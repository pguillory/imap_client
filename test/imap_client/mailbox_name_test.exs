defmodule IMAPClient.MailboxNameTest do
  use ExUnit.Case, async: true

  import IMAPClient.MailboxName

  # Every valid row round-trips exactly: LIST
  # decodes the wire name and SELECT/APPEND send it back, so the two must agree.
  test "valid names encode and decode exactly" do
    for {name, wire} <- [
          {"INBOX", "INBOX"},
          {"[Gmail]/Envoyés", "[Gmail]/Envoy&AOk-s"},
          {"&", "&-"},
          {"R&D", "R&-D"},
          {"~peter/mail/台北/日本語", "~peter/mail/&U,BTFw-/&ZeVnLIqe-"},
          {"Reçus 📬", "Re&AOc-us &2D3c7A-"},
          {"Archive&AOk-", "Archive&-AOk-"},
          {"Archiveé", "Archive&AOk-"}
        ] do
      assert encode(name) == wire, name
      assert decode(wire) == name, wire
      assert encode(decode(wire)) == wire, wire
    end
  end

  test "a name that isn't canonical modified UTF-7 is left as sent" do
    for {label, raw} <- [
          {"unterminated shift", "&AOk"},
          {"character outside the alphabet", "&Jjo!-"},
          {"shifted printable ASCII", "&AEE-"},
          {"adjacent shifts", "&U,BTFw-&ZeVnLIqe-"},
          {"nonzero padding bits", "&AOl-"},
          {"odd byte count", "&AA-"},
          {"raw 8-bit text", "Envoyés"},
          {"shifted control characters", "&AA0ACg-"},
          {"unpaired surrogate", "&2D0-"}
        ] do
      assert decode(raw) == raw, label
    end
  end

  test "a literal ampersand right after a shift is not an adjacent shift" do
    assert decode("&AOk-&-") == "é&"
  end

  test "encoding leaves a binary that is not UTF-8 unchanged" do
    assert encode(<<"a", 0xFF>>) == <<"a", 0xFF>>
  end
end
