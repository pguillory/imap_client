defmodule IMAPClient.NewCommandsTest do
  use ExUnit.Case, async: true

  import IMAPClient

  alias IMAPClient.Error
  alias IMAPClient.FakeServer
  alias IMAPClient.Peer
  alias IMAPClient.SampleDecoder
  alias IMAPClient.SocketWait

  defp fake(opts \\ []) do
    mailboxes = %{
      "INBOX" => %{
        uid_validity: 9,
        messages: [
          %{uid: 3, flags: ["\\Seen"]},
          %{
            uid: 4,
            envelope:
              ~s|NIL "=?shift_jis?B?gqA=?=" (("=?x-unknown?B?SGk=?=" NIL "a" "example.test")) NIL NIL NIL NIL NIL NIL NIL|,
            internal_date: "02-Nov-2026 10:00:00 +0000"
          }
        ]
      },
      "Drafts" => %{messages: []},
      "Empty" => %{messages: []}
    }

    server = start_supervised!({FakeServer, Keyword.merge([mailboxes: mailboxes], opts)})
    {server, FakeServer.endpoint(server)}
  end

  defp connected(config) do
    connection = start_supervised!({IMAPClient, owner: self()}, id: make_ref())
    :ok = connect(connection, Map.take(config, [:host, :port, :use_tls]))
    connection
  end

  defp wire(script) do
    peer = start_supervised!({Peer, script: script})

    connection =
      start_supervised!({IMAPClient, owner: self(), timeouts: [authentication_ms: 2_000]})

    :ok = connect(connection, %{host: "127.0.0.1", port: Peer.port(peer), use_tls: false})
    connection
  end

  describe "authenticate/4" do
    test "PLAIN and XOAUTH2 sign in to the fake" do
      {_server, config} = fake()

      connection = connected(config)
      assert authenticate(connection, :plain, config.username, config.password) == :ok
      assert {:ok, _} = status(connection, "INBOX")

      connection = connected(config)
      assert authenticate(connection, :xoauth2, config.username, config.access_token) == :ok
      assert {:ok, _} = status(connection, "INBOX")
    end

    test "a refused password or token is :auth_rejected and the connection stays usable" do
      {_server, config} = fake()
      connection = connected(config)

      assert {:error, %Error{code: :auth_rejected, stage: :authentication}} =
               authenticate(connection, :plain, config.username, "wrong")

      assert {:error, %Error{code: :auth_rejected, stage: :authentication} = error} =
               authenticate(connection, :xoauth2, config.username, "expired-token")

      refute Exception.message(error) =~ "expired-token"
      assert live?(connection)
      assert authenticate(connection, :xoauth2, config.username, config.access_token) == :ok
    end

    test "sends the initial response only after the continuation, in exact bytes" do
      parent = self()
      response = Base.encode64("user=a@example.test\x01auth=Bearer tok\x01\x01")

      connection =
        wire(fn socket ->
          :ok = :gen_tcp.send(socket, "* OK ready\r\n")
          "A1 AUTHENTICATE XOAUTH2" = Peer.line(socket)
          send(parent, {:before_continuation, :gen_tcp.recv(socket, 0, 100)})
          :ok = :gen_tcp.send(socket, "+ \r\n")
          ^response = Peer.line(socket)
          :ok = :gen_tcp.send(socket, "A1 OK signed in\r\n")
          SocketWait.recv(:gen_tcp, socket)
        end)

      assert authenticate(connection, :xoauth2, "a@example.test", "tok") == :ok
      assert_receive {:before_continuation, {:error, :timeout}}
    end

    test "answers the XOAUTH2 error challenge with an empty line, then reports :auth_rejected" do
      connection =
        wire(fn socket ->
          :ok = :gen_tcp.send(socket, "* OK ready\r\n")
          "A1 AUTHENTICATE XOAUTH2" = Peer.line(socket)
          :ok = :gen_tcp.send(socket, "+ \r\n")
          _response = Peer.line(socket)
          :ok = :gen_tcp.send(socket, "+ eyJzdGF0dXMiOiI0MDEifQ==\r\n")
          "" = Peer.line(socket)
          :ok = :gen_tcp.send(socket, "A1 NO token refused\r\n")
          SocketWait.recv(:gen_tcp, socket)
        end)

      assert {:error, %Error{code: :auth_rejected}} =
               authenticate(connection, :xoauth2, "a@example.test", "tok")

      assert live?(connection)
    end

    test "a second challenge under PLAIN is a protocol error" do
      connection =
        wire(fn socket ->
          :ok = :gen_tcp.send(socket, "* OK ready\r\n")
          "A1 AUTHENTICATE PLAIN" = Peer.line(socket)
          :ok = :gen_tcp.send(socket, "+ \r\n")
          _response = Peer.line(socket)
          :ok = :gen_tcp.send(socket, "+ again\r\n")
          SocketWait.recv(:gen_tcp, socket)
        end)

      assert {:error, %Error{code: :protocol, stage: :authentication}} =
               authenticate(connection, :plain, "a@example.test", "pw")

      refute live?(connection)
    end

    test "process status never shows the credentials, even mid-exchange" do
      parent = self()

      connection =
        wire(fn socket ->
          :ok = :gen_tcp.send(socket, "* OK ready\r\n")
          "A1 AUTHENTICATE PLAIN" = Peer.line(socket)
          :ok = :gen_tcp.send(socket, "+ \r\n")
          _response = Peer.line(socket)
          send(parent, {:response_received, self()})

          receive do
            :finish -> :gen_tcp.send(socket, "A1 OK signed in\r\n")
          end

          SocketWait.recv(:gen_tcp, socket)
        end)

      caller = Task.async(fn -> authenticate(connection, :plain, "a@example.test", "s3cret") end)
      assert_receive {:response_received, peer}
      status = inspect(:sys.get_status(connection), limit: :infinity)
      refute status =~ "s3cret"
      refute status =~ Base.encode64(<<0, "a@example.test", 0, "s3cret">>)
      send(peer, :finish)
      assert Task.await(caller) == :ok
    end

    test "an XOAUTH2 token never shows in process status or the fake's command history" do
      {server, config} = fake(access_token: "tok-s3cret")
      connection = connected(config)
      assert authenticate(connection, :xoauth2, config.username, "tok-s3cret") == :ok

      for text <- [
            inspect(:sys.get_status(connection), limit: :infinity),
            inspect(FakeServer.commands(server), limit: :infinity)
          ] do
        refute text =~ "tok-s3cret"
        refute text =~ Base.encode64("user=#{config.username}\x01auth=Bearer tok-s3cret\x01\x01")
      end
    end

    test "a server that stalls the exchange times out at the authentication deadline" do
      {server, config} = fake()

      connection =
        start_supervised!(
          {IMAPClient, owner: self(), timeouts: [authentication_ms: 200]},
          id: make_ref()
        )

      :ok = connect(connection, Map.take(config, [:host, :port, :use_tls]))
      :ok = FakeServer.script_next(server, :authenticate, :stall)

      assert {:error, %Error{code: :timeout, stage: :authentication} = error} =
               authenticate(connection, :xoauth2, config.username, config.access_token)

      refute Exception.message(error) =~ config.access_token
      refute live?(connection)
    end

    test "refuses unsafe credentials and SASL separators before sending anything" do
      {server, config} = fake()
      connection = connected(config)

      for {mechanism, username, secret} <- [
            {:plain, "a", "b\r\nc"},
            {:plain, "a\0", "b"},
            {:xoauth2, "a\x01auth=x", "tok"},
            {:xoauth2, "a", "tok\x01"},
            {:cram_md5, "a", "b"}
          ] do
        assert {:error, %Error{code: :invalid_argument, stage: :authentication}} =
                 authenticate(connection, mechanism, username, secret)
      end

      refute Enum.any?(FakeServer.commands(server), &(&1.command == :authenticate))
    end

    test "session configs choose the mechanism" do
      {server, config} = fake()

      assert test_connection(Map.put(config, :auth, :plain)) == %{ok: true}

      assert test_connection(config |> Map.put(:auth, :xoauth2) |> Map.delete(:password)) == %{
               ok: true
             }

      assert test_connection(%{config | access_token: "bad"} |> Map.put(:auth, :xoauth2)) ==
               %{ok: false, reason: :auth}

      kinds = Enum.map(FakeServer.commands(server), & &1.command)
      assert Enum.count(kinds, &(&1 == :authenticate)) == 3
      refute :login in kinds
    end
  end

  describe "noop/1" do
    test "returns the untagged updates the server sent with it" do
      {server, config} = fake()
      connection = connected(config)
      :ok = login(connection, config.username, config.password)
      assert noop(connection) == {:ok, []}

      :ok = FakeServer.queue_untagged(server, "* 5 EXISTS")
      assert noop(connection) == {:ok, ["* 5 EXISTS"]}
    end
  end

  describe "status/3" do
    test "reports the requested counts, zeros included, without selecting" do
      {server, config} = fake()
      connection = connected(config)
      :ok = login(connection, config.username, config.password)

      assert status(connection, "INBOX") ==
               {:ok, %{messages: 2, uid_next: 5, uid_validity: 9, unseen: 1}}

      assert status(connection, "Empty", [:messages, :recent, :unseen]) ==
               {:ok, %{messages: 0, recent: 0, unseen: 0}}

      assert {:error, %Error{code: :no}} = status(connection, "Missing")
      assert {:error, %Error{code: :invalid_argument}} = status(connection, "INBOX", [:size])
      refute Enum.any?(FakeServer.commands(server), &(&1.command == :select))
    end

    test "skips an item with a non-number value without dropping the ones after it" do
      connection =
        wire(fn socket ->
          :ok = :gen_tcp.send(socket, "* OK ready\r\n")
          ~s|A1 STATUS "INBOX" (MESSAGES UNSEEN)| = Peer.line(socket)

          :ok =
            :gen_tcp.send(socket, [
              "* STATUS INBOX (MESSAGES 3 MAILBOXID (F2212ea87) X NIL UNSEEN 1)\r\n",
              "A1 OK done\r\n"
            ])

          SocketWait.recv(:gen_tcp, socket)
        end)

      assert status(connection, "INBOX", [:messages, :unseen]) ==
               {:ok, %{messages: 3, unseen: 1}}
    end

    test "ignores a STATUS response for another mailbox and parses a literal name" do
      connection =
        wire(fn socket ->
          :ok = :gen_tcp.send(socket, "* OK ready\r\n")
          ~s|A1 STATUS "Caf&AOk-" (MESSAGES UNSEEN)| = Peer.line(socket)

          :ok =
            :gen_tcp.send(socket, [
              "* STATUS Other (MESSAGES 7)\r\n",
              "* STATUS {8}\r\nCaf&AOk- (MESSAGES 0 UNSEEN 3)\r\n",
              "A1 OK done\r\n"
            ])

          SocketWait.recv(:gen_tcp, socket)
        end)

      assert status(connection, "Café", [:messages, :unseen]) ==
               {:ok, %{messages: 0, unseen: 3}}
    end
  end

  describe "append/4" do
    test "stores flags and an internal date" do
      {server, config} = fake()
      date = ~U[2026-03-04 05:06:07.891Z]

      assert append(config, "Drafts", "Subject: x\r\n\r\nbody",
               flags: ["\\Flagged"],
               internal_date: date
             ) == {:ok, %{uid: 1, uid_validity: 1}}

      assert append(config, "Drafts", "Subject: y\r\n\r\nbody") ==
               {:ok, %{uid: 2, uid_validity: 1}}

      assert [first, second] = FakeServer.mailbox(server, "Drafts").messages
      assert first.flags == ["\\Flagged"]
      assert first.internal_date == "4-Mar-2026 05:06:07 +0000"
      assert second.flags == []
    end

    test "sends the flags and date on the wire" do
      connection =
        wire(fn socket ->
          :ok = :gen_tcp.send(socket, "* OK ready\r\n")

          ~s|A1 APPEND "Drafts" (\\Seen $Label) " 4-Mar-2026 05:06:07 +0000" {2}| =
            Peer.line(socket)

          :ok = :gen_tcp.send(socket, "+ go\r\n")
          {:ok, "hi\r\n"} = SocketWait.recv(:gen_tcp, socket, 4)
          :ok = :gen_tcp.send(socket, "A1 OK appended\r\n")
          SocketWait.recv(:gen_tcp, socket)
        end)

      assert append(connection, "Drafts", "hi",
               flags: ["\\Seen", "$Label"],
               internal_date: DateTime.new!(~D[2026-03-04], ~T[05:06:07], "Etc/UTC")
             ) == {:ok, %{uid: nil, uid_validity: nil}}
    end

    test "returns APPENDUID's UID and UIDVALIDITY" do
      {server, config} = fake()
      :ok = FakeServer.set_uid_validity(server, "Drafts", 77)

      assert append(config, "Drafts", "Subject: x\r\n\r\nbody") ==
               {:ok, %{uid: 1, uid_validity: 77}}
    end

    test "returns nil UID and UIDVALIDITY from a server without UIDPLUS" do
      {_server, config} = fake(capabilities: ["IMAP4rev1", "AUTH=PLAIN"])

      assert append(config, "Drafts", "Subject: x\r\n\r\nbody") ==
               {:ok, %{uid: nil, uid_validity: nil}}
    end

    test "refuses invalid flags and dates before sending" do
      {server, config} = fake()
      connection = connected(config)
      :ok = login(connection, config.username, config.password)

      for opts <- [
            [flags: ["bad flag"]],
            [flags: ["(x"]],
            [flags: "\\Seen"],
            [flags: ["\\Recent"]],
            [flags: ["\\recent"]],
            [flags: ["caf\u00e9"]],
            [flags: ["a\\b"]],
            [internal_date: "today"],
            [internal_date: ~U[0999-12-31 00:00:00Z]],
            [internal_date: DateTime.new!(Date.new!(10_000, 1, 1), ~T[00:00:00])],
            %{flags: []},
            [:flags]
          ] do
        assert {:error, %Error{code: :invalid_argument, stage: :append}} =
                 append(connection, "Drafts", "x", opts)
      end

      refute Enum.any?(FakeServer.commands(server), &(&1.command == :append))
    end
  end

  describe "charset decoding" do
    test "envelopes decode with the given decoder; unknown encoded words keep their payload" do
      {_server, config} = fake()
      connection = connected(config)
      :ok = login(connection, config.username, config.password)
      :ok = select(connection, "INBOX")

      assert {:ok, %{envelopes: %{4 => %{envelope: envelope}}}} =
               fetch_envelopes(connection, [4], charset_decoder: SampleDecoder)

      assert envelope.subject == "あ"
      assert [%{name: "SGk=", address: "a@example.test"}] = envelope.from

      assert {:ok, %{envelopes: %{4 => %{envelope: %{subject: "gqA="}}}}} =
               fetch_envelopes(connection, [4])
    end

    test "a body in an unknown charset comes back raw and untrimmed" do
      server =
        start_supervised!(
          {FakeServer,
           mailboxes: %{
             "INBOX" => %{
               messages: [
                 %{
                   uid: 1,
                   bodystructure: ~s|"TEXT" "PLAIN" ("CHARSET" "x-unknown") NIL NIL "7BIT" 4 1|,
                   sections: %{"1" => " hi "}
                 },
                 %{
                   uid: 2,
                   bodystructure: ~s|"TEXT" "PLAIN" ("CHARSET" "Shift_JIS") NIL NIL "7BIT" 2 1|,
                   sections: %{"1" => <<0x82, 0xA0>>}
                 }
               ]
             }
           }}
        )

      config = FakeServer.endpoint(server)

      assert {:ok, [%{email: one}, %{email: two}]} = read_many(config, [1, 2])
      assert one.text_body == %{charset: "x-unknown", bytes: " hi "}
      assert two.text_body == %{charset: "Shift_JIS", bytes: <<0x82, 0xA0>>}

      config = Map.put(config, :charset_decoder, SampleDecoder)
      assert {:ok, %{email: %{text_body: "あ"}}} = read(config, 2)
    end
  end
end
