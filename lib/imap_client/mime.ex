defmodule IMAPClient.MIME do
  # Internal to IMAPClient.
  @moduledoc false

  alias IMAPClient.Charset
  alias IMAPClient.Syntax
  alias IMAPClient.Text

  def parse_mime_structure(input) when is_binary(input) do
    input |> Charset.utf8() |> mime_values([]) |> parse_mime_structure()
  end

  def parse_mime_structure([_ | _] = values) do
    with {:ok, part} <- parse_part(scrub_metadata(values), "") do
      part
    else
      _ -> nil
    end
  end

  def parse_mime_structure(_) do
    nil
  end

  defp scrub_metadata(values) when is_list(values) do
    Enum.map(values, &scrub_metadata/1)
  end

  defp scrub_metadata(value) when is_binary(value) do
    Charset.utf8(value)
  end

  defp scrub_metadata(value) do
    value
  end

  # Some real-world BODYSTRUCTURE corpus entries have surplus trailing closes;
  # this parser tolerates those, so the tolerance lives here, not in
  # the shared Syntax parser.
  defp mime_values(input, acc) do
    case String.trim_leading(input) do
      "" ->
        Enum.reverse(acc)

      <<")", _::binary>> ->
        Enum.reverse(acc)

      input ->
        case Syntax.next(input) do
          {:ok, value, rest} -> mime_values(rest, [value | acc])
          _ -> []
        end
    end
  end

  defp parse_part([first | _] = values, prefix) when is_list(first) do
    {bodies, rest} = Enum.split_while(values, &is_list/1)

    children =
      bodies
      |> Enum.with_index(1)
      |> Enum.map(fn {body, index} ->
        child_prefix = if prefix == "", do: "#{index}", else: "#{prefix}.#{index}"
        parse_part(body, child_prefix)
      end)

    if Enum.all?(children, &match?({:ok, _}, &1)) do
      subtype = string_at(rest, 0)
      {disposition, disposition_params} = disposition(Enum.at(rest, 2))

      {:ok,
       %{
         part_id: prefix,
         type: "multipart",
         subtype: String.downcase(subtype),
         params: params(Enum.at(rest, 1)),
         encoding: "",
         size: 0,
         disposition: disposition,
         disposition_params: disposition_params,
         children: Enum.map(children, fn {:ok, part} -> part end)
       }}
    else
      {:error, :invalid_structure}
    end
  end

  defp parse_part([type | rest], prefix) when is_binary(type) do
    type = String.downcase(type)

    {subtype, rest} =
      case rest do
        [parameters | _] when is_list(parameters) ->
          {if(type == "text", do: "plain", else: ""), rest}

        [subtype | tail] ->
          {downcase(subtype), tail}

        [] ->
          {"", []}
      end

    extra =
      cond do
        type == "text" -> 1
        type == "message" and subtype == "rfc822" -> 3
        true -> 0
      end

    {disposition, disposition_params} = disposition(Enum.at(rest, 6 + extra))

    {:ok,
     %{
       part_id: if(prefix == "", do: "1", else: prefix),
       type: type,
       subtype: subtype,
       params: params(Enum.at(rest, 0)),
       encoding: downcase(Enum.at(rest, 3)),
       size: number(Enum.at(rest, 4)),
       disposition: disposition,
       disposition_params: disposition_params
     }}
  end

  defp parse_part(_, _) do
    {:error, :invalid_structure}
  end

  defp string_at(values, index) do
    text(Enum.at(values, index))
  end

  defp text(value) when is_binary(value) do
    value
  end

  defp text(_) do
    ""
  end

  defp downcase(value) do
    value |> text() |> String.downcase()
  end

  defp number(value) when is_binary(value) do
    case Integer.parse(value) do
      {value, ""} when value >= 0 -> value
      _ -> 0
    end
  end

  defp number(_) do
    0
  end

  defp params(values) when is_list(values) do
    values
    |> Enum.chunk_every(2)
    |> Enum.reduce(%{}, fn
      [key, value], acc when is_binary(key) and is_binary(value) ->
        Map.put(acc, String.downcase(key), value)

      _, acc ->
        acc
    end)
  end

  defp params(_) do
    %{}
  end

  defp disposition([kind | rest]) do
    kind = downcase(kind)
    {if(kind == "", do: nil, else: kind), params(List.first(rest))}
  end

  defp disposition(_) do
    {nil, %{}}
  end

  def select_text_parts(nil) do
    %{plain: nil, html: nil}
  end

  def select_text_parts(%{type: "multipart", children: children, subtype: subtype})
      when subtype in ["related", "signed"] do
    select_text_parts(List.first(children))
  end

  def select_text_parts(%{type: "multipart", children: children, subtype: "report"}) do
    first = List.first(children)
    %{plain: if(candidate?(first, "plain"), do: first), html: nil}
  end

  def select_text_parts(%{type: "multipart", children: children, subtype: "alternative"}) do
    Enum.reduce(children, %{plain: nil, html: nil}, fn child, selected ->
      found = select_text_parts(child)
      %{plain: selected.plain || found.plain, html: selected.html || found.html}
    end)
  end

  def select_text_parts(%{type: "multipart", children: children}) do
    Enum.reduce_while(children, %{plain: nil, html: nil}, fn child, selected ->
      cond do
        selected.plain && selected.html ->
          {:halt, selected}

        child.type == "multipart" ->
          found = select_text_parts(child)
          if found.plain || found.html, do: {:halt, found}, else: {:cont, selected}

        candidate?(child, "plain") ->
          {:cont, %{selected | plain: selected.plain || child}}

        candidate?(child, "html") ->
          {:cont, %{selected | html: selected.html || child}}

        true ->
          {:cont, selected}
      end
    end)
  end

  def select_text_parts(part) do
    %{
      plain: if(candidate?(part, "plain"), do: part),
      html: if(candidate?(part, "html"), do: part)
    }
  end

  defp candidate?(%{type: "text", subtype: subtype, disposition: disposition}, subtype) do
    disposition != "attachment"
  end

  defp candidate?(_, _) do
    false
  end

  def find_leaf_part(nil, _part_id) do
    nil
  end

  def find_leaf_part(%{children: children}, part_id) do
    Enum.find_value(children, &find_leaf_part(&1, part_id))
  end

  def find_leaf_part(%{part_id: part_id} = part, part_id) do
    part
  end

  def find_leaf_part(_, _) do
    nil
  end

  def collect_attachments(structure, body, decoder \\ nil)

  def collect_attachments(nil, _body, _decoder) do
    []
  end

  def collect_attachments(%{children: children}, body, decoder) do
    Enum.flat_map(children, &collect_attachments(&1, body, decoder))
  end

  def collect_attachments(part, body, decoder) do
    if part == body.plain || part == body.html do
      []
    else
      [
        %{
          part_id: part.part_id,
          filename: attachment_filename(part, decoder),
          mime_type: normalized_mime_type(part),
          size: if(part.encoding == "base64", do: div(part.size * 3, 4), else: part.size)
        }
      ]
    end
  end

  def normalized_mime_type(part) do
    type = String.downcase(part.type <> "/" <> part.subtype)

    if Regex.match?(~r/\A[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+\z/, type),
      do: type,
      else: "application/octet-stream"
  end

  def attachment_filename(part, decoder \\ nil) do
    declared =
      read_mime_param(part.disposition_params, "filename", decoder) ||
        read_mime_param(part.params, "name", decoder)

    cleaned =
      if declared, do: Text.one_line(declared)

    cond do
      cleaned not in [nil, ""] -> cleaned
      part.type == "message" && part.subtype == "rfc822" -> "forwarded-message.eml"
      true -> "attachment-#{part.part_id}"
    end
  end

  def read_mime_param(params, name, decoder \\ nil) do
    cond do
      Map.has_key?(params, name <> "*") ->
        extended_parameter(Map.fetch!(params, name <> "*"), decoder)

      Map.has_key?(params, name <> "*0") || Map.has_key?(params, name <> "*0*") ->
        {segments, charset} = parameter_segments(params, name, 0, [], nil)
        decode_parameter(IO.iodata_to_binary(Enum.reverse(segments)), charset, decoder)

      Map.has_key?(params, name) ->
        decode_encoded_words(Map.fetch!(params, name), decoder)

      true ->
        nil
    end
  end

  defp extended_parameter(value, decoder) do
    case String.split(value, "'", parts: 3) do
      [charset, _language, data] -> decode_parameter(percent_decode(data), charset, decoder)
      _ -> value
    end
  end

  # An RFC 2231 parameter in an unknown charset reads as lossy UTF-8.
  defp decode_parameter(bytes, label, decoder) do
    case Charset.decode_with(decoder, bytes, body_label(label)) do
      {:ok, text} -> text
      :error -> Charset.utf8(bytes)
    end
  end

  # Body and parameter labels are trimmed, and a missing or empty one means UTF-8.
  defp body_label(label) do
    case if(is_binary(label), do: String.trim(label), else: "") do
      "" -> "utf-8"
      label -> label
    end
  end

  defp parameter_segments(params, name, index, acc, charset) do
    encoded = Map.get(params, "#{name}*#{index}*")
    plain = Map.get(params, "#{name}*#{index}")

    cond do
      encoded != nil ->
        {data, charset} =
          case {index, String.split(encoded, "'", parts: 3)} do
            {0, [label, _language, data]} -> {data, label}
            _ -> {encoded, charset}
          end

        parameter_segments(params, name, index + 1, [percent_decode(data) | acc], charset)

      plain != nil ->
        parameter_segments(params, name, index + 1, [plain | acc], charset)

      true ->
        {acc, charset}
    end
  end

  defp percent_decode(input) do
    percent_decode(input, [])
  end

  defp percent_decode(<<"%", high, low, rest::binary>>, acc)
       when high in ?0..?9 or high in ?A..?F or high in ?a..?f do
    if low in ?0..?9 or low in ?A..?F or low in ?a..?f do
      percent_decode(rest, [<<String.to_integer(<<high, low>>, 16)>> | acc])
    else
      percent_decode(<<high, low, rest::binary>>, ["%" | acc])
    end
  end

  defp percent_decode(<<byte, rest::binary>>, acc) do
    percent_decode(rest, [<<byte>> | acc])
  end

  defp percent_decode("", acc) do
    acc |> Enum.reverse() |> IO.iodata_to_binary()
  end

  def decode_encoded_words(input, decoder \\ nil) do
    input = Charset.utf8(input)
    matches = Regex.scan(~r/=\?([^?]+)\?([BQ])\?([^?]+)\?=/i, input, return: :index)

    {result, cursor, _previous} =
      Enum.reduce(matches, {[], 0, false}, fn [{offset, length}, charset, encoding, data],
                                              {acc, cursor, previous} ->
        charset = binary_part(input, elem(charset, 0), elem(charset, 1))
        encoding = binary_part(input, elem(encoding, 0), elem(encoding, 1))
        data = binary_part(input, elem(data, 0), elem(data, 1))
        separator = binary_part(input, cursor, offset - cursor)
        {decoded, success} = decode_word(charset, encoding, data, decoder)

        separator =
          if previous && success && Regex.match?(~r/\A(?:(?:\r\n)?[ \t])+\z/, separator),
            do: "",
            else: separator

        {[decoded, separator | acc], offset + length, success}
      end)

    IO.iodata_to_binary(
      Enum.reverse([binary_part(input, cursor, byte_size(input) - cursor) | result])
    )
  end

  # An encoded word in an unknown charset, or with malformed data, keeps its encoded
  # payload. Its label is passed as written.
  defp decode_word(charset, encoding, data, decoder) do
    bytes =
      if String.upcase(encoding) == "B" do
        Base.decode64(data, padding: false)
      else
        {:ok, decode_quoted_printable(String.replace(data, "_", " "))}
      end

    with {:ok, bytes} <- bytes,
         {:ok, text} <- Charset.decode_with(decoder, bytes, charset) do
      {text, true}
    else
      :error -> {data, false}
    end
  end

  @doc """
  Text bytes, transfer-decoded leniently: malformed base64 characters are skipped, and
  undecodable base64 becomes empty.
  """
  def decode_transfer_encoding(bytes, encoding) do
    case String.downcase(String.trim(encoding)) do
      "base64" -> lenient_base64(bytes)
      "quoted-printable" -> decode_quoted_printable(bytes)
      _ -> bytes
    end
  end

  @doc """
  Attachment bytes, transfer-decoded strictly: `{:ok, bytes}`, or
  `{:error, :malformed_content}` for malformed base64.
  """
  def decode_attachment(bytes, encoding) do
    case String.downcase(String.trim(encoding)) do
      "base64" ->
        case Base.decode64(Regex.replace(~r/[ \t\r\n]/, bytes, ""), padding: false) do
          {:ok, decoded} -> {:ok, decoded}
          :error -> {:error, :malformed_content}
        end

      "quoted-printable" ->
        {:ok, decode_quoted_printable(bytes)}

      _ ->
        {:ok, bytes}
    end
  end

  defp lenient_base64(bytes) do
    data = Regex.replace(~r/[^A-Za-z0-9+\/]/, bytes, "")

    data =
      if rem(byte_size(data), 4) == 1 do
        binary_part(data, 0, byte_size(data) - 1)
      else
        data
      end

    case Base.decode64(data, padding: false) do
      {:ok, decoded} -> decoded
      :error -> ""
    end
  end

  defp decode_quoted_printable(bytes) do
    bytes |> quoted_printable([]) |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp quoted_printable("", acc) do
    acc
  end

  defp quoted_printable(<<"=", rest::binary>>, acc) do
    case soft_break(rest) do
      {:ok, tail} -> quoted_printable(tail, acc)
      :no -> quoted_printable_escape(rest, acc)
    end
  end

  defp quoted_printable(bytes, acc) do
    case :binary.match(bytes, "=") do
      {offset, 1} ->
        <<span::binary-size(offset), rest::binary>> = bytes
        quoted_printable(rest, [span | acc])

      :nomatch ->
        [bytes | acc]
    end
  end

  defp soft_break(<<"\r\n", rest::binary>>) do
    {:ok, rest}
  end

  defp soft_break(<<"\n", rest::binary>>) do
    {:ok, rest}
  end

  defp soft_break(<<space, rest::binary>>) when space in [32, 9] do
    soft_break(rest)
  end

  defp soft_break(_) do
    :no
  end

  defp quoted_printable_escape(<<high, low, rest::binary>>, acc)
       when (high in ?0..?9 or high in ?A..?F or high in ?a..?f) and
              (low in ?0..?9 or low in ?A..?F or low in ?a..?f) do
    quoted_printable(rest, [<<String.to_integer(<<high, low>>, 16)>> | acc])
  end

  defp quoted_printable_escape(rest, acc) do
    quoted_printable(rest, ["=" | acc])
  end

  @doc """
  A text part's bytes, transfer-decoded and then charset-decoded: a string, or
  `%{charset: label, bytes: bytes}` when the decoder doesn't know the charset. A part
  without structure is UTF-8.
  """
  def decode_text_part(bytes, nil, _decoder) do
    Charset.utf8(bytes)
  end

  def decode_text_part(bytes, part, decoder) do
    bytes = decode_transfer_encoding(bytes, part.encoding)
    label = body_label(Map.get(part.params, "charset"))

    case Charset.decode_with(decoder, bytes, label) do
      {:ok, text} -> text
      :error -> %{charset: label, bytes: bytes}
    end
  end

  def decoded_size_lower_bound(part) do
    if String.downcase(String.trim(part.encoding)) in ["7bit", "8bit", "binary", ""],
      do: part.size,
      else: nil
  end
end
