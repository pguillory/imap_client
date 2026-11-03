defmodule IMAPClient.ConnectionWireTest do
  use ExUnit.Case, async: true

  import IMAPClient

  alias IMAPClient.Error
  alias IMAPClient.Peer
  alias IMAPClient.SocketWait

  defp connected(script, opts \\ []) do
    peer = start_supervised!({Peer, script: script})

    defaults = [
      owner: self(),
      timeouts: [
        command_ms: 2_000,
        body_fetch_ms: 2_000,
        append_ms: 2_000,
        greeting_ms: 2_000
      ]
    ]

    connection = start_supervised!({IMAPClient, Keyword.merge(defaults, opts)})

    :ok =
      connect(connection, %{host: "127.0.0.1", port: Peer.port(peer), use_tls: false})

    connection
  end

  test "sends Unicode APPEND in exact octets only after continuation and a separate final CRLF" do
    parent = self()
    bytes = "Subject: résumé\r\n\r\n" <> String.duplicate("x", 70_000)

    connection =
      connected(fn socket ->
        :ok = :gen_tcp.send(socket, "* OK ready\r\n")
        expected = ~s|A1 APPEND "Drafts" (\\Seen \\Draft) {#{byte_size(bytes)}}|
        ^expected = Peer.line(socket)
        :ok = :gen_tcp.send(socket, "+ OK send literal\r\n")
        {:ok, received} = SocketWait.recv(:gen_tcp, socket, byte_size(bytes))
        {:ok, "\r\n"} = SocketWait.recv(:gen_tcp, socket, 2)
        send(parent, {:literal, received})
        :ok = :gen_tcp.send(socket, "A1 OK appended\r\n")
        SocketWait.recv(:gen_tcp, socket)
      end)

    assert :ok = append(connection, "Drafts", bytes, flags: ["\\Seen", "\\Draft"])
    assert_receive {:literal, ^bytes}
  end

  test "never sends APPEND literal bytes after refusal" do
    parent = self()

    connection =
      connected(fn socket ->
        :ok = :gen_tcp.send(socket, "* OK ready\r\n")
        "A1 APPEND \"Drafts\" (\\Seen \\Draft) {6}" = Peer.line(socket)
        :ok = :gen_tcp.send(socket, "A1 NO [OVERQUOTA] refused\r\n")
        send(parent, {:after_refusal, SocketWait.recv(:gen_tcp, socket)})
      end)

    assert {:error, %Error{code: :no, response_code: "OVERQUOTA"}} =
             append(connection, "Drafts", "secret", flags: ["\\Seen", "\\Draft"])

    assert :ok = close(connection)
    assert_receive {:after_refusal, {:error, :closed}}
  end

  test "poisons premature literal success and continuation after payload" do
    for response <- ["A1 OK premature\r\n", "+ next\r\n"] do
      peer =
        start_supervised!(
          {Peer,
           script: fn socket ->
             :ok = :gen_tcp.send(socket, "* OK ready\r\n")
             Peer.line(socket)

             if String.starts_with?(response, "+") do
               :ok = :gen_tcp.send(socket, "+ first\r\n")
               {:ok, "a\r\n"} = SocketWait.recv(:gen_tcp, socket, 3)
             end

             :ok = :gen_tcp.send(socket, response)
             SocketWait.recv(:gen_tcp, socket)
           end},
          id: make_ref()
        )

      connection = start_supervised!({IMAPClient, owner: self()}, id: make_ref())

      :ok =
        connect(connection, %{host: "127.0.0.1", port: Peer.port(peer), use_tls: false})

      assert {:error, %Error{code: :protocol, outcome_unknown?: true}} =
               append(connection, "Drafts", "a", flags: ["\\Seen", "\\Draft"])

      refute live?(connection)
    end
  end

  test "sends multiple SEARCH UTF-8 literals with one continuation each" do
    connection =
      connected(fn socket ->
        :ok = :gen_tcp.send(socket, "* OK ready\r\n")
        "A1 UID SEARCH CHARSET UTF-8 ALL FROM {4}" = Peer.line(socket)
        :ok = :gen_tcp.send(socket, "+ NO continuation prose\r\n")
        {:ok, "Zoë"} = SocketWait.recv(:gen_tcp, socket, 4)
        " SUBJECT {6}" = Peer.line(socket)
        :ok = :gen_tcp.send(socket, "+ BAD continuation prose\r\n")
        {:ok, "你好"} = SocketWait.recv(:gen_tcp, socket, 6)
        " UNSEEN" = Peer.line(socket)
        :ok = :gen_tcp.send(socket, "* SEARCH 7\r\nA1 OK done\r\n")
        SocketWait.recv(:gen_tcp, socket)
      end)

    segments = [
      "CHARSET UTF-8 ALL FROM ",
      {:literal, "Zoë"},
      " SUBJECT ",
      {:literal, "你好"},
      " UNSEEN"
    ]

    assert search_uids(connection, segments) == {:ok, [7]}
  end

  test "SPECIAL-USE falls back once only after BAD and discards partial rows" do
    connection =
      connected(fn socket ->
        :ok = :gen_tcp.send(socket, "* OK ready\r\n")
        ~s|A1 LIST "" "*" RETURN (SPECIAL-USE)| = Peer.line(socket)
        :ok = :gen_tcp.send(socket, "* LIST (\\Drafts) \"/\" \"Wrong\"\r\nA1 BAD unsupported\r\n")
        ~s|A2 LIST "" "*"| = Peer.line(socket)
        :ok = :gen_tcp.send(socket, "* LIST (\\Drafts) \"/\" \"Drafts\"\r\nA2 OK done\r\n")
        SocketWait.recv(:gen_tcp, socket)
      end)

    assert list_special_use(connection) ==
             {:ok, [%{name: "Drafts", flags: ["\\Drafts"], delimiter: "/"}]}
  end

  test "strict SPECIAL-USE refuses literal mailbox names" do
    connection =
      connected(fn socket ->
        :ok = :gen_tcp.send(socket, "* OK ready\r\n")
        Peer.line(socket)
        :ok = :gen_tcp.send(socket, "* LIST (\\Drafts) NIL {6}\r\nDrafts\r\nA1 OK done\r\n")
        SocketWait.recv(:gen_tcp, socket)
      end)

    assert {:error, %Error{code: :protocol}} = list_special_use(connection)
    refute live?(connection)
  end

  test "malformed Drafts and oversized metadata poison the session" do
    for {operation, response, expected_code} <- [
          {:list, "* LIST (\\Drafts) \"/\"\r\nA1 OK done\r\n", :protocol},
          {:fetch, "* 1 FETCH (UID 1 ENVELOPE ({1048577}\r\n", :response_too_large}
        ] do
      peer =
        start_supervised!(
          {Peer,
           script: fn socket ->
             :ok = :gen_tcp.send(socket, "* OK ready\r\n")
             Peer.line(socket)
             :ok = :gen_tcp.send(socket, response)
             SocketWait.recv(:gen_tcp, socket)
           end},
          id: make_ref()
        )

      connection = start_supervised!({IMAPClient, owner: self()}, id: make_ref())

      :ok =
        connect(connection, %{host: "127.0.0.1", port: Peer.port(peer), use_tls: false})

      result =
        if operation == :list,
          do: list_special_use(connection),
          else: fetch(connection, [1], "ENVELOPE")

      assert {:error, %Error{code: ^expected_code}} = result
      refute live?(connection)
    end
  end

  test "BODY bound and EOF mid-literal cannot leave reusable response bytes" do
    for {tail, expected_code} <- [
          {"* 1 FETCH (UID 1 BODY[1] {8}\r\n", :response_too_large},
          {"* 1 FETCH (UID 1 BODY[1] {3}\r\na", :closed}
        ] do
      peer =
        start_supervised!(
          {Peer,
           script: fn socket ->
             :ok = :gen_tcp.send(socket, "* OK ready\r\n")
             Peer.line(socket)
             :ok = :gen_tcp.send(socket, tail)
             if expected_code == :response_too_large, do: SocketWait.recv(:gen_tcp, socket)
           end},
          id: make_ref()
        )

      connection =
        start_supervised!({IMAPClient, owner: self(), max_body_literal_bytes: 4}, id: make_ref())

      :ok =
        connect(connection, %{host: "127.0.0.1", port: Peer.port(peer), use_tls: false})

      assert {:error, %Error{code: ^expected_code}} = fetch_body(connection, 1, "1")
      refute live?(connection)
    end
  end

  test "EXAMINE requires positive UIDVALIDITY and UIDNEXT and SEARCH preserves omission" do
    connection =
      connected(fn socket ->
        :ok = :gen_tcp.send(socket, "* OK ready\r\n")
        ~s|A1 EXAMINE "INBOX"| = Peer.line(socket)

        :ok =
          :gen_tcp.send(
            socket,
            "* OK [UIDVALIDITY 7] valid\r\n* OK [UIDNEXT 42] next\r\nA1 OK done\r\n"
          )

        "A2 UID SEARCH ALL" = Peer.line(socket)
        :ok = :gen_tcp.send(socket, "A2 OK no data\r\n")
        SocketWait.recv(:gen_tcp, socket)
      end)

    assert {:ok, %{uid_validity: 7, uid_next: 42}} = examine(connection, "INBOX")
    assert {:ok, %{uids: nil, lines: []}} = search_strict(connection, "ALL")
  end

  test "command injection is refused before emitting any bytes" do
    parent = self()

    connection =
      connected(fn socket ->
        :ok = :gen_tcp.send(socket, "* OK ready\r\n")
        send(parent, {:remaining, SocketWait.recv(:gen_tcp, socket)})
      end)

    assert {:error, %Error{code: :invalid_argument}} =
             select(connection, "INBOX\r\nDELETE INBOX")

    assert {:error, %Error{code: :invalid_argument}} =
             append(connection, "Drafts\n", "hello", flags: ["\\Seen", "\\Draft"])

    # The raw name is checked before modified UTF-7 encoding could hide a line break.
    assert {:error, %Error{code: :invalid_argument}} =
             examine(connection, "Envoyés\r\nDELETE INBOX")

    assert {:error, %Error{code: :invalid_argument}} =
             copy(connection, [1], "Archive" <> <<0>>)

    assert {:error, %Error{code: :invalid_argument}} =
             move_uids(connection, [1], "Archive\r")

    assert {:error, %Error{code: :invalid_argument}} =
             store(connection, [1], "\\Seen) DELETE INBOX", "+")

    assert {:error, %Error{code: :invalid_argument}} =
             store(connection, [1], "\\Seen\n", "+")

    assert {:error, %Error{code: :invalid_argument}} = fetch_body(connection, 1, "1\n")

    assert :ok = close(connection)
    assert_receive {:remaining, {:error, :closed}}
  end
end
