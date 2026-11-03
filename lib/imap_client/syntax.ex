defmodule IMAPClient.Syntax do
  # Internal to IMAPClient.
  @moduledoc false

  def parse(input) when is_binary(input) do
    values(skip_space(input), [])
  end

  defp values("", values) do
    {:ok, Enum.reverse(values)}
  end

  defp values(input, values) do
    with {:ok, value, rest} <- next(input) do
      values(skip_space(rest), [value | values])
    end
  end

  def next(input) when is_binary(input) do
    value(skip_space(input))
  end

  defp value(<<"(", rest::binary>>) do
    list(skip_space(rest), [])
  end

  defp value(<<quote, rest::binary>>) when quote in [?", ?'] do
    quoted(rest, quote, [])
  end

  defp value("") do
    {:error, :invalid_response}
  end

  defp value(<<")", _::binary>>) do
    {:error, :invalid_response}
  end

  defp value(input) do
    atom(input, [])
  end

  defp list(<<")", rest::binary>>, values) do
    {:ok, Enum.reverse(values), rest}
  end

  defp list("", _values) do
    {:error, :invalid_response}
  end

  defp list(input, values) do
    with {:ok, value, rest} <- next(input) do
      list(skip_space(rest), [value | values])
    end
  end

  # Retain binary spans rather than one cons per octet: BODY values can be tens
  # of MiB, and a byte list would dwarf the literal and its configured bound.
  defp quoted(input, quote, spans) do
    delimiters = if quote == ?", do: [<<quote>>, "\\"], else: <<quote>>

    case :binary.match(input, delimiters) do
      {offset, 1} ->
        <<span::binary-size(offset), delimiter, rest::binary>> = input

        case {delimiter, rest} do
          {^quote, rest} -> {:ok, IO.iodata_to_binary(Enum.reverse([span | spans])), rest}
          {?\\, <<escaped, rest::binary>>} -> quoted(rest, quote, [<<escaped>>, span | spans])
          _ -> {:error, :invalid_response}
        end

      :nomatch ->
        {:error, :invalid_response}
    end
  end

  defp atom(input, []) do
    delimiters = ["\t", "\n", "\v", "\f", "\r", " ", "(", ")", "\"", <<0xC2, 0xA0>>]

    offset =
      case :binary.match(input, delimiters) do
        {offset, _} -> offset
        :nomatch -> byte_size(input)
      end

    <<text::binary-size(offset), rest::binary>> = input

    if text == "",
      do: {:error, :invalid_response},
      else: {:ok, if(String.upcase(text) == "NIL", do: nil, else: text), rest}
  end

  defp skip_space(<<byte, rest::binary>>) when byte in [9, 10, 11, 12, 13, 32] do
    skip_space(rest)
  end

  defp skip_space(<<0xC2, 0xA0, rest::binary>>) do
    skip_space(rest)
  end

  defp skip_space(rest) do
    rest
  end
end
