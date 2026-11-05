defmodule IMAPClient.Protocol do
  # Internal to IMAPClient.
  @moduledoc false

  alias IMAPClient.Charset
  alias IMAPClient.MailboxName
  alias IMAPClient.MIME
  alias IMAPClient.Syntax

  def safe_text?(text) when is_binary(text) do
    :binary.match(text, ["\r", "\n", <<0>>]) == :nomatch
  end

  def safe_text?(_) do
    false
  end

  def quote_string(text) do
    "\"" <>
      (text
       |> :binary.replace("\\", "\\\\", [:global])
       |> :binary.replace("\"", "\\\"", [:global])) <> "\""
  end

  # A mailbox name for the wire: modified UTF-7, then quoted. Callers
  # check the raw name with safe_text?/1 first.
  def quote_mailbox(name) do
    quote_string(MailboxName.encode(name))
  end

  def tagged_status(line) do
    case Regex.run(~r/^(\S+)\s+(OK|NO|BAD)(?:\s|$)/i, line) do
      [_, tag, status] -> {String.upcase(tag), status_atom(String.upcase(status))}
      _ -> nil
    end
  end

  defp status_atom("OK") do
    :ok
  end

  defp status_atom("NO") do
    :no
  end

  defp status_atom("BAD") do
    :bad
  end

  def fetch_line?(line) do
    Regex.match?(~r/^\*\s+\d+\s+FETCH\b/i, line)
  end

  def bye?(line) do
    Regex.match?(~r/^\*\s+BYE(?:\s|$)/i, line)
  end

  def fetch_items(line) do
    case Regex.run(~r/^\*\s+\d+\s+FETCH\s+\((.*)$/is, line) do
      [_, content] -> fetch_pairs(content, %{})
      _ -> :other
    end
  end

  defp fetch_pairs(content, pairs) do
    content = String.trim_leading(content)

    if String.starts_with?(content, ")") do
      if String.trim(content) == ")", do: {:ok, pairs}, else: {:error, :invalid_response}
    else
      with {:ok, name, rest} <- item_name(content),
           {:ok, value, rest} <- Syntax.next(rest) do
        key = String.upcase(name)

        if Map.has_key?(pairs, key),
          do: {:error, :invalid_response},
          else: fetch_pairs(rest, Map.put(pairs, key, value))
      else
        _ -> {:error, :invalid_response}
      end
    end
  end

  defp item_name(content) do
    case Regex.run(~r/^([^\s()"\[\]]+(?:\[[^\]]*\](?:<\d+>)?)?)\s+/s, content) do
      [whole, name] ->
        {:ok, name, binary_part(content, byte_size(whole), byte_size(content) - byte_size(whole))}

      _ ->
        {:error, :invalid_response}
    end
  end

  def metadata(lines) do
    Enum.reduce(lines, %{messages: %{}, other_lines: []}, fn line, acc ->
      case fetch_items(line) do
        {:ok, %{"UID" => uid} = items} when is_binary(uid) ->
          case positive_integer(uid) do
            {:ok, uid} ->
              items = Map.new(items, fn {name, value} -> {name, metadata_text(value)} end)

              update_in(
                acc.messages,
                &Map.update(&1, uid, items, fn prior -> Map.merge(prior, items) end)
              )

            _ ->
              acc
          end

        _ ->
          if fetch_line?(line),
            do: acc,
            else: update_in(acc.other_lines, &[metadata_text(line) | &1])
      end
    end)
    |> Map.update!(:other_lines, &Enum.reverse/1)
  end

  def body(lines, uid, section) do
    expected = normalize_section(section)

    Enum.reduce_while(lines, {:ok, :missing}, fn line, acc ->
      case fetch_items(line) do
        {:ok, items} ->
          bodies = Enum.filter(items, fn {name, _} -> String.starts_with?(name, "BODY[") end)

          case bodies do
            [] ->
              {:cont, acc}

            [{name, value}] ->
              valid? =
                Map.get(items, "UID") == Integer.to_string(uid) and
                  normalize_section(name) == "BODY[#{expected}]" and
                  (is_binary(value) or is_nil(value))

              if valid? and acc == {:ok, :missing},
                do: {:cont, {:ok, value || ""}},
                else: {:halt, {:error, :invalid_response}}

            _ ->
              {:halt, {:error, :invalid_response}}
          end

        {:error, _} ->
          {:halt, {:error, :invalid_response}}

        :other ->
          {:cont, acc}
      end
    end)
  end

  def normalize_section(section) do
    section |> String.trim() |> String.upcase() |> String.replace(~r/\s+/, " ")
  end

  # RFC 4315 section 3: only the tagged OK of an APPEND carries APPENDUID, and a single
  # message has a single UID, not a set. Anything else leaves both unknown.
  def append_uid(completion) do
    with [_, validity, uid] <-
           Regex.run(
             ~r/^\S+\s+OK\s+\[APPENDUID ([1-9][0-9]*) ([1-9][0-9]*)\](?:\s|$)/i,
             completion
           ),
         {:ok, validity} <- positive_integer(validity),
         {:ok, uid} <- positive_integer(uid) do
      %{uid: uid, uid_validity: validity}
    else
      _ -> %{uid: nil, uid_validity: nil}
    end
  end

  def positive_integer(value) when is_binary(value) do
    digits = String.trim_leading(value, "0")

    if byte_size(digits) in 1..10 and Regex.match?(~r/\A[0-9]+\z/, value) do
      case Integer.parse(digits) do
        {number, ""} when number in 1..4_294_967_295 -> {:ok, number}
        _ -> {:error, :invalid_response}
      end
    else
      {:error, :invalid_response}
    end
  end

  def positive_integer(_) do
    {:error, :invalid_response}
  end

  def search_uids(lines) do
    Enum.find_value(lines, fn line ->
      case Regex.run(~r/^\*\s+SEARCH\b(.*)$/i, line) do
        [_, rest] ->
          rest
          |> String.split()
          |> Enum.flat_map(fn value ->
            case positive_integer(value) do
              {:ok, uid} -> [uid]
              _ -> []
            end
          end)

        _ ->
          nil
      end
    end)
  end

  @status_keys %{
    "MESSAGES" => :messages,
    "RECENT" => :recent,
    "UIDNEXT" => :uid_next,
    "UIDVALIDITY" => :uid_validity,
    "UNSEEN" => :unseen
  }

  @doc """
  The counts in the STATUS responses for `folder`, keyed by atom. Responses for another
  mailbox, unknown items and malformed values are ignored. Counts may be zero.
  """
  def status(lines, folder) do
    Enum.reduce(lines, %{}, fn line, acc ->
      with [_, rest] <- Regex.run(~r/^\*\s+STATUS\s+(.+)$/is, line),
           {:ok, name, rest} <- mailbox_name_prefix(rest),
           true <- mailbox_names_match?(folder, MailboxName.decode(metadata_text(name))),
           {:ok, items, _rest} when is_list(items) <- Syntax.next(rest) do
        Map.merge(acc, status_items(items))
      else
        _ -> acc
      end
    end)
  end

  defp mailbox_name_prefix(rest) do
    rest = String.trim_leading(rest)

    if String.starts_with?(rest, "\"") do
      Syntax.next(rest)
    else
      case String.split(rest, " ", parts: 2) do
        [name, rest] when name != "" -> {:ok, name, rest}
        _ -> {:error, :invalid_response}
      end
    end
  end

  # An item whose value isn't a number (NIL, or a list such as RFC 8474's MAILBOXID) is
  # skipped without dropping the items after it.
  defp status_items([name, value | rest]) do
    items = status_items(rest)

    with true <- is_binary(name) and is_binary(value),
         {:ok, key} <- Map.fetch(@status_keys, String.upcase(name)),
         true <- Regex.match?(~r/\A[0-9]{1,10}\z/, value),
         {number, ""} when number <= 4_294_967_295 <- Integer.parse(value) do
      Map.put(items, key, number)
    else
      _ -> items
    end
  end

  defp status_items(_) do
    %{}
  end

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  @doc """
  A `DateTime` as an IMAP date-time (`17-Jul-1996 02:44:25 +0000`), in UTC. The year
  must have four digits after the shift to UTC; see `valid_internal_date?/1`.
  """
  def internal_date(%DateTime{} = date) do
    date = DateTime.shift_zone!(date, "Etc/UTC")
    day = date.day |> Integer.to_string() |> String.pad_leading(2, " ")
    time = date |> DateTime.to_time() |> Time.truncate(:second) |> Time.to_iso8601()
    "#{day}-#{Enum.at(@months, date.month - 1)}-#{date.year} #{time} +0000"
  end

  @doc "Whether a `DateTime` can be sent as an IMAP date-time: a four-digit UTC year."
  def valid_internal_date?(%DateTime{} = date) do
    DateTime.shift_zone!(date, "Etc/UTC").year in 1000..9999
  end

  def valid_internal_date?(_date) do
    false
  end

  def mailbox_names_match?(requested, available) do
    if String.upcase(requested) == "INBOX",
      do: String.upcase(available) == "INBOX",
      else: requested == available
  end

  def list_folder(line, strict? \\ false) do
    case Regex.run(~r/^\*\s+LIST\s+\(([^)]*)\)\s+(.+)$/is, line) do
      [_, flags, rest] ->
        flags = String.split(flags)

        with {:ok, delimiter, rest} <- Syntax.next(rest),
             true <- is_binary(delimiter) or is_nil(delimiter),
             {:ok, name, rest} <- mailbox_name(rest),
             true <- is_binary(name) and String.trim(rest) == "" do
          {:ok,
           %{
             name: MailboxName.decode(metadata_text(name)),
             flags: metadata_text(flags),
             delimiter: metadata_text(delimiter || "")
           }}
        else
          _ -> malformed_folder(flags, strict?)
        end

      _ ->
        if strict? and Regex.match?(~r/^\*\s+LIST\b.*\\Drafts\b/i, line),
          do: {:error, :invalid_response},
          else: :other
    end
  end

  # Mailbox is an astring, so bare NIL and apostrophes are ordinary name bytes.
  # MIME's tolerant single-quote/NIL grammar must not alter a mailbox atom.
  defp mailbox_name(rest) do
    name = String.trim(rest)

    cond do
      String.starts_with?(name, "\"") -> Syntax.next(name)
      name != "" and !String.contains?(name, "\"") -> {:ok, name, ""}
      true -> {:error, :invalid_response}
    end
  end

  defp malformed_folder(flags, strict?) do
    if strict? and Enum.any?(flags, &(String.downcase(&1) == "\\drafts")),
      do: {:error, :invalid_response},
      else: :other
  end

  def build_search(criteria) when is_map(criteria) do
    values = Enum.map([:from, :subject, :keyword], &Map.get(criteria, &1))
    dates = Enum.map([:since, :until], &Map.get(criteria, &1))

    if Enum.all?(values, &(is_nil(&1) or safe_text?(&1))) and Enum.all?(dates, &valid_date?/1) do
      {segments, text} =
        Enum.reduce(Enum.zip(~w(FROM SUBJECT TEXT), values), {[], "ALL"}, fn
          {_key, value}, acc when value in [nil, ""] ->
            acc

          {key, value}, {segments, text} ->
            if ascii?(value),
              do: {segments, text <> " #{key} " <> quote_string(value)},
              else: {segments ++ [text <> " #{key} ", {:literal, value}], ""}
        end)

      text =
        text <> if(criteria[:since] not in [nil, ""], do: " SINCE #{criteria.since}", else: "")

      text =
        text <> if(criteria[:until] not in [nil, ""], do: " BEFORE #{criteria.until}", else: "")

      text = text <> if(criteria[:unread_only], do: " UNSEEN", else: "")
      segments = if text == "", do: segments, else: segments ++ [text]

      segments =
        if length(segments) > 1,
          do: List.update_at(segments, 0, &("CHARSET UTF-8 " <> &1)),
          else: segments

      {:ok, segments}
    else
      {:error, :invalid_argument}
    end
  end

  defp valid_date?(nil) do
    true
  end

  defp valid_date?("") do
    true
  end

  defp valid_date?(date) when is_binary(date) do
    Regex.match?(~r/\A\d{1,2}-(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)-\d{4}\z/i, date)
  end

  defp valid_date?(_) do
    false
  end

  defp ascii?(bytes) do
    Enum.all?(:binary.bin_to_list(bytes), &(&1 < 128))
  end

  def envelope(content, decoder \\ nil) do
    empty = %{date: nil, subject: nil, from: [], to: [], cc: [], reply_to: [], message_id: nil}

    parsed =
      cond do
        is_list(content) -> {:ok, content}
        is_binary(content) -> Syntax.parse(content)
        true -> {:error, :invalid_response}
      end

    parsed =
      case parsed do
        {:ok, fields} -> {:ok, metadata_text(Enum.take(fields ++ List.duplicate(nil, 10), 10))}
        error -> error
      end

    case parsed do
      {:ok, [date, subject, from, _sender, reply, to, cc, _bcc, _in_reply, id]} ->
        %{
          empty
          | date: string_or_nil(date),
            subject: decoded(subject, decoder),
            from: addresses(from, decoder),
            reply_to: addresses(reply, decoder),
            to: addresses(to, decoder),
            cc: addresses(cc, decoder),
            message_id: string_or_nil(id)
        }

      _ ->
        empty
    end
  end

  defp string_or_nil(value) when is_binary(value) do
    value
  end

  defp string_or_nil(_) do
    nil
  end

  defp decoded(value, decoder) when is_binary(value) and value != "" do
    MIME.decode_encoded_words(value, decoder)
  end

  defp decoded(_, _decoder) do
    nil
  end

  defp addresses(values, decoder) when is_list(values) do
    Enum.flat_map(values, fn
      [name, _, mailbox, host] when is_binary(host) and host != "" ->
        [%{name: decoded(name, decoder), address: (string_or_nil(mailbox) || "") <> "@" <> host}]

      _ ->
        []
    end)
  end

  defp addresses(_, _decoder) do
    []
  end

  defp metadata_text(value) when is_binary(value) do
    Charset.utf8(value)
  end

  defp metadata_text(values) when is_list(values) do
    Enum.map(values, &metadata_text/1)
  end

  defp metadata_text(value) do
    value
  end

  def list_unsubscribe(nil) do
    nil
  end

  def list_unsubscribe(raw) do
    urls = Regex.scan(~r/<([^>]+)>/, raw, capture: :all_but_first) |> List.flatten()

    Enum.find(urls, &String.starts_with?(String.downcase(&1), "mailto:")) ||
      Enum.find(urls, &String.starts_with?(String.downcase(&1), "https:")) || List.first(urls)
  end
end
