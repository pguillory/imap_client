defmodule IMAPClient.ProtocolTest do
  use ExUnit.Case, async: true

  import IMAPClient.Protocol

  test "matches status tokens with exact tag boundaries and case folding" do
    for {line, expected} <- [
          {"a1 oK complete", {"A1", :ok}},
          {"A10 NO refused", {"A10", :no}},
          {"A1 BAD done", {"A1", :bad}},
          {"A1 OKAY text", nil},
          {"* OK greeting", {"*", :ok}},
          {"A1X OK done", {"A1X", :ok}}
        ],
        do: assert(tagged_status(line) == expected)
  end

  test "quotes escapes and refuses CR LF and NUL before writing" do
    assert quote_string("a\\b\"c") == "\"a\\\\b\\\"c\""
    for value <- ["a\r", "a\n", "a" <> <<0>>], do: refute(safe_text?(value))
    assert safe_text?("résumé")
  end

  test "reads only top-level FETCH pairs including header sections with spaces" do
    line =
      ~s|* 12 FETCH (UID 345 FLAGS (\\Seen) ENVELOPE (NIL "UID 5 BODYSTRUCTURE (evil)" NIL NIL NIL NIL NIL NIL NIL NIL) BODY[HEADER.FIELDS (X Y)] "UID 7" INTERNALDATE "17-Jul-2026 02:44:25 -0700")|

    assert {:ok, items} = fetch_items(line)
    assert items["UID"] == "345"
    assert items["FLAGS"] == ["\\Seen"]
    assert items["BODY[HEADER.FIELDS (X Y)]"] == "UID 7"
    refute Map.has_key?(items, "BODYSTRUCTURE")
  end

  test "combines split metadata by UID and excludes message data from other lines" do
    result =
      metadata([
        "* 1 FETCH (UID 4 FLAGS (\\Seen))",
        "* 2 FETCH (UID 5 FLAGS ())",
        ~s|* 1 FETCH (UID 4 ENVELOPE (NIL "Hi" NIL NIL NIL NIL NIL NIL NIL NIL))|,
        "* 4 FETCH malformed",
        "* OK note"
      ])

    assert result.messages[4]["FLAGS"] == ["\\Seen"]
    assert result.messages[4]["ENVELOPE"] == [nil, "Hi", nil, nil, nil, nil, nil, nil, nil, nil]
    assert result.messages[5]["FLAGS"] == []
    assert result.other_lines == ["* OK note"]
  end

  test "validates body UID section partial origin duplicates and trailer" do
    for line <- [
          ~s|* 1 FETCH (UID 2 BODY[1] "hello")|,
          ~s|* 1 FETCH (UID 1 BODY[2] "hello")|,
          ~s|* 1 FETCH (UID 1 BODY[1]<0> "hello")|,
          ~s|* 1 FETCH (UID 1 BODY[1] "hello"|,
          ~s|* 1 FETCH (UID 1 BODY[1] "hello" BODY[1] "again")|
        ],
        do: assert(body([line], 1, "1") == {:error, :invalid_response})

    line = ~s|* 1 FETCH (FLAGS (\\Seen) BODY[1] "hello" UID 1)|
    assert body([line], 1, "1") == {:ok, "hello"}
    assert body([line, line], 1, "1") == {:error, :invalid_response}
    assert body(["* 1 FETCH (UID 1 BODY[1] NIL)"], 1, "1") == {:ok, ""}
    assert body(["* 1 FETCH (UID 1 FLAGS ())"], 1, "1") == {:ok, :missing}
  end

  test "keeps missing SEARCH distinct from empty and filters malformed UID tokens" do
    assert search_uids(["* SEARCH"]) == []
    assert search_uids(["* OK done"]) == nil
    assert search_uids(["* SEARCH 8 bad 4 0 -2 +1 4294967296"]) == [8, 4]
  end

  test "uses UTF-8 synchronizing literals only for non-ASCII search values" do
    assert {:ok, [~s(ALL FROM "alice" SUBJECT "hello" UNSEEN)]} =
             build_search(%{from: "alice", subject: "hello", unread_only: true})

    assert {:ok,
            [
              "CHARSET UTF-8 ALL FROM ",
              {:literal, "Zoë"},
              " SUBJECT ",
              {:literal, "你好"},
              " SINCE 1-Jan-2024"
            ]} = build_search(%{from: "Zoë", subject: "你好", since: "1-Jan-2024"})

    assert build_search(%{}) == {:ok, ["ALL"]}
  end

  test "rejects unsafe search strings and malformed dates before opening a connection" do
    for criteria <- [
          %{from: "a\r\nDELETE INBOX"},
          %{subject: <<0>>},
          %{keyword: "a\n"},
          %{since: "2024-01-15"},
          %{since: "15-Foo-2024"},
          %{until: "1-Jan-2024 ALL"},
          %{since: "15-Jan-2024\n"}
        ],
        do: assert(build_search(criteria) == {:error, :invalid_argument})
  end

  test "empty optional dates are ignored " do
    assert build_search(%{since: "", until: ""}) == {:ok, ["ALL"]}
  end

  test "metadata strings are lossy UTF-8 while BODY remains raw bytes" do
    invalid = "caf" <> <<0xE9>>

    metadata =
      metadata([
        "* 1 FETCH (UID 1 ENVELOPE (NIL \"" <> invalid <> "\" NIL NIL NIL NIL NIL NIL NIL NIL))"
      ])

    assert metadata.messages[1]["ENVELOPE"] |> Enum.at(1) == "caf�"
    assert envelope([nil, invalid]).subject == "caf�"

    assert list_folder("* LIST () NIL \"" <> invalid <> "\"") ==
             {:ok, %{name: "caf�", flags: [], delimiter: ""}}

    assert body(["* 1 FETCH (UID 1 BODY[1] \"" <> invalid <> "\")"], 1, "1") ==
             {:ok, invalid}
  end

  test "envelope field order preserves date reply-to cc and incomplete fields" do
    assert envelope(~s|"today" "subject"|).date == "today"

    data = [
      "today",
      "subject",
      [[nil, nil, nil, "example.com"]],
      nil,
      [["Reply", nil, "reply", "example.com"]],
      [[nil, nil, "to", "example.com"]],
      [[nil, nil, "cc1", "example.com"], [nil, nil, "cc2", "example.com"]],
      nil,
      nil,
      "<id>"
    ]

    envelope = envelope(data)
    assert envelope.from == [%{name: nil, address: "@example.com"}]
    assert envelope.reply_to == [%{name: "Reply", address: "reply@example.com"}]
    assert Enum.map(envelope.cc, & &1.address) == ["cc1@example.com", "cc2@example.com"]
  end

  test "matches only INBOX case insensitively" do
    assert mailbox_names_match?("INBOX", "Inbox")
    refute mailbox_names_match?("Drafts", "drafts")
  end

  test "parses quoted atom escaped and NIL folder data" do
    for {line, expected} <- [
          {~s|* LIST (\\Drafts) "/" "My Drafts"|,
           %{name: "My Drafts", flags: ["\\Drafts"], delimiter: "/"}},
          {~s|* LIST () NIL INBOX|, %{name: "INBOX", flags: [], delimiter: ""}},
          {~s|* LIST (\\Sent) "/" "a\\\"b"|, %{name: "a\"b", flags: ["\\Sent"], delimiter: "/"}}
        ],
        do: assert(list_folder(line, true) == {:ok, expected})

    assert list_folder(~s|* LIST (\\Drafts) "/"|, true) == {:error, :invalid_response}
    assert list_folder("* OK note", true) == :other
  end

  test "parses envelope addresses and skips group boundary markers" do
    content =
      ~s|NIL "=?UTF-8?B?SGVsbG8=?=" (("=?UTF-8?Q?Zo=C3=AB?=" NIL "zoe" "example.com") ("Group" NIL "group" NIL) (NIL NIL NIL NIL)) NIL NIL ((NIL NIL "bob" "example.com")) NIL NIL NIL "<id@example.com>"|

    result = envelope(content)
    assert result.subject == "Hello"
    assert result.from == [%{name: "Zoë", address: "zoe@example.com"}]
    assert result.to == [%{name: nil, address: "bob@example.com"}]
    assert result.message_id == "<id@example.com>"
    assert envelope("").from == []
  end

  test "decodes modified UTF-7 LIST names in both strict and lenient parsing" do
    line = ~s|* LIST (\\HasNoChildren \\Drafts) "/" "[Gmail]/Brouillons&AOk-"|

    for strict? <- [true, false] do
      assert {:ok, %{name: "[Gmail]/Brouillonsé"}} = list_folder(line, strict?)
    end

    assert {:ok, %{name: "Envoyés"}} = list_folder(~s|* LIST () "/" Envoy&AOk-s|)
  end

  test "mailbox astrings preserve bare NIL and leading or matched apostrophes" do
    for name <- ["NIL", "'Drafts", "'Archive'"] do
      assert list_folder(~s|* LIST (\\Drafts) "/" #{name}|, true) ==
               {:ok, %{name: name, flags: ["\\Drafts"], delimiter: "/"}}
    end

    assert list_folder(~s|* LIST () NIL "NIL"|) ==
             {:ok, %{name: "NIL", flags: [], delimiter: ""}}
  end

  test "prefers mailto unsubscribe then HTTPS then first declared URL" do
    assert list_unsubscribe("List-Unsubscribe: <https://example.com>, <mailto:u@example.com>") ==
             "mailto:u@example.com"

    assert list_unsubscribe("<http://a>, <HTTPS://b>") == "HTTPS://b"
    assert list_unsubscribe("<http://a>") == "http://a"
    assert list_unsubscribe("plain text") == nil
  end

  test "internal dates are UTC IMAP date-times with a four-digit year" do
    assert internal_date(~U[2026-03-04 05:06:07.891Z]) == " 4-Mar-2026 05:06:07 +0000"

    assert valid_internal_date?(~U[1000-01-01 00:00:00Z])
    assert valid_internal_date?(~U[9999-12-31 23:59:59Z])
    refute valid_internal_date?(~U[0999-12-31 23:59:59Z])
    refute valid_internal_date?("2026-03-04")
  end
end
