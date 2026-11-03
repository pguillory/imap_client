defmodule IMAPClient.FramerTest do
  use ExUnit.Case, async: true

  import IMAPClient.Framer

  # A literal comes out of the framer as a quoted string with " and \ escaped, so the
  # frame is one line the response parser can read.

  test "frames every packet split without treating literal bytes as protocol" do
    body = "A10 OK fake\r\n\"\\" <> <<0, 255>>
    wire = "* 1 FETCH (UID 12 BODY[] {#{byte_size(body)}}\r\n" <> body <> ")\r\na1 OK done\r\n"

    for offset <- 0..byte_size(wire) do
      <<left::binary-size(offset), right::binary>> = wire
      {:ok, first, state} = feed(new(), left)
      {:ok, last, _state} = feed(state, right)

      assert first ++ last == [
               ~s|* 1 FETCH (UID 12 BODY[] "A10 OK fake\r\n\\"\\\\| <> <<0, 255>> <> ~s|")|,
               "a1 OK done"
             ]
    end
  end

  test "reads multiple literals including empty and literal8 in one response" do
    wire =
      "* 2 FETCH (UID 7 ENVELOPE ({0}\r\n {3}\r\nhey NIL NIL NIL NIL NIL NIL NIL NIL) BODY[] ~{2}\r\n" <>
        <<0, 255>> <> ")\r\n"

    assert {:ok, [line], _} = feed(new(), wire)

    assert line ==
             ~s|* 2 FETCH (UID 7 ENVELOPE ("" "hey" NIL NIL NIL NIL NIL NIL NIL NIL) BODY[] "| <>
               <<0, 255>> <> ~s|")|
  end

  test "status brace text is not an announced literal" do
    for status <- ["OK", "NO", "BAD", "BYE"] do
      line = "* #{status} arbitrary prose {123}"

      assert {:ok, [^line, "A1 OK done"], _} =
               feed(new(), line <> "\r\nA1 OK done\r\n")
    end
  end

  test "LIST mailbox literals use their octet lengths" do
    assert {:ok, ["* LIST (\\Drafts) NIL \"Dra\\\"fts\r\""], _} =
             feed(new(), "* LIST (\\Drafts) NIL {8}\r\nDra\"fts\r\r\n")
  end

  test "refuses large announcements before retaining payload" do
    assert {:error, :response_too_large} =
             feed(new(literal_limit_bytes: 3), "* 1 FETCH (BODY[] {4}\r\n")

    assert {:error, :response_too_large} = feed(new(line_limit_bytes: 3), "abcd")

    assert {:error, :response_too_large} =
             feed(new(line_limit_bytes: 3), "abcd\r\n")
  end

  test "retains incomplete CRLF and literal until the exact remaining bytes arrive" do
    {:ok, [], state} = feed(new(), "* 1 FETCH (UID 1 BODY[] {3}\r")
    {:ok, [], state} = feed(state, "\na")
    {:ok, [], state} = feed(state, "b")
    assert {:ok, [~s|* 1 FETCH (UID 1 BODY[] "abc")|], _} = feed(state, "c)\r\n")
  end

  test "an exactly full physical line works with a split CRLF" do
    {:ok, [], state} = feed(new(line_limit_bytes: 3), "abc\r")
    assert {:ok, ["abc"], _} = feed(state, "\n")
    assert {:error, :response_too_large} = feed(new(line_limit_bytes: 3), "abcd\r")
  end

  test "many individually valid literals cannot exceed the logical response budget" do
    state = new(literal_limit_bytes: 3, logical_limit_bytes: 30)

    assert {:error, :response_too_large} =
             feed(
               state,
               "* 1 FETCH (X {3}\r\nabc Y {3}\r\ndef Z {3}\r\nghi W {3}\r\njkl)\r\n"
             )
  end

  test "strict SPECIAL-USE mode refuses literal mailbox names before consuming them" do
    state = new(reject_list_literals?: true)
    assert feed(state, "* LIST (\\Drafts) NIL {6}\r\n") == {:error, :unsupported_literal}
  end

  test "unbounded decimal literal markers are refused before integer parsing" do
    marker = String.duplicate("9", 100)

    assert feed(new(), "* 1 FETCH (BODY[] {" <> marker <> "}\r\n") ==
             {:error, :response_too_large}
  end
end
