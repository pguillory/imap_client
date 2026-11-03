defmodule IMAPClient.ConnectionTest do
  use ExUnit.Case, async: true

  import IMAPClient

  alias IMAPClient.Error
  alias IMAPClient.Peer
  alias IMAPClient.SocketWait

  defp connected(script, opts \\ []) do
    peer = start_supervised!({Peer, script: script})

    connection =
      start_supervised!(
        {IMAPClient,
         Keyword.merge(
           [
             owner: self(),
             timeouts: [
               command_ms: 2_000,
               body_fetch_ms: 2_000,
               greeting_ms: 2_000,
               authentication_ms: 2_000,
               logout_ms: 5_000
             ]
           ],
           opts
         )}
      )

    :ok =
      connect(connection, %{host: "127.0.0.1", port: Peer.port(peer), use_tls: false})

    connection
  end

  test "sends escaped LOGIN and SELECT then exact UID commands and expected LOGOUT BYE" do
    parent = self()

    connection =
      connected(fn socket ->
        :ok = :gen_tcp.send(socket, "* OK ready\r\n")

        for {command, response} <- [
              {~s|A1 LOGIN "a\\\"b" "app-password"|, "A1 OK logged in\r\n"},
              {~s|A2 SELECT "INBOX"|, "* 2 EXISTS\r\nA2 OK selected\r\n"},
              {"A3 UID SEARCH ALL", "* SEARCH 12 9\r\nA3 OK done\r\n"},
              {"A4 UID STORE 12 +FLAGS (\\Seen)", "A4 OK done\r\n"},
              {"A5 LOGOUT", "* BYE logging out\r\nA5 OK done\r\n"}
            ] do
          received = Peer.line(socket)
          send(parent, {:command, received})

          if received == command,
            do: :ok = :gen_tcp.send(socket, response),
            else: raise("unexpected test command")
        end
      end)

    assert :ok = login(connection, "a\"b", "app-password")
    assert :ok = select(connection, "INBOX")
    assert {:ok, [12, 9]} = search_uids(connection, "ALL")
    assert :ok = store(connection, [12], "\\Seen", "+")
    assert :ok = logout(connection)
    refute live?(connection)
    assert_receive {:command, ~s|A1 LOGIN "a\\\"b" "app-password"|}
  end

  test "frames fragmented binary BODY payload and validates its UID" do
    bytes = "A1 OK body\r\n" <> <<0, 255>>

    connection =
      connected(fn socket ->
        :ok = :gen_tcp.send(socket, "* OK ready\r\n")
        "A1 UID FETCH 7 (BODY.PEEK[1])" = Peer.line(socket)

        wire =
          "* OK note {999}\r\n* 1 FETCH (BODY[1] {#{byte_size(bytes)}}\r\n" <>
            bytes <> " UID 7 FLAGS (\\Seen))\r\nA1 OK done\r\n"

        for <<byte <- wire>>, do: :ok = :gen_tcp.send(socket, <<byte>>)
        SocketWait.recv(:gen_tcp, socket)
      end)

    assert fetch_body(connection, 7, "1") == {:ok, bytes}
    assert live?(connection)
  end

  test "missing body differs from NIL and an empty quoted body" do
    connection =
      connected(fn socket ->
        :ok = :gen_tcp.send(socket, "* OK ready\r\n")

        for {tag, body} <- [
              {"A1", ""},
              {"A2", "* 1 FETCH (UID 7 BODY[1] NIL)\r\n"},
              {"A3", "* 1 FETCH (UID 7 BODY[1] \"\")\r\n"}
            ] do
          expected = "#{tag} UID FETCH 7 (BODY.PEEK[1])"
          ^expected = Peer.line(socket)
          :ok = :gen_tcp.send(socket, body <> "#{tag} OK done\r\n")
        end

        SocketWait.recv(:gen_tcp, socket)
      end)

    assert {:error, %Error{code: :no_data}} = fetch_body(connection, 7, "1")
    assert fetch_body(connection, 7, "1") == {:ok, ""}
    assert fetch_body(connection, 7, "1") == {:ok, ""}
  end

  test "tagged refusal preserves session and classifies login rejection safely" do
    connection =
      connected(fn socket ->
        :ok = :gen_tcp.send(socket, "* OK ready\r\n")
        Peer.line(socket)
        :ok = :gen_tcp.send(socket, "A1 NO [AUTHENTICATIONFAILED] Invalid credentials secret\r\n")
        "A2 CAPABILITY" = Peer.line(socket)
        :ok = :gen_tcp.send(socket, "* CAPABILITY imap4rev1 IDLE\r\nA2 OK done\r\n")
        SocketWait.recv(:gen_tcp, socket)
      end)

    assert {:error, %Error{code: :auth_rejected} = error} = login(connection, "a", "b")
    refute Exception.message(error) =~ "secret"
    assert {:ok, capabilities} = capabilities(connection)
    assert capabilities == MapSet.new(["IMAP4REV1", "IDLE"])
  end

  test "foreign completion poisons immediately instead of waiting for a deadline" do
    connection =
      connected(fn socket ->
        :ok = :gen_tcp.send(socket, "* OK ready\r\n")
        Peer.line(socket)
        :ok = :gen_tcp.send(socket, "A10 OK wrong tag\r\n")
        SocketWait.recv(:gen_tcp, socket)
      end)

    assert {:error, %Error{code: :protocol}} = search_uids(connection, "ALL")
    refute live?(connection)
    assert {:error, %Error{code: :closed}} = search_uids(connection, "ALL")
    assert :ok = close(connection)
  end

  test "command timeout poisons and reports ambiguous mutation outcome" do
    connection =
      connected(
        fn socket ->
          :ok = :gen_tcp.send(socket, "* OK ready\r\n")
          "A1 UID STORE 1 +FLAGS (\\Seen)" = Peer.line(socket)
          :gen_tcp.recv(socket, 0, 5_000)
        end,
        timeouts: [command_ms: 500]
      )

    assert {:error, %Error{code: :timeout, stage: :store, outcome_unknown?: true}} =
             store(connection, [1], "\\Seen", "+")

    refute live?(connection)
  end

  test "refuses overlapping commands at admission without queuing a mutation" do
    parent = self()

    connection =
      connected(fn socket ->
        :ok = :gen_tcp.send(socket, "* OK ready\r\n")
        "A1 UID SEARCH ALL" = Peer.line(socket)
        send(parent, :search_received)

        receive do
          :finish -> :ok
        end

        :ok = :gen_tcp.send(socket, "* SEARCH\r\nA1 OK done\r\n")
        SocketWait.recv(:gen_tcp, socket)
      end)

    start_supervised!({Task, fn -> send(parent, {:result, search_uids(connection, "ALL")}) end})

    assert_receive :search_received
    assert {:error, %Error{code: :busy}} = store(connection, [1], "\\Seen", "+")
    assert :ok = close(connection)
    assert_receive {:result, {:error, %Error{code: :closed}}}
  end
end
