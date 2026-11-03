defmodule IMAPClient.SessionTest do
  use ExUnit.Case, async: true

  import IMAPClient

  alias IMAPClient.Error
  alias IMAPClient.FakeServer
  alias IMAPClient.Peer

  defp message(uid, overrides \\ %{}) do
    Map.merge(
      %{
        uid: uid,
        flags: [],
        envelope:
          ~s|NIL "Message #{uid}" (("Alice" NIL "alice" "example.com")) NIL NIL ((NIL NIL "bob" "example.com")) NIL NIL NIL "<#{uid}@example.com>"|,
        bodystructure: ~s|"TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 5 1|,
        sections: %{"1" => "hello"},
        headers: "List-Unsubscribe: <mailto:u@example.com>\r\n\r\n"
      },
      overrides
    )
  end

  defp fake(messages, opts \\ []) do
    mailboxes = %{
      "INBOX" => %{messages: messages},
      "Archive" => %{messages: []},
      "Drafts" => %{messages: [], flags: ["\\Drafts"]}
    }

    server = start_supervised!({FakeServer, Keyword.merge([mailboxes: mailboxes], opts)})

    config =
      FakeServer.endpoint(server)
      |> Map.put(:connection_options,
        timeouts: [
          command_ms: 2_000,
          body_fetch_ms: 2_000,
          authentication_ms: 2_000,
          logout_ms: 2_000
        ]
      )

    {server, config}
  end

  test "search sorts highest UID first, limits and returns parsed envelopes" do
    {_server, config} = fake([message(2), message(7), message(4)])
    assert {:ok, result} = search(config, %{limit: 2, from: "alice"})
    assert Enum.map(result.results, & &1.uid) == [7, 4]
    assert result.unreturned == 0
    assert hd(result.results).envelope.subject == "Message 7"
    assert hd(result.results).list_unsubscribe == "mailto:u@example.com"
    refute hd(result.results).has_attachments
  end

  test "search counts metadata omissions without doing another SEARCH" do
    {server, config} = fake([message(7)])
    :ok = FakeServer.script_next(server, :fetch, {:omit, :metadata})
    assert search(config, %{}) == {:ok, %{results: [], unreturned: 1}}
    assert Enum.count(FakeServer.commands(server), &(&1.command == :search)) == 1
  end

  test "read_many follows requested order and reuses one login and SELECT" do
    {server, config} = fake([message(2), message(7)])

    assert {:ok, [%{kind: :found, email: first}, %{kind: :found, email: second}]} =
             read_many(config, [7, 2], "INBOX")

    assert {first.uid, second.uid} == {7, 2}
    assert first.text_body == "hello"
    assert first.attachments == []
    commands = FakeServer.commands(server)
    assert Enum.count(commands, &(&1.command == :login)) == 1
    assert Enum.count(commands, &(&1.command == :select)) == 1
    assert List.last(commands).command == :logout
  end

  test "missing metadata distinguishes gone withheld and unchecked" do
    for {script, reason} <- [{{:omit, :metadata}, :withheld}, {{:remove, "INBOX", 7}, :gone}] do
      {server, config} = fake([message(7)])
      :ok = FakeServer.script_next(server, :fetch, script)
      assert read(config, 7, "INBOX") == {:ok, %{kind: :missing, uid: 7, reason: reason}}
      stop_supervised!(FakeServer)
    end

    {server, config} = fake([message(7)])
    :ok = FakeServer.script_next(server, :fetch, {:omit, :metadata})
    :ok = FakeServer.script_next(server, :search, {:omit, :search})

    assert read(config, 7, "INBOX") ==
             {:ok, %{kind: :missing, uid: 7, reason: :unchecked}}
  end

  test "missing body is withheld while returned empty bytes are a found empty body" do
    {server, config} = fake([message(7)])
    :ok = FakeServer.script_next(server, :fetch_body, {:omit, :body})
    assert read(config, 7, "INBOX") == {:ok, %{kind: :missing, uid: 7, reason: :withheld}}
    stop_supervised!(FakeServer)
    {_server, config} = fake([message(7, %{sections: %{"1" => ""}})])
    assert {:ok, %{kind: :found, email: email}} = read(config, 7, "INBOX")
    refute Map.has_key?(email, :text_body)
  end

  test "body timeout propagates rather than returning a bodyless found message" do
    {server, config} = fake([message(7)])
    config = Map.put(config, :connection_options, timeouts: [body_fetch_ms: 500])
    :ok = FakeServer.script_next(server, :fetch_body, :stall)
    assert {:error, %Error{code: :timeout, stage: :body}} = read(config, 7, "INBOX")
    refute Enum.any?(FakeServer.commands(server), &(&1.command == :logout))
  end

  test "body decoding uses declared transfer encoding and charset" do
    msg =
      message(7, %{
        bodystructure:
          ~s|"TEXT" "PLAIN" ("CHARSET" "WINDOWS-1252") NIL NIL "QUOTED-PRINTABLE" 8 1|,
        sections: %{"1" => "caf=E9"}
      })

    {_server, config} = fake([msg])
    assert {:ok, %{kind: :found, email: %{text_body: "café"}}} = read(config, 7, "INBOX")
  end

  test "attachment-only structure never guesses and displays file bytes as body" do
    msg =
      message(7, %{
        bodystructure: ~s|"APPLICATION" "PDF" NIL NIL NIL "BASE64" 4|,
        sections: %{"1" => "eA=="}
      })

    {server, config} = fake([msg])
    assert {:ok, %{kind: :found, email: email}} = read(config, 7, "INBOX")
    assert length(email.attachments) == 1
    refute Map.has_key?(email, :text_body)
    assert Enum.count(FakeServer.commands(server), &(&1.command == :fetch)) == 1
  end

  test "MOVE uses server capability and reports missing UIDs" do
    {server, config} = fake([message(7)])

    assert move(config, [7, 99], "Archive", "INBOX") ==
             {:ok, %{missing_uids: [99], unpurged_uids: []}}

    assert FakeServer.mailbox(server, "INBOX").messages == []
    assert length(FakeServer.mailbox(server, "Archive").messages) == 1
    assert Enum.any?(FakeServer.commands(server), &(&1.command == :move))
  end

  test "fallback expunges only moved UIDs with UIDPLUS and never plain EXPUNGE" do
    {server, config} =
      fake([message(7), message(8, %{flags: ["\\Deleted"]})],
        capabilities: ["IMAP4rev1", "UIDPLUS"]
      )

    assert move(config, [7], "Archive", "INBOX") ==
             {:ok, %{missing_uids: [], unpurged_uids: []}}

    assert Enum.map(FakeServer.mailbox(server, "INBOX").messages, & &1.uid) == [8]
    assert Enum.any?(FakeServer.commands(server), &(&1.command == :expunge))
  end

  test "without UIDPLUS or MOVE reports deleted source copies as unpurged" do
    {server, config} = fake([message(7)], capabilities: ["IMAP4rev1"])

    assert move(config, [7], "Archive", "INBOX") ==
             {:ok, %{missing_uids: [], unpurged_uids: [7]}}

    assert hd(FakeServer.mailbox(server, "INBOX").messages).flags == ["\\Deleted"]
    refute Enum.any?(FakeServer.commands(server), &(&1.command == :expunge))
  end

  test "flags only existing UIDs and supports removing Seen and adding Answered" do
    {server, config} = fake([message(7)])
    assert mark_read(config, [7, 99]) == {:ok, %{missing_uids: [99]}}
    assert mark_unread(config, [7]) == {:ok, %{missing_uids: []}}
    assert add_flags(config, [7], ["\\Answered"]) == {:ok, %{missing_uids: []}}
    assert hd(FakeServer.mailbox(server, "INBOX").messages).flags == ["\\Answered"]
  end

  test "folder refusal is preserved and still logs out" do
    {server, config} = fake([])
    assert {:error, %Error{code: :mailbox_no}} = read(config, 7, "Missing")
    assert List.last(FakeServer.commands(server)).command == :logout
  end

  test "lists folders and appends a Unicode draft with Seen and Draft flags" do
    {server, config} = fake([])
    assert {:ok, folders} = list_special_use_folders(config)
    assert Enum.any?(folders, &(&1.name == "Drafts" and "\\Drafts" in &1.flags))
    bytes = "Subject: résumé\r\n\r\nhello"
    assert :ok = append(config, "Drafts", bytes, flags: ["\\Seen", "\\Draft"])
    draft = hd(FakeServer.mailbox(server, "Drafts").messages)
    assert Enum.sort(draft.flags) == ["\\Draft", "\\Seen"]
  end

  test "downloads transfer-decoded attachment with filename and real MIME type" do
    msg =
      message(7, %{
        bodystructure:
          ~s|"APPLICATION" "PDF" NIL NIL NIL "BASE64" 4 NIL ("ATTACHMENT" ("FILENAME" "a.pdf"))|,
        sections: %{"1" => "eA=="}
      })

    {_server, config} = fake([msg])

    assert download_attachment(config, 7, "1", "INBOX", 5) ==
             {:ok, %{kind: :ok, content: "x", mime_type: "application/pdf", filename: "a.pdf"}}

    assert download_attachment(config, 7, "9", "INBOX", 5) == {:ok, %{kind: :not_found}}
  end

  test "checks attachment decoded limits before and after download" do
    msg =
      message(7, %{
        bodystructure: ~s|"APPLICATION" "PDF" NIL NIL NIL "BINARY" 8|,
        sections: %{"1" => "12345678"}
      })

    {server, config} = fake([msg])

    assert download_attachment(config, 7, "1", "INBOX", 2) ==
             {:ok, %{kind: :too_large, bytes: 8}}

    assert Enum.count(FakeServer.commands(server), &(&1.command == :fetch)) == 1
    stop_supervised!(FakeServer)

    msg =
      message(7, %{
        bodystructure: ~s|"APPLICATION" "PDF" NIL NIL NIL "BASE64" 8|,
        sections: %{"1" => "aGVsbG8="}
      })

    {_server, config} = fake([msg])

    assert download_attachment(config, 7, "1", "INBOX", 2) ==
             {:ok, %{kind: :too_large, bytes: 5}}
  end

  test "malformed attachment content fails instead of saving altered bytes" do
    msg =
      message(7, %{
        bodystructure: ~s|"APPLICATION" "PDF" NIL NIL NIL "BASE64" 5|,
        sections: %{"1" => "T@Q=="}
      })

    {_server, config} = fake([msg])

    assert {:error, %Error{code: :malformed_content}} =
             download_attachment(config, 7, "1", "INBOX", 100)
  end

  test "connection test classifies wrong app passwords and never exposes server text" do
    {_server, config} = fake([])
    assert test_connection(config) == %{ok: true}
    assert test_connection(%{config | password: "wrong"}) == %{ok: false, reason: :auth}
  end

  test "only live refusals permit guessed body sections" do
    {server, config} = fake([message(7)])
    :ok = FakeServer.script_next(server, :fetch_body, {:refuse, :no, nil})
    assert {:ok, %{kind: :found, email: %{text_body: "hello"}}} = read(config, 7, "INBOX")
    assert Enum.count(FakeServer.commands(server), &(&1.command == :fetch)) == 3
  end

  test "empty returned body does not trigger guessed sections" do
    {server, config} = fake([message(7, %{sections: %{"1" => ""}})])
    assert {:ok, %{kind: :found}} = read(config, 7, "INBOX")
    assert Enum.count(FakeServer.commands(server), &(&1.command == :fetch)) == 2
  end

  test "all missing mutation UIDs skip capabilities and changes" do
    {server, config} = fake([])

    assert move(config, [7], "Archive", "INBOX") ==
             {:ok, %{missing_uids: [7], unpurged_uids: []}}

    refute Enum.any?(
             FakeServer.commands(server),
             &(&1.command in [:capability, :copy, :move, :store, :expunge])
           )
  end

  test "attachment zero bytes and omitted body remain distinct" do
    {server, config} = fake([message(7, %{sections: %{"1" => ""}})])

    assert {:ok, %{kind: :ok, content: ""}} =
             download_attachment(config, 7, "1", "INBOX", 5)

    :ok = FakeServer.script_next(server, :fetch_body, {:omit, :body})

    assert download_attachment(config, 7, "1", "INBOX", 5) ==
             {:ok, %{kind: :missing, reason: :withheld}}
  end

  test "unknown attachment folder propagates and a live FETCH refusal means not_found" do
    {server, config} = fake([message(7)])

    assert {:error, %Error{code: :mailbox_no}} =
             download_attachment(config, 7, "1", "Absent", 5)

    :ok = FakeServer.script_next(server, :fetch_body, {:refuse, :bad, nil})
    assert download_attachment(config, 7, "1", "INBOX", 5) == {:ok, %{kind: :not_found}}
  end

  test "invalid connection options are a programming error and raise" do
    assert_raise ArgumentError, fn ->
      test_connection(%{
        host: "127.0.0.1",
        username: "u",
        password: "p",
        connection_options: [timeouts: [command_ms: -1]]
      })
    end
  end

  test "a live existence refusal is unchecked while a failed check propagates" do
    {server, config} = fake([message(7)])
    :ok = FakeServer.script_next(server, :fetch, {:omit, :metadata})
    :ok = FakeServer.script_next(server, :search, {:refuse, :no, nil})

    assert read(config, 7, "INBOX") ==
             {:ok, %{kind: :missing, uid: 7, reason: :unchecked}}

    :ok = FakeServer.script_next(server, :fetch, {:omit, :metadata})
    :ok = FakeServer.script_next(server, :search, :close)
    assert {:error, %Error{code: :closed}} = read(config, 7, "INBOX")
  end

  test "withheld body does not stop later messages in the batch" do
    {server, config} = fake([message(7), message(8)])
    :ok = FakeServer.script_next(server, :fetch_body, {:omit, :body})

    assert {:ok, [%{kind: :missing, uid: 7, reason: :withheld}, %{kind: :found, email: email}]} =
             read_many(config, [7, 8], "INBOX")

    assert email.uid == 8
    assert email.text_body == "hello"
    refute Enum.any?(FakeServer.commands(server), &(&1.command == :search))
  end

  test "body fallback tries TEXT after both the selected and guessed section are refused" do
    {server, config} = fake([message(7, %{sections: %{"1" => "hello", "TEXT" => "fallback"}})])
    :ok = FakeServer.script_next(server, :fetch_body, {:refuse, :no, nil})
    :ok = FakeServer.script_next(server, :fetch_body, {:refuse, :bad, nil})

    assert {:ok, %{kind: :found, email: %{text_body: "fallback"}}} =
             read(config, 7, "INBOX")
  end

  test "missing attachment metadata uses exactly one existence check" do
    {server, config} = fake([message(7)])
    :ok = FakeServer.script_next(server, :fetch, {:omit, :metadata})

    assert download_attachment(config, 7, "1", "INBOX", 100) ==
             {:ok, %{kind: :missing, reason: :withheld}}

    assert Enum.count(FakeServer.commands(server), &(&1.command == :search)) == 1
  end

  test "large quoted-printable encoded size does not refuse a small decoded attachment" do
    encoded = "=78" <> String.duplicate("=\r\n", 100)

    {_server, config} =
      fake([
        message(7, %{
          bodystructure:
            ~s|"APPLICATION" "PDF" NIL NIL NIL "QUOTED-PRINTABLE" #{byte_size(encoded)}|,
          sections: %{"1" => encoded}
        })
      ])

    assert {:ok, %{kind: :ok, content: "x"}} =
             download_attachment(config, 7, "1", "INBOX", 1)
  end

  test "metadata gap diagnostics preserve the existence-check outcome without account config" do
    {server, config} = fake([message(7)])
    parent = self()
    config = Map.put(config, :on_diagnostic, &send(parent, {:diagnostic, &1}))
    :ok = FakeServer.script_next(server, :fetch, {:omit, :metadata})
    assert {:ok, %{kind: :missing, reason: :withheld}} = read(config, 7, "INBOX")

    assert_receive {:diagnostic, event}
    assert event.event == :fetch_incomplete
    assert event.stage == :metadata
    assert event.folder == "INBOX"
    assert event.requested_count == 1
    assert event.missing == [%{uid: 7, reason: :withheld}]
    assert event.other_lines == []
    assert is_binary(event.completion)
    assert event.search.outcome == :answered
    assert event.search.other_lines == []
    assert is_binary(event.search.completion)
    refute Map.has_key?(event, :password)
    refute Map.has_key?(event, :username)
  end

  test "failed existence checks emit diagnostics before the failure propagates" do
    {server, config} = fake([message(7)])
    parent = self()
    config = Map.put(config, :on_diagnostic, &send(parent, {:diagnostic, &1}))
    :ok = FakeServer.script_next(server, :fetch, {:omit, :metadata})
    :ok = FakeServer.script_next(server, :search, :close)
    assert {:error, %Error{code: :closed}} = read(config, 7, "INBOX")
    assert_receive {:diagnostic, %{search: %{outcome: :failed}, missing: [%{reason: :unchecked}]}}
  end

  test "connection failure diagnostics contain only a category" do
    {_server, config} = fake([])
    parent = self()

    config =
      Map.merge(config, %{password: "wrong", on_diagnostic: &send(parent, {:diagnostic, &1})})

    assert test_connection(config) == %{ok: false, reason: :auth}
    assert_receive {:diagnostic, %{event: :connection_test_failed, reason: :auth} = event}
    assert map_size(event) == 2
  end

  test "body diagnostics survive a later failed batch fetch" do
    {server, config} = fake([message(7), message(8)])
    parent = self()
    config = Map.put(config, :on_diagnostic, &send(parent, {:diagnostic, &1}))
    :ok = FakeServer.script_next(server, :fetch_body, {:omit, :body})
    :ok = FakeServer.script_next(server, :fetch_body, :close)
    assert {:error, %Error{code: :closed}} = read_many(config, [7, 8], "INBOX")

    assert_receive {:diagnostic,
                    %{
                      event: :fetch_incomplete,
                      stage: :body,
                      requested_count: 2,
                      missing: [%{uid: 7, reason: :withheld}],
                      other_lines: [],
                      completion: completion
                    }}

    assert is_binary(completion)
  end

  test "connection tests distinguish server connection limits from ordinary refusals" do
    for {response, reason} <- [
          {"NO Too many simultaneous connections", :busy},
          {"NO service refused", :refused},
          {"BAD unsupported login", :refused}
        ] do
      peer =
        start_supervised!(
          {Peer,
           script: fn socket ->
             :ok = :gen_tcp.send(socket, "* OK ready\r\n")
             "A1 LOGIN \"u\" \"p\"" = Peer.line(socket)
             :ok = :gen_tcp.send(socket, "A1 " <> response <> "\r\n")
             "A2 LOGOUT" = Peer.line(socket)
             :ok = :gen_tcp.send(socket, "* BYE closing\r\nA2 OK logged out\r\n")
           end}
        )

      assert test_connection(%{
               host: "127.0.0.1",
               port: Peer.port(peer),
               use_tls: false,
               username: "u",
               password: "p"
             }) == %{ok: false, reason: reason}

      stop_supervised!(Peer)
    end
  end

  test "authentication timeout is unreachable and does not attempt LOGOUT" do
    {server, config} = fake([])
    config = Map.put(config, :connection_options, timeouts: [authentication_ms: 500])
    # A timed-out LOGIN is retried once, so both attempts must stall.
    :ok = FakeServer.script_next(server, :login, :stall)
    :ok = FakeServer.script_next(server, :login, :stall)
    assert test_connection(config) == %{ok: false, reason: :unreachable}
    refute Enum.any?(FakeServer.commands(server), &(&1.command == :logout))
  end

  describe "sign-in" do
    defp reporting(config) do
      parent = self()
      Map.put(config, :on_diagnostic, &send(parent, {:diagnostic, &1}))
    end

    defp logins(server) do
      Enum.count(FakeServer.commands(server), &(&1.command == :login))
    end

    defp signin_events do
      receive do
        {:diagnostic, %{event: :signin_slow} = event} -> [event | signin_events()]
      after
        0 -> []
      end
    end

    test "a LOGIN timeout is retried once on a fresh connection and reported" do
      {server, config} = fake([message(7)])
      config = config |> Map.put(:connection_options, timeouts: [authentication_ms: 500])
      :ok = FakeServer.script_next(server, :login, :stall)
      links = Process.info(self(), :links)

      assert {:ok, %{results: [%{uid: 7}]}} = search(reporting(config), %{})
      assert logins(server) == 2
      assert Process.info(self(), :links) == links

      assert [
               %{attempt: 1, outcome: :timeout, stage: :authentication, retried: true},
               %{attempt: 2, outcome: :ok, stage: nil, retried: false}
             ] = signin_events()
    end

    test "a second LOGIN timeout is returned after exactly two attempts" do
      {server, config} = fake([])
      config = Map.put(config, :connection_options, timeouts: [authentication_ms: 500])
      :ok = FakeServer.script_next(server, :login, :stall)
      :ok = FakeServer.script_next(server, :login, :stall)

      assert {:error, %Error{code: :timeout, stage: :authentication}} =
               search(reporting(config), %{})

      assert logins(server) == 2

      assert [
               %{attempt: 1, outcome: :timeout, retried: true},
               %{attempt: 2, outcome: :timeout, stage: :authentication, retried: false}
             ] = signin_events()
    end

    test "with retry_sign_in false, a LOGIN timeout is returned after one attempt" do
      {server, config} = fake([message(7)])

      config =
        config
        |> Map.put(:connection_options, timeouts: [authentication_ms: 500])
        |> Map.put(:retry_sign_in, false)

      :ok = FakeServer.script_next(server, :login, :stall)

      assert {:error, %Error{code: :timeout, stage: :authentication}} =
               search(reporting(config), %{})

      assert logins(server) == 1
      assert [%{attempt: 1, outcome: :timeout, retried: false}] = signin_events()
    end

    test "a greeting timeout is retried once" do
      peer =
        start_supervised!(
          {Peer,
           script: [
             fn socket -> {:error, _} = :gen_tcp.recv(socket, 0, 5_000) end,
             fn socket ->
               :ok = :gen_tcp.send(socket, "* OK ready\r\n")
               "A1 LOGIN \"u\" \"p\"" = Peer.line(socket)
               :ok = :gen_tcp.send(socket, "A1 OK authenticated\r\n")
               "A2 LOGOUT" = Peer.line(socket)
               :ok = :gen_tcp.send(socket, "* BYE closing\r\nA2 OK logged out\r\n")
             end
           ]}
        )

      config = %{
        host: "127.0.0.1",
        port: Peer.port(peer),
        use_tls: false,
        username: "u",
        password: "p",
        connection_options: [timeouts: [greeting_ms: 500]]
      }

      assert test_connection(reporting(config)) == %{ok: true}

      assert [
               %{attempt: 1, outcome: :timeout, stage: :greeting, retried: true},
               %{attempt: 2, outcome: :ok, retried: false}
             ] = signin_events()
    end

    test "a refused LOGIN or an unreachable server is not retried" do
      {server, config} = fake([])

      assert {:error, %Error{code: :auth_rejected}} =
               search(reporting(%{config | password: "wrong"}), %{})

      assert logins(server) == 1

      {:ok, listener} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(listener)
      :ok = :gen_tcp.close(listener)

      assert {:error, %Error{stage: :connect}} =
               search(reporting(%{config | port: port}), %{})

      assert signin_events() == []
    end

    test "a timeout after sign-in is not retried" do
      {server, config} = fake([])
      config = Map.put(config, :connection_options, timeouts: [command_ms: 500])
      :ok = FakeServer.script_next(server, :select, :stall)

      assert {:error, %Error{code: :timeout, stage: :select}} =
               search(reporting(config), %{folder: "Archive"})

      assert logins(server) == 1
      assert signin_events() == []
    end

    test "a slow sign-in that worked is reported once" do
      {_server, config} = fake([])
      config = Map.put(config, :slow_signin_ms, 0)
      assert {:ok, _} = list_folders(reporting(config))
      assert [%{attempt: 1, outcome: :ok, stage: nil, retried: false} = event] = signin_events()
      assert is_integer(event.signin_ms) and event.signin_ms >= 0
    end
  end

  describe "modified UTF-7 mailbox names" do
    @wire "[Gmail]/Envoy&AOk-s"
    @name "[Gmail]/Envoyés"

    defp utf7_fake(capabilities) do
      mailboxes = %{
        "INBOX" => %{messages: [message(7)]},
        @wire => %{messages: []},
        "Drafts" => %{messages: [], flags: ["\\Drafts"]}
      }

      server =
        start_supervised!(
          {FakeServer, mailboxes: mailboxes, capabilities: capabilities},
          id: make_ref()
        )

      {server, FakeServer.endpoint(server)}
    end

    defp uids(server, mailbox) do
      Enum.map(FakeServer.mailbox(server, mailbox).messages, & &1.uid)
    end

    test "folders list decoded and SELECT, MOVE and APPEND send them encoded" do
      {server, config} = utf7_fake(["IMAP4rev1", "IDLE", "MOVE", "UIDPLUS"])

      assert {:ok, folders} = list_folders(config)
      assert @name in Enum.map(folders, & &1.name)
      refute @wire in Enum.map(folders, & &1.name)

      assert {:ok, %{results: []}} = search(config, %{folder: @name})
      assert {:ok, %{missing_uids: []}} = move(config, [7], @name, "INBOX")
      assert [_] = uids(server, @wire)

      assert :ok =
               append(config, @name, "Subject: x\r\n\r\nbody\r\n", flags: ["\\Seen", "\\Draft"])

      assert length(uids(server, @wire)) == 2
    end

    test "the COPY fallback and EXAMINE send them encoded" do
      {server, config} = utf7_fake(["IMAP4rev1", "IDLE", "UIDPLUS"])

      assert {:ok, %{missing_uids: [], unpurged_uids: []}} =
               move(config, [7], @name, "INBOX")

      assert [_] = uids(server, @wire)

      {:ok, connection} = start_link()
      :ok = connect(connection, config)
      :ok = login(connection, config.username, config.password)
      assert {:ok, %{uid_validity: _}} = examine(connection, @name)
      close(connection)
    end
  end

  test "existence diagnostics exclude complete FETCH frames with private literal payloads" do
    parent = self()
    subject = "Private subject\r\nA99 OK not a response"

    peer =
      start_supervised!(
        {Peer,
         script: fn socket ->
           :ok = :gen_tcp.send(socket, "* OK ready\r\n")
           "A1 LOGIN \"u\" \"p\"" = Peer.line(socket)
           :ok = :gen_tcp.send(socket, "A1 OK authenticated\r\n")
           "A2 SELECT \"INBOX\"" = Peer.line(socket)
           :ok = :gen_tcp.send(socket, "A2 OK selected\r\n")
           assert String.starts_with?(Peer.line(socket), "A3 UID FETCH 7 ")
           :ok = :gen_tcp.send(socket, "A3 OK metadata omitted\r\n")
           "A4 UID SEARCH UID 7" = Peer.line(socket)

           :ok =
             :gen_tcp.send(socket, [
               "* 1 FETCH (UID 99 ENVELOPE (NIL {#{byte_size(subject)}}\r\n",
               subject,
               " NIL NIL NIL NIL NIL NIL NIL NIL))\r\n* SEARCH 7\r\nA4 OK checked\r\n"
             ])

           "A5 LOGOUT" = Peer.line(socket)
           :ok = :gen_tcp.send(socket, "* BYE closing\r\nA5 OK logged out\r\n")
         end}
      )

    config = %{
      host: "127.0.0.1",
      port: Peer.port(peer),
      use_tls: false,
      username: "u",
      password: "p",
      on_diagnostic: &send(parent, {:diagnostic, &1})
    }

    assert read(config, 7, "INBOX") == {:ok, %{kind: :missing, uid: 7, reason: :withheld}}
    assert_receive {:diagnostic, %{search: %{outcome: :answered, other_lines: []}} = event}
    refute inspect(event) =~ "Private subject"
    refute inspect(event) =~ "A99"
  end

  test "session cleanup stops its connection without leaving trapped EXIT messages" do
    {server, config} = fake([message(7)])
    :ok = FakeServer.script_next(server, :fetch, {:omit, :metadata})
    parent = self()
    {:links, before_links} = Process.info(self(), :links)

    config =
      Map.put(config, :on_diagnostic, fn _event ->
        {:links, links} = Process.info(self(), :links)
        [connection] = links -- before_links
        send(parent, {:session_connection, connection, Process.monitor(connection)})
      end)

    previous = Process.flag(:trap_exit, true)

    try do
      assert {:ok, %{kind: :missing}} = read(config, 7, "INBOX")
      assert_receive {:session_connection, connection, monitor}
      assert_receive {:DOWN, ^monitor, :process, ^connection, :normal}
      refute_received {:EXIT, ^connection, _}
    after
      Process.flag(:trap_exit, previous)
    end
  end

  test "an already dead connection owner cannot replace the operation error during cleanup" do
    {_server, config} = fake([])

    owner =
      start_supervised!(
        {Task,
         fn ->
           receive do
             :finish -> :ok
           end
         end}
      )

    monitor = Process.monitor(owner)
    send(owner, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
    config = Map.put(config, :connection_options, owner: owner)
    assert {:error, %Error{code: :closed}} = read(config, 7, "INBOX")
  end

  test "a nil search folder uses INBOX" do
    {_server, config} = fake([message(7)])
    assert {:ok, %{results: [%{uid: 7}]}} = search(config, %{folder: nil})
  end
end
