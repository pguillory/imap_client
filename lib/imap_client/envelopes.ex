defmodule IMAPClient.Envelopes do
  # Internal to IMAPClient: the read-only envelope and INTERNALDATE fetches and the
  # SEARCH date.
  @moduledoc false

  alias IMAPClient
  alias IMAPClient.Protocol

  # Fetching ENVELOPE and INTERNALDATE never sets \Seen, so these fetches cannot
  # change the mailbox.
  @envelope_items "UID ENVELOPE INTERNALDATE"

  def fetch_envelopes(_connection, [], _decoder) do
    {:ok, %{envelopes: %{}, other_lines: []}}
  end

  def fetch_envelopes(connection, uids, decoder) do
    with {:ok, data} <- IMAPClient.fetch(connection, uids, @envelope_items) do
      requested = MapSet.new(uids)

      envelopes =
        for {uid, items} <- data.messages,
            MapSet.member?(requested, uid),
            envelope = envelope(uid, items, decoder),
            envelope != nil,
            into: %{},
            do: {uid, envelope}

      {:ok, %{envelopes: envelopes, other_lines: data.other_lines}}
    end
  end

  # A UID is included only when both its envelope (not NIL) and a parseable
  # INTERNALDATE came back; the caller decides what the others mean.
  defp envelope(uid, items, decoder) do
    with {:ok, envelope} when is_list(envelope) <- Map.fetch(items, "ENVELOPE"),
         {:ok, raw_date} when is_binary(raw_date) <- Map.fetch(items, "INTERNALDATE"),
         internal_date_ms when is_integer(internal_date_ms) <- parse_internal_date(raw_date) do
      %{
        uid: uid,
        envelope: Protocol.envelope(envelope, decoder),
        internal_date_ms: internal_date_ms
      }
    else
      _ -> nil
    end
  end

  def fetch_internal_dates(_connection, []) do
    {:ok, %{dates: %{}, other_lines: []}}
  end

  # INTERNALDATE alone (never sets \Seen): a UID is present only when a parseable
  # date came back.
  def fetch_internal_dates(connection, uids) do
    with {:ok, data} <- IMAPClient.fetch(connection, uids, "UID INTERNALDATE") do
      requested = MapSet.new(uids)

      dates =
        for {uid, items} <- data.messages,
            MapSet.member?(requested, uid),
            raw = items["INTERNALDATE"],
            is_binary(raw),
            at = parse_internal_date(raw),
            into: %{},
            do: {uid, at}

      {:ok, %{dates: dates, other_lines: data.other_lines}}
    end
  end

  @search_months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  # A day as IMAP's SEARCH date ("5-Oct-2026"), in UTC.
  def search_date(ms) when is_integer(ms) do
    date = ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_date()
    "#{date.day}-#{Enum.at(@search_months, date.month - 1)}-#{date.year}"
  end

  @months ~w(jan feb mar apr may jun jul aug sep oct nov dec)
  @unix_epoch_days Date.to_gregorian_days(~D[1970-01-01])

  # IMAP INTERNALDATE ("17-Jul-1996 02:44:25 -0700") to Unix milliseconds, or nil.
  # Field overflow (31-Feb, hour 99) rolls over, and a two-digit year means 1900 plus
  # that year.
  def parse_internal_date(value) do
    regex =
      ~r/^\s?(\d{1,2})-([A-Za-z]{3})-(\d{4}) (\d{2}):(\d{2}):(\d{2}) ([+-])(\d{2})(\d{2})$/

    with [_, day, month, year, hour, minute, second, sign, offset_hours, offset_minutes] <-
           Regex.run(regex, String.trim(value)),
         index when is_integer(index) <- Enum.find_index(@months, &(&1 == String.downcase(month))) do
      [day, year, hour, minute, second, offset_hours, offset_minutes] =
        Enum.map(
          [day, year, hour, minute, second, offset_hours, offset_minutes],
          &String.to_integer/1
        )

      year = if year < 100, do: year + 1900, else: year
      days = Date.to_gregorian_days(Date.new!(year, index + 1, 1)) + day - 1 - @unix_epoch_days
      offset_minutes = (offset_hours * 60 + offset_minutes) * if(sign == "-", do: -1, else: 1)

      (days * 86_400 + hour * 3_600 + minute * 60 + second - offset_minutes * 60) * 1_000
    else
      _ -> nil
    end
  end
end
