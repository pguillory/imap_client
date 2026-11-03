defmodule IMAPClient.PublicSessionsTest do
  use ExUnit.Case, async: true

  import IMAPClient

  alias IMAPClient.FakeServer
  alias IMAPClient.Peer
  alias IMAPClient.SocketWait

  test "public session helpers read and update mail over real IMAP sockets" do
    server =
      start_supervised!(
        {FakeServer,
         mailboxes: %{
           "INBOX" => %{
             messages: [
               %{
                 uid: 7,
                 bodystructure: ~s|"TEXT" "PLAIN" NIL NIL NIL "7BIT" 5 1|,
                 sections: %{"1" => "hello"}
               }
             ]
           },
           "Archive" => %{messages: []}
         }}
      )

    config = FakeServer.endpoint(server)
    assert test_connection(config) == %{ok: true}
    assert {:ok, %{results: [%{uid: 7}], unreturned: 0}} = search(config, %{})
    assert {:ok, %{kind: :found, email: %{text_body: "hello"}}} = read(config, 7)
    assert {:ok, [%{kind: :found}]} = read_many(config, [7])
    assert mark_read(config, [7]) == {:ok, %{missing_uids: []}}
    assert hd(FakeServer.mailbox(server, "INBOX").messages).flags == ["\\Seen"]
    assert mark_unread(config, [7]) == {:ok, %{missing_uids: []}}
    assert add_flags(config, [7], ["\\Answered"]) == {:ok, %{missing_uids: []}}
    assert remove_flags(config, [7], ["\\Answered"]) == {:ok, %{missing_uids: []}}
    assert hd(FakeServer.mailbox(server, "INBOX").messages).flags == []

    assert move(config, [7], "Archive") ==
             {:ok, %{missing_uids: [], unpurged_uids: []}}

    assert FakeServer.mailbox(server, "INBOX").messages == []
  end

  test "public folder draft and attachment helpers preserve content" do
    server =
      start_supervised!(
        {FakeServer,
         mailboxes: %{
           "INBOX" => %{
             messages: [
               %{
                 uid: 7,
                 bodystructure: ~s|"APPLICATION" "PDF" NIL NIL NIL "BASE64" 4|,
                 sections: %{"1" => "eA=="}
               }
             ]
           },
           "Drafts" => %{messages: [], flags: ["\\Drafts"]}
         }}
      )

    config = FakeServer.endpoint(server)
    assert {:ok, folders} = list_folders(config)
    assert Enum.map(folders, & &1.name) == ["Drafts", "INBOX"]
    assert {:ok, special} = list_special_use_folders(config)
    assert Enum.any?(special, &("\\Drafts" in &1.flags))

    assert :ok =
             append(config, "Drafts", "Subject: draft\r\n\r\nhello", flags: ["\\Seen", "\\Draft"])

    assert length(FakeServer.mailbox(server, "Drafts").messages) == 1
    assert {:ok, %{kind: :ok, content: "x"}} = download_attachment(config, 7, "1", 5)
  end

  test "body response diagnostics exclude FETCH payloads and preserve a missing result" do
    peer =
      start_supervised!(
        {Peer,
         script: fn socket ->
           :ok = :gen_tcp.send(socket, "* OK ready\r\n")
           "A1 UID FETCH 7 (BODY.PEEK[1])" = Peer.line(socket)

           :ok =
             :gen_tcp.send(
               socket,
               "* 7 FETCH (UID 7 FLAGS (\\Seen))\r\n* OK [ALERT] throttled\r\nA1 OK finished\r\n"
             )

           SocketWait.recv(:gen_tcp, socket)
         end}
      )

    connection = start_supervised!({IMAPClient, owner: self()})

    assert :ok =
             connect(connection, %{
               host: "127.0.0.1",
               port: Peer.port(peer),
               use_tls: false
             })

    assert fetch_body_response(connection, 7, "1") ==
             {:ok,
              %{
                body: :missing,
                other_lines: ["* OK [ALERT] throttled"],
                completion: "A1 OK finished"
              }}

    assert :ok = close(connection)
  end
end
