defmodule IMAPClient.SyntaxTest do
  use ExUnit.Case, async: true

  import IMAPClient.Syntax

  test "parses nested lists, NIL, numbers, quoted escapes and tolerant whitespace" do
    assert {:ok, [nil, "42", ["a\"b", "x\\y", "single quoted", "7BIT"]]} =
             parse("nIl 42 (\"a\\\"b\"\t\"x\\\\y\"\r\n'single quoted' 7BIT)")

    assert {:ok, []} = parse("")
  end

  test "next parses one value and preserves the remaining input" do
    assert {:ok, ["UID", "42"], " FLAGS ()"} = next(" \t(UID 42) FLAGS ()")
    assert {:ok, nil, " next"} = next("NIL next")
    assert {:ok, "a b", " rest"} = next("\"a b\" rest")
  end

  test "rejects incomplete lists and strings rather than returning partial protocol data" do
    for input <- ["(", "(one", "\"unfinished", "\"escape\\", ")", "a )"] do
      assert {:error, :invalid_response} = parse(input)
    end
  end

  test "large quoted values retain binary spans and preserve escaped boundaries" do
    body = String.duplicate("payload", 300_000)

    assert next("\"" <> body <> "\\\"\\\\tail\" rest") ==
             {:ok, body <> "\"\\tail", " rest"}
  end

  test "metadata tolerates NBSP and form-feed separators seen in real BODYSTRUCTUREs" do
    assert parse("\"TEXT\"\u00a0\"PLAIN\"\f(\"CHARSET\" \"UTF-8\")") ==
             {:ok, ["TEXT", "PLAIN", ["CHARSET", "UTF-8"]]}
  end
end
