defmodule IMAPClient.FakeServerTest do
  use ExUnit.Case, async: true

  import IMAPClient.FakeServer

  alias IMAPClient.FakeServer
  alias IMAPClient.SocketWait

  defp start_server(opts \\ []) do
    server = start_supervised!({FakeServer, opts})
    %{port: port} = endpoint(server)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 2_000)
    assert {:ok, "* OK fake ready\r\n"} = SocketWait.recv(:gen_tcp, socket)
    {server, socket}
  end

  defp command(socket, tag, command) do
    :ok = :gen_tcp.send(socket, [tag, " ", command, "\r\n"])
    completion(socket, tag, "")
  end

  defp completion(socket, tag, bytes) do
    if Regex.match?(~r/(?:^|\r\n)#{Regex.escape(tag)} (?:OK|NO|BAD)[^\r\n]*\r\n$/, bytes) do
      bytes
    else
      assert {:ok, next} = SocketWait.recv(:gen_tcp, socket)
      completion(socket, tag, bytes <> next)
    end
  end

  defp login(socket) do
    assert(command(socket, "a", "LOGIN \"fake-user\" \"fake-password\"") == "a OK completed\r\n")
  end

  defp message(uid, flags \\ []) do
    %{
      uid: uid,
      flags: flags,
      headers: "From: Sender <sender@example.test>\r\nSubject: Hello café\r\n\r\n",
      sections: %{"1" => "hello\r\nworld", "TEXT" => "hello world"},
      internal_date: "03-Feb-2026 04:05:06 +0000"
    }
  end

  test "authentication and selected-mailbox states are enforced" do
    {server, socket} = start_server()
    assert command(socket, "b", "UID SEARCH ALL") == "b NO completed\r\n"
    assert command(socket, "c", "SELECT INBOX") == "c NO completed\r\n"

    assert command(socket, "d", "LOGIN fake-user wrong") ==
             "d NO [AUTHENTICATIONFAILED] completed\r\n"

    login(socket)
    assert command(socket, "e", "UID SEARCH ALL") == "e BAD completed\r\n"

    assert command(socket, "f", "LOGIN fake-user fake-password") ==
             "f NO [AUTHENTICATIONFAILED] completed\r\n"

    assert command(socket, "g", "SELECT Missing") == "g NO [NONEXISTENT] completed\r\n"
    assert command(socket, "h", "SELECT INBOX") =~ "h OK [READ-WRITE]"
    assert command(socket, "i", "UID SEARCH ALL") == "* SEARCH\r\ni OK completed\r\n"
    assert %{uid_next: 1} = mailbox(server, "INBOX")
  end

  test "AUTHENTICATE, NOOP and STATUS follow their states, and a malformed AUTHENTICATE is BAD" do
    {server, socket} = start_server(mailboxes: %{"INBOX" => %{messages: [message(1)]}})
    assert command(socket, "a", "STATUS INBOX (MESSAGES)") == "a NO completed\r\n"
    assert command(socket, "b", "AUTHENTICATE (PLAIN)") == "b BAD completed\r\n"
    assert command(socket, "c", "AUTHENTICATE CRAM-MD5") == "c NO completed\r\n"
    assert command(socket, "d", "NOOP") == "d OK completed\r\n"

    :ok = :gen_tcp.send(socket, "e AUTHENTICATE PLAIN\r\n")
    assert {:ok, "+ \r\n"} = SocketWait.recv(:gen_tcp, socket)
    :ok = :gen_tcp.send(socket, [Base.encode64("\0fake-user\0fake-password"), "\r\n"])
    assert completion(socket, "e", "") == "e OK completed\r\n"

    assert command(socket, "f", "STATUS INBOX (MESSAGES UNSEEN)") ==
             "* STATUS \"INBOX\" (MESSAGES 1 UNSEEN 1)\r\nf OK completed\r\n"

    assert Process.alive?(server)
  end

  test "read-only mailbox refuses STORE, MOVE and UID EXPUNGE" do
    {server, socket} =
      start_server(mailboxes: %{"INBOX" => %{messages: [message(7)]}, "Archive" => %{}})

    login(socket)
    assert command(socket, "b", "EXAMINE INBOX") =~ "[READ-ONLY]"
    assert command(socket, "c", "UID STORE 7 +FLAGS.SILENT (\\Seen)") == "c NO completed\r\n"
    assert command(socket, "d", "UID MOVE 7 Archive") == "d NO completed\r\n"
    assert command(socket, "e", "UID EXPUNGE 7") == "e NO completed\r\n"
    assert [%{flags: []}] = mailbox(server, "INBOX").messages
  end

  test "capabilities gate extension commands and support LIST fallback" do
    {_server, socket} = start_server(capabilities: ["IMAP4rev1"])
    login(socket)
    command(socket, "b", "SELECT INBOX")
    assert command(socket, "c", "CAPABILITY") == "* CAPABILITY IMAP4REV1\r\nc OK completed\r\n"
    assert command(socket, "d", "UID MOVE 1 Archive") == "d BAD completed\r\n"
    assert command(socket, "e", "UID EXPUNGE 1") == "e BAD completed\r\n"
    assert command(socket, "f", "IDLE") == "f BAD completed\r\n"
    assert command(socket, "g", "LIST \"\" \"*\" RETURN (SPECIAL-USE)") == "g BAD completed\r\n"

    assert command(socket, "h", "LIST \"\" \"*\"") ==
             "* LIST () \"/\" \"INBOX\"\r\nh OK completed\r\n"
  end

  test "UID search criteria use message state, conjunctions, dates, and UID ranges" do
    {_server, socket} =
      start_server(
        mailboxes: %{"INBOX" => %{messages: [message(2), message(8, ["\\Seen"]), message(12)]}}
      )

    login(socket)
    command(socket, "b", "SELECT INBOX")

    assert command(
             socket,
             "c",
             "UID SEARCH ALL UNSEEN UID 12:2 SINCE 3-Feb-2026 BEFORE 4-Feb-2026"
           ) == "* SEARCH 2 12\r\nc OK completed\r\n"

    assert command(
             socket,
             "d",
             "UID SEARCH FROM \"sender@example.test\" SUBJECT \"café\" TEXT \"world\""
           ) == "* SEARCH 2 8 12\r\nd OK completed\r\n"

    assert command(socket, "e", "UID SEARCH UID 0") == "e BAD completed\r\n"
    assert command(socket, "f", "UID SEARCH UID 2:*") == "* SEARCH 2 8 12\r\nf OK completed\r\n"

    assert command(socket, "g", "UID SEARCH BEFORE 2-Feb-2026") ==
             "* SEARCH\r\ng OK completed\r\n"

    assert command(socket, "h", "UID SEARCH SINCE 31-Feb-2026") == "h BAD completed\r\n"
  end

  test "synchronizing search literals preserve UTF-8 octets and resume the command" do
    {_server, socket} = start_server(mailboxes: %{"INBOX" => %{messages: [message(1)]}})
    login(socket)
    command(socket, "b", "SELECT INBOX")
    :ok = :gen_tcp.send(socket, "c UID SEARCH CHARSET UTF-8 SUBJECT {5}\r\n")
    assert {:ok, "+ literal follows\r\n"} = SocketWait.recv(:gen_tcp, socket)
    :ok = :gen_tcp.send(socket, "café UNSEEN\r\n")
    assert completion(socket, "c", "") == "* SEARCH 1\r\nc OK completed\r\n"
  end

  test "FETCH emits real metadata and byte-counted body literals with a UID" do
    {_server, socket} = start_server(mailboxes: %{"INBOX" => %{messages: [message(9)]}})
    login(socket)
    command(socket, "b", "SELECT INBOX")

    assert command(socket, "c", "UID FETCH 9 (UID FLAGS ENVELOPE BODYSTRUCTURE INTERNALDATE)") =~
             "* 1 FETCH (UID 9 FLAGS () ENVELOPE (NIL NIL NIL NIL NIL NIL NIL NIL NIL NIL)"

    assert command(socket, "d", "UID FETCH 9 (BODY.PEEK[1])") ==
             "* 1 FETCH (UID 9 BODY[1] {12}\r\nhello\r\nworld)\r\nd OK completed\r\n"

    assert command(socket, "e", "UID FETCH 9 (BODY.PEEK[HEADER.FIELDS (LIST-UNSUBSCRIBE)])") =~
             "BODY[HEADER.FIELDS (LIST-UNSUBSCRIBE)] {"

    assert command(socket, "f", "UID FETCH 9 (BOGUS)") == "f BAD completed\r\n"
  end

  test "STORE and UID EXPUNGE only remove targeted deleted messages" do
    {server, socket} =
      start_server(
        mailboxes: %{"INBOX" => %{messages: [message(2), message(7, ["\\Deleted"]), message(9)]}}
      )

    login(socket)
    command(socket, "b", "SELECT INBOX")

    assert command(socket, "c", "UID STORE 2 +FLAGS.SILENT (\\Seen \\Deleted)") ==
             "c OK completed\r\n"

    assert command(socket, "d", "UID EXPUNGE 2,9") == "* 1 EXPUNGE\r\nd OK completed\r\n"
    assert Enum.map(mailbox(server, "INBOX").messages, & &1.uid) == [7, 9]
    assert command(socket, "e", "EXPUNGE") == "e BAD completed\r\n"
  end

  test "COPY and MOVE assign destination UIDs monotonically" do
    {server, socket} =
      start_server(
        mailboxes: %{
          "INBOX" => %{messages: [message(2), message(7)]},
          "Archive" => %{uid_next: 20}
        }
      )

    login(socket)
    command(socket, "b", "SELECT INBOX")
    assert command(socket, "c", "UID COPY 2 Missing") == "c NO [TRYCREATE] completed\r\n"
    assert command(socket, "d", "UID COPY 2 Archive") == "d OK completed\r\n"
    assert command(socket, "e", "UID MOVE 7 Archive") == "e OK completed\r\n"
    assert Enum.map(mailbox(server, "Archive").messages, & &1.uid) == [20, 21]
    assert Enum.map(mailbox(server, "INBOX").messages, & &1.uid) == [2]
    assert mailbox(server, "Archive").uid_next == 22
  end

  test "APPEND counts binary octets, requires its trailer and redacts message and login data" do
    {server, socket} = start_server()
    login(socket)
    body = <<0, 255, 13, 10>> <> "café"

    :ok =
      :gen_tcp.send(socket, [
        "b APPEND INBOX (\\Seen \\Draft) {",
        to_string(byte_size(body)),
        "}\r\n"
      ])

    assert {:ok, "+ literal follows\r\n"} = SocketWait.recv(:gen_tcp, socket)
    :ok = :gen_tcp.send(socket, [body, "\r\n"])
    assert completion(socket, "b", "") == "b OK [APPENDUID 1 1] completed\r\n"

    assert [%{uid: 1, flags: ["\\Seen", "\\Draft"], sections: %{"" => ^body}}] =
             mailbox(server, "INBOX").messages

    assert commands(server) == [%{command: :login}, %{command: :append}]
    assert mailbox(server, "INBOX").uid_next == 2
  end

  test "APPEND refuses unauthenticated literal before granting continuation" do
    {_server, socket} = start_server()
    :ok = :gen_tcp.send(socket, "b APPEND INBOX (\\Draft) {4}\r\n")
    assert {:ok, "b NO command state invalid\r\n"} = SocketWait.recv(:gen_tcp, socket)
  end

  test "literal bytes sent before the continuation close the misbehaving peer" do
    {_server, socket} = start_server()
    login(socket)
    :ok = :gen_tcp.send(socket, "b APPEND INBOX (\\Draft) {4}\r\nmail\r\n")
    assert {:ok, "* BAD literal before continuation\r\n"} = SocketWait.recv(:gen_tcp, socket)
    assert {:error, :closed} = SocketWait.recv(:gen_tcp, socket)
  end

  test "malformed quoted strings, lists and bare protocol newlines are refused" do
    {_server, socket} = start_server()

    for bytes <- [
          "b LOGIN \"unterminated x\r\n",
          "b LOGIN (x\r\n",
          "b LOGIN \"bad\\q\" x\r\n",
          "b LOGIN x\ny z\r\n",
          "b LOGIN \"fake-user\"\"fake-password\"\r\n"
        ] do
      :ok = :gen_tcp.send(socket, bytes)
      assert {:ok, "* BAD malformed command\r\n"} = SocketWait.recv(:gen_tcp, socket)
    end
  end

  test "IDLE pushes socket events, rejects commands, and DONE owns its original completion" do
    {server, socket} = start_server()
    login(socket)
    command(socket, "b", "SELECT INBOX")
    :ok = :gen_tcp.send(socket, "c IDLE\r\n")
    assert {:ok, "+ idling\r\n"} = SocketWait.recv(:gen_tcp, socket)
    assert :ok = push_idle(server, "* 2 EXISTS")
    assert {:ok, "* 2 EXISTS\r\n"} = SocketWait.recv(:gen_tcp, socket)
    assert command(socket, "d", "UID SEARCH ALL") == "d BAD completed\r\n"
    :ok = :gen_tcp.send(socket, "DONE\r\n")
    assert completion(socket, "c", "") == "c OK completed\r\n"
    assert command(socket, "e", "UID SEARCH ALL") == "* SEARCH\r\ne OK completed\r\n"
    assert {:error, :invalid_update} = push_idle(server, "* 3 EXISTS\r\n* BYE")
  end

  test "failure scripting is command-scoped and missing SEARCH differs from an empty result" do
    {server, socket} = start_server()
    assert :ok = script_next(server, :search, {:omit, :search})
    assert :ok = script_next(server, :list, {:refuse, :no, "UNAVAILABLE"})
    login(socket)
    command(socket, "b", "SELECT INBOX")
    assert command(socket, "c", "UID SEARCH ALL") == "c OK completed\r\n"
    assert command(socket, "d", "UID SEARCH ALL") == "* SEARCH\r\nd OK completed\r\n"
    assert command(socket, "e", "LIST \"\" \"*\"") == "e NO [UNAVAILABLE] completed\r\n"

    assert {:error, :invalid_script} =
             script_next(server, :list, {:refuse, :no, "injected\r\n"})
  end

  test "a held response waits for release while the server serves other connections" do
    {server, socket} = start_server(mailboxes: %{"INBOX" => %{messages: [message(1)]}})
    %{port: port} = endpoint(server)
    assert :ok = script_next(server, :search, {:hold, self()})
    login(socket)
    command(socket, "b", "SELECT INBOX")
    :ok = queue_untagged(server, "* 1 EXISTS")
    :ok = :gen_tcp.send(socket, "c UID SEARCH ALL\r\n")
    assert_receive {:imap_fake_held, held}

    # The command ran (history has it), its response waits, and another connection
    # signs in and is answered meanwhile.
    assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 100)
    assert :search in Enum.map(commands(server), & &1.command)
    {:ok, other} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 2_000)
    assert {:ok, "* OK fake ready\r\n"} = SocketWait.recv(:gen_tcp, other)
    login(other)

    # Sent while held: answered after the held response, in order. The untagged line
    # queued before the held command goes out with its response.
    :ok = :gen_tcp.send(socket, "d UID SEARCH ALL\r\n")
    :ok = release(held)

    assert completion(socket, "d", "") ==
             "* 1 EXISTS\r\n* SEARCH 1\r\nc OK completed\r\n* SEARCH 1\r\nd OK completed\r\n"

    assert {:error, :invalid_script} = script_next(server, :logout, {:hold, self()})
  end

  test "a held response is released when its owner exits, and a disconnect ends it" do
    {server, socket} = start_server()
    test = self()

    owner =
      spawn(fn ->
        :ok = script_next(server, :list, {:hold, self()})
        send(test, :scripted)
        assert_receive {:imap_fake_held, _held}
        send(test, :held)
      end)

    assert_receive :scripted
    login(socket)
    :ok = :gen_tcp.send(socket, "b LIST \"\" \"*\"\r\n")
    assert_receive :held
    ref = Process.monitor(owner)
    assert_receive {:DOWN, ^ref, :process, ^owner, _}
    assert completion(socket, "b", "") =~ "b OK completed"

    # Held again, then the client goes away: the connection ends without a release.
    assert :ok = script_next(server, :list, {:hold, self()})
    :ok = :gen_tcp.send(socket, "c LIST \"\" \"*\"\r\n")
    assert_receive {:imap_fake_held, {peer, _ref}}
    peer_ref = Process.monitor(peer)
    :gen_tcp.close(socket)
    assert_receive {:DOWN, ^peer_ref, :process, ^peer, _}
  end

  test "message removal and omitted fetch responses model search-fetch races" do
    {server, socket} =
      start_server(mailboxes: %{"INBOX" => %{messages: [message(1), message(2)]}})

    login(socket)
    command(socket, "b", "SELECT INBOX")
    assert command(socket, "c", "UID SEARCH ALL") == "* SEARCH 1 2\r\nc OK completed\r\n"
    assert :ok = remove_message(server, "INBOX", 1)

    assert command(socket, "d", "UID FETCH 1,2 (UID FLAGS)") ==
             "* 1 FETCH (UID 2 FLAGS ())\r\nd OK completed\r\n"

    assert :ok = script_next(server, :fetch, {:omit, :metadata})
    assert command(socket, "e", "UID FETCH 2 (UID FLAGS)") == "e OK completed\r\n"
    assert :ok = script_next(server, :fetch, {:omit, :body})
    assert command(socket, "f", "UID FETCH 2 (BODY.PEEK[1])") == "f OK completed\r\n"
  end

  test "metadata omission recognizes HEADER.FIELDS and filters requested header names" do
    mail = %{
      message(1)
      | headers:
          "From: sender@example.test\r\nList-Unsubscribe: <https://example.test/unsubscribe>\r\n folded\r\nSubject: hello\r\n\r\n"
    }

    {server, socket} = start_server(mailboxes: %{"INBOX" => %{messages: [mail]}})
    login(socket)
    command(socket, "b", "SELECT INBOX")

    response =
      command(
        socket,
        "c",
        "UID FETCH 1 (FLAGS ENVELOPE BODYSTRUCTURE BODY.PEEK[HEADER.FIELDS (List-Unsubscribe)])"
      )

    assert response =~ "List-Unsubscribe: <https://example.test/unsubscribe>\r\n folded\r\n\r\n"
    refute response =~ "From:"
    refute response =~ "Subject:"
    assert :ok = script_next(server, :fetch, {:omit, :metadata})

    assert command(
             socket,
             "d",
             "UID FETCH 1 (FLAGS ENVELOPE BODYSTRUCTURE BODY.PEEK[HEADER.FIELDS (List-Unsubscribe)])"
           ) == "d OK completed\r\n"

    assert command(socket, "e", "UID FETCH 1 (BODY.PEEK[999])") ==
             "* 1 FETCH (UID 1 BODY[999] NIL)\r\ne OK completed\r\n"
  end

  test "search-fetched disappearance can be scripted before FETCH and UIDs are never reused" do
    {server, socket} = start_server(mailboxes: %{"INBOX" => %{messages: [message(1)]}})
    login(socket)
    command(socket, "b", "SELECT INBOX")
    assert :ok = script_next(server, :fetch, {:remove, "INBOX", 1})
    assert command(socket, "c", "UID SEARCH ALL") == "* SEARCH 1\r\nc OK completed\r\n"
    assert command(socket, "d", "UID FETCH 1 (UID FLAGS)") == "d OK completed\r\n"
    assert mailbox(server, "INBOX").uid_next == 2
  end

  test "APPEND bytes without the required trailing CRLF do not create a message" do
    {server, socket} = start_server()
    login(socket)
    :ok = :gen_tcp.send(socket, "b APPEND INBOX (\\Draft) {4}\r\n")
    assert {:ok, "+ literal follows\r\n"} = SocketWait.recv(:gen_tcp, socket)
    :ok = :gen_tcp.send(socket, "mailc CAPABILITY\r\n")
    assert {:ok, "* BAD malformed command\r\n"} = SocketWait.recv(:gen_tcp, socket)
    assert mailbox(server, "INBOX").messages == []
  end

  test "body failure scripts skip metadata FETCH and still preserve command history" do
    {server, socket} = start_server(mailboxes: %{"INBOX" => %{messages: [message(1)]}})
    login(socket)
    command(socket, "b", "SELECT INBOX")
    assert :ok = script_next(server, :fetch_body, {:omit, :body})

    assert command(
             socket,
             "c",
             "UID FETCH 1 (UID FLAGS BODY.PEEK[HEADER.FIELDS (List-Unsubscribe)])"
           ) =~ "UID 1 FLAGS ()"

    assert command(socket, "d", "UID FETCH 1 (BODY.PEEK[1])") == "d OK completed\r\n"
    assert command(socket, "e", "UID FETCH 1 (BODY.PEEK[1])") =~ "hello\r\nworld"

    assert Enum.take(commands(server), -3) ==
             List.duplicate(%{command: :fetch, uid_set: "1"}, 3)
  end

  test "UID wildcard remains relative to the mailbox after other SEARCH filters" do
    {_, socket} =
      start_server(mailboxes: %{"INBOX" => %{messages: [message(1), message(9, ["\\Seen"])]}})

    login(socket)
    command(socket, "b", "SELECT INBOX")
    assert command(socket, "c", "UID SEARCH UNSEEN UID *") == "* SEARCH\r\nc OK completed\r\n"

    assert command(socket, "d", "uid search charset utf-8 unseen uid 1:9") ==
             "* SEARCH 1\r\nd OK completed\r\n"
  end

  test "envelope-only SEARCH uses the specified field" do
    message =
      Map.merge(message(1), %{
        headers: "",
        envelope:
          "NIL \"Meeting\" ((\"Sender\" NIL \"sender\" \"example.test\")) NIL NIL NIL NIL NIL NIL NIL"
      })

    {_, socket} = start_server(mailboxes: %{"INBOX" => %{messages: [message]}})
    login(socket)
    command(socket, "b", "SELECT INBOX")

    assert command(socket, "c", "UID SEARCH FROM \"sender@example.test\" SUBJECT Meeting") ==
             "* SEARCH 1\r\nc OK completed\r\n"

    assert command(socket, "d", "UID SEARCH FROM Meeting") == "* SEARCH\r\nd OK completed\r\n"
  end

  test "server status redacts credentials and mail and stopping it closes accepted sockets" do
    {server, socket} = start_server(name: nil, mailboxes: %{"INBOX" => %{messages: [message(1)]}})
    status = inspect(:sys.get_status(server), limit: :infinity)
    refute status =~ "fake-password"
    refute status =~ "sender@example.test"
    assert :ok = stop_supervised(FakeServer)
    assert {:error, :closed} = SocketWait.recv(:gen_tcp, socket)
  end

  test "scripted transport closure and LOGOUT close sockets" do
    {server, socket} = start_server()
    login(socket)
    assert :ok = script_next(server, :capability, :close)
    :ok = :gen_tcp.send(socket, "b CAPABILITY\r\n")
    assert {:error, :closed} = SocketWait.recv(:gen_tcp, socket)
    %{port: port} = endpoint(server)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 2_000)
    assert {:ok, _} = SocketWait.recv(:gen_tcp, socket)
    assert command(socket, "c", "LOGOUT") == "* BYE closing\r\nc OK completed\r\n"
    assert {:error, :closed} = SocketWait.recv(:gen_tcp, socket)
  end

  test "failed SELECT and EXAMINE attempts deselect the previous mailbox" do
    {server, socket} = start_server(mailboxes: %{"INBOX" => %{messages: [message(1)]}})
    login(socket)
    command(socket, "b", "SELECT INBOX")
    assert command(socket, "c", "SELECT Missing") == "c NO [NONEXISTENT] completed\r\n"
    assert command(socket, "d", "UID SEARCH ALL") == "d BAD completed\r\n"

    for kind <- [:select, :examine] do
      command(socket, "e", "SELECT INBOX")
      assert :ok = script_next(server, kind, {:refuse, :no, nil})

      assert command(socket, "f", String.upcase(Atom.to_string(kind)) <> " INBOX") ==
               "f NO completed\r\n"

      assert command(socket, "g", "UID STORE 1 +FLAGS.SILENT (\\Deleted)") ==
               "g BAD completed\r\n"
    end

    assert [%{flags: []}] = mailbox(server, "INBOX").messages
  end

  test "STORE validates flags and canonicalizes system-flag case" do
    {server, socket} = start_server(mailboxes: %{"INBOX" => %{messages: [message(1)]}})
    login(socket)
    command(socket, "b", "SELECT INBOX")

    assert command(socket, "c", ~s|UID STORE 1 +FLAGS.SILENT ("bad flag")|) ==
             "c BAD completed\r\n"

    assert command(socket, "d", "UID STORE 1 +FLAGS.SILENT (\\Recent)") == "d BAD completed\r\n"
    assert command(socket, "e", "UID STORE 1 +FLAGS.SILENT (\\sEeN)") == "e OK completed\r\n"
    assert [%{flags: ["\\Seen"]}] = mailbox(server, "INBOX").messages
    assert command(socket, "f", "UID SEARCH UNSEEN") == "* SEARCH\r\nf OK completed\r\n"
    assert command(socket, "g", "UID STORE 1 -FLAGS.SILENT (\\seen)") == "g OK completed\r\n"
    assert command(socket, "h", "UID SEARCH UNSEEN") == "* SEARCH 1\r\nh OK completed\r\n"

    :ok = :gen_tcp.send(socket, "i APPEND INBOX (\\sEeN \\dRaFt) {0}\r\n")
    assert {:ok, "+ literal follows\r\n"} = SocketWait.recv(:gen_tcp, socket)
    :ok = :gen_tcp.send(socket, "\r\n")
    assert completion(socket, "i", "") == "i OK [APPENDUID 1 2] completed\r\n"
    assert List.last(mailbox(server, "INBOX").messages).flags == ["\\Seen", "\\Draft"]
  end

  test "SEARCH requires a key and permits CHARSET only as one leading prefix" do
    {_, socket} = start_server()
    login(socket)
    command(socket, "b", "SELECT INBOX")

    for criteria <- [
          "",
          "CHARSET",
          "CHARSET UTF-8",
          "ALL CHARSET UTF-8 UNSEEN",
          "CHARSET UTF-8 CHARSET UTF-8 ALL"
        ] do
      assert command(socket, "c", "UID SEARCH " <> criteria) == "c BAD completed\r\n"
    end

    assert command(socket, "d", "UID SEARCH charset utf-8 ALL") ==
             "* SEARCH\r\nd OK completed\r\n"
  end

  test "LIST rejects an incorrectly nested RETURN extension" do
    {_, socket} = start_server()
    login(socket)
    assert command(socket, "b", ~s|LIST "" "*" (RETURN (SPECIAL-USE))|) == "b BAD completed\r\n"
    assert command(socket, "c", ~s|LIST "" "*" RETURN (SPECIAL-USE)|) =~ "c OK completed\r\n"
  end

  test "UID sets reject values above uint32 and malformed UID text is not retained" do
    {server, socket} = start_server()
    login(socket)
    command(socket, "b", "SELECT INBOX")

    for uids <- ["4294967296", "1:4294967296", "sensitive-invalid-uid"] do
      assert command(socket, "c", "UID FETCH " <> uids <> " (UID FLAGS)") == "c BAD completed\r\n"
    end

    assert Enum.take(commands(server), -3) == List.duplicate(%{command: :fetch}, 3)
    assert command(socket, "d", "UID SEARCH UID 4294967295") == "* SEARCH\r\nd OK completed\r\n"
    assert command(socket, "e", "UID SEARCH UID 4294967296") == "e BAD completed\r\n"
  end

  test "arrivals take UIDNEXT and a new UIDVALIDITY shows in EXAMINE" do
    {server, socket} = start_server(mailboxes: %{"INBOX" => %{messages: [message(4)]}})
    login(socket)

    assert {:ok, 5} = add_message(server, "INBOX", %{uid: 99, flags: ["\\Seen"]})
    assert {:ok, 6} = add_message(server, "INBOX", %{})
    assert {:error, :nonexistent} = add_message(server, "Missing", %{})
    assert {:error, :invalid_message} = add_message(server, "INBOX", [])
    assert :ok = set_uid_validity(server, "INBOX", 77)
    assert {:error, :nonexistent} = set_uid_validity(server, "Missing", 77)

    for invalid <- [0, 4_294_967_296, "7"] do
      assert {:error, :invalid_uid_validity} =
               set_uid_validity(server, "INBOX", invalid)
    end

    reply = command(socket, "b", "EXAMINE INBOX")
    assert reply =~ "* 3 EXISTS\r\n"
    assert reply =~ "[UIDVALIDITY 77]"
    assert reply =~ "[UIDNEXT 7]"
    assert command(socket, "c", "UID SEARCH UNSEEN") == "* SEARCH 4 6\r\nc OK completed\r\n"
  end

  test "queued untagged lines precede the next response of every connected peer" do
    {server, socket} = start_server()
    %{port: port} = endpoint(server)
    {:ok, other} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 2_000)
    assert {:ok, "* OK fake ready\r\n"} = SocketWait.recv(:gen_tcp, other)
    login(socket)
    assert {:error, :invalid_update} = queue_untagged(server, "* 1 EXISTS\r\n* BYE")
    assert :ok = queue_untagged(server, "* 1 EXISTS")
    assert :ok = queue_untagged(server, "* 1 RECENT")

    assert command(socket, "b", "SELECT INBOX") =~
             ~r/\A\* 1 EXISTS\r\n\* 1 RECENT\r\n\* FLAGS/

    assert command(socket, "c", "UID SEARCH ALL") == "* SEARCH\r\nc OK completed\r\n"

    # The other peer still has both lines queued, ahead of even an unauthenticated reply.
    assert command(other, "d", "CAPABILITY") =~ ~r/\A\* 1 EXISTS\r\n\* 1 RECENT\r\n\* CAPABILITY/
  end

  test "dropping connections closes sockets silently, including during IDLE" do
    {server, socket} = start_server()
    login(socket)
    command(socket, "b", "SELECT INBOX")
    :ok = :gen_tcp.send(socket, "c IDLE\r\n")
    assert {:ok, "+ idling\r\n"} = SocketWait.recv(:gen_tcp, socket)

    assert :ok = drop_connections(server)
    assert {:error, :closed} = SocketWait.recv(:gen_tcp, socket)
  end
end
