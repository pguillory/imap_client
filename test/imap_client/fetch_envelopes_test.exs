defmodule IMAPClient.FetchEnvelopesTest do
  use ExUnit.Case, async: true

  import IMAPClient

  alias IMAPClient.FakeServer
  alias IMAPClient.Peer
  alias IMAPClient.SocketWait

  @envelope ~s|"Mon, 2 Feb 2026 10:00:00 +0000" "Hello" (("Ann Sender" NIL "ann" "example.test")) NIL NIL (("Me" NIL "me" "example.test")) NIL NIL NIL "<m1@example.test>"|

  defp open(server) do
    config = FakeServer.endpoint(server)
    {:ok, connection} = start_link()
    :ok = connect(connection, config)
    :ok = login(connection, config.username, config.password)
    {:ok, _} = examine(connection, "INBOX")
    connection
  end

  defp message(uid, overrides \\ %{}) do
    Map.merge(
      %{uid: uid, envelope: @envelope, internal_date: "03-Feb-2026 04:05:06 -0700"},
      overrides
    )
  end

  test "fetches envelopes read-only with envelope and date" do
    server =
      start_supervised!(
        {FakeServer, mailboxes: %{"INBOX" => %{messages: [message(4), message(5)]}}}
      )

    connection = open(server)

    assert {:ok, %{envelopes: envelopes, other_lines: []}} =
             fetch_envelopes(connection, [4, 5, 9])

    assert envelopes[4] == %{
             uid: 4,
             envelope: %{
               date: "Mon, 2 Feb 2026 10:00:00 +0000",
               subject: "Hello",
               from: [%{name: "Ann Sender", address: "ann@example.test"}],
               to: [%{name: "Me", address: "me@example.test"}],
               cc: [],
               reply_to: [],
               message_id: "<m1@example.test>"
             },
             internal_date_ms: 1_770_116_706_000
           }

    assert Map.keys(envelopes) == [4, 5]
    assert Enum.all?(FakeServer.mailbox(server, "INBOX").messages, &(&1.flags == []))
  end

  test "a UID with an unparseable INTERNALDATE or omitted metadata is not a candidate" do
    server =
      start_supervised!(
        {FakeServer,
         mailboxes: %{
           "INBOX" => %{messages: [message(4, %{internal_date: "yesterday"}), message(5)]}
         }}
      )

    connection = open(server)

    assert {:ok, %{envelopes: envelopes}} =
             fetch_envelopes(connection, [4, 5])

    assert Map.keys(envelopes) == [5]

    :ok = FakeServer.script_next(server, :fetch, {:omit, :metadata})
    assert {:ok, %{envelopes: envelopes}} = fetch_envelopes(connection, [5])
    assert envelopes == %{}
  end

  test "returns other untagged lines and sends nothing for no UIDs" do
    server = start_supervised!({FakeServer, mailboxes: %{"INBOX" => %{messages: [message(4)]}}})
    connection = open(server)
    commands = length(FakeServer.commands(server))

    assert fetch_envelopes(connection, []) ==
             {:ok, %{envelopes: %{}, other_lines: []}}

    assert length(FakeServer.commands(server)) == commands

    :ok = FakeServer.queue_untagged(server, "* 2 EXISTS")

    assert {:ok, %{other_lines: ["* 2 EXISTS"]}} =
             fetch_envelopes(connection, [4])
  end

  # Pins the exact read-only request independently of the fake.
  test "sends one ENVELOPE and INTERNALDATE FETCH and skips FLAGS-only and NIL-envelope entries" do
    peer =
      start_supervised!(
        {Peer,
         script: fn socket ->
           :ok = :gen_tcp.send(socket, "* OK ready\r\n")

           "A1 UID FETCH 40,41,42 (UID ENVELOPE INTERNALDATE)" = Peer.line(socket)

           :ok =
             :gen_tcp.send(socket, [
               ~s|* 1 FETCH (UID 40 ENVELOPE (NIL "Hi" NIL NIL NIL NIL NIL NIL NIL NIL) |,
               ~s|INTERNALDATE "17-Jul-2026 02:44:25 -0700")\r\n|,
               "* 2 FETCH (UID 41 FLAGS (\\Seen))\r\n",
               ~s|* 3 FETCH (UID 42 ENVELOPE NIL INTERNALDATE "17-Jul-2026 02:44:25 -0700")\r\n|,
               "* 3 EXISTS\r\nA1 OK done\r\n"
             ])

           SocketWait.recv(:gen_tcp, socket)
         end}
      )

    {:ok, connection} = start_link()

    :ok =
      connect(connection, %{host: "127.0.0.1", port: Peer.port(peer), use_tls: false})

    assert {:ok, %{envelopes: envelopes, other_lines: ["* 3 EXISTS"]}} =
             fetch_envelopes(connection, [40, 41, 42])

    assert Map.keys(envelopes) == [40]

    assert %{uid: 40, internal_date_ms: 1_784_281_465_000, envelope: %{subject: "Hi"}} =
             envelopes[40]
  end

  test "fetches only arrival dates, read-only, for the UIDs that came back" do
    server =
      start_supervised!(
        {FakeServer,
         mailboxes: %{
           "INBOX" => %{
             messages: [message(4), message(5, %{internal_date: "not a date"}), message(6)]
           }
         }}
      )

    connection = open(server)

    assert {:ok, %{dates: dates, other_lines: []}} =
             fetch_internal_dates(connection, [4, 5, 6, 9])

    assert dates == %{4 => 1_770_116_706_000, 6 => 1_770_116_706_000}
    assert {:ok, %{dates: %{}}} = fetch_internal_dates(connection, [])
    assert FakeServer.mailbox(server, "INBOX").messages |> Enum.all?(&(&1.flags == []))
  end

  test "formats a SEARCH date as the UTC day" do
    assert search_date(0) == "1-Jan-1970"
    assert search_date(1_770_116_706_000) == "3-Feb-2026"
    # 23:30 on Oct 4 in UTC-7 is already Oct 5 in UTC.
    assert search_date(1_791_181_800_000) == "5-Oct-2026"
  end
end
