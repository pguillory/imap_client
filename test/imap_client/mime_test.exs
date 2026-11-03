defmodule IMAPClient.MIMETest do
  use ExUnit.Case, async: true

  import IMAPClient.MIME

  alias IMAPClient.SampleDecoder

  @corpus Path.expand("../fixtures/mime_corpus.json", __DIR__)
          |> File.read!()
          |> :json.decode(:ok, %{null: nil})
          |> elem(0)

  for item <- @corpus do
    @item item
    test "BODYSTRUCTURE corpus: #{@item["name"]}" do
      item = @item
      parts = select_text_parts(parse_mime_structure(item["structure"]))
      assert part_id(parts.plain) == item["plain"]
      assert part_id(parts.html) == item["html"]
    end
  end

  defp part_id(nil) do
    nil
  end

  defp part_id(part) do
    part.part_id
  end

  defp leaf(type, subtype, extra \\ "") do
    parse_mime_structure("\"#{type}\" \"#{subtype}\" NIL NIL NIL \"7BIT\" 5 #{extra}")
  end

  test "numbers nested parts by position" do
    source =
      ~s|("TEXT" "PLAIN" NIL NIL NIL "7BIT" 5 1)( ("TEXT" "HTML" NIL NIL NIL "7BIT" 8 1)("IMAGE" "PNG" NIL NIL NIL "BASE64" 12) "RELATED") "MIXED"|

    structure = parse_mime_structure(source)
    assert select_text_parts(structure).html.part_id == "2.1"
    assert find_leaf_part(structure, "2.2").subtype == "png"
    assert find_leaf_part(structure, "2") == nil
    assert find_leaf_part(nil, "1") == nil
  end

  test "lists text attachments, calendar invites, forwarded messages and inline images" do
    source =
      ~s|("TEXT" "PLAIN" NIL NIL NIL "7BIT" 5 1 NIL ("ATTACHMENT" ("FILENAME" "notes.txt")))("TEXT" "CALENDAR" NIL NIL NIL "7BIT" 5 1)("MESSAGE" "RFC822" NIL NIL NIL "7BIT" 50 NIL NIL 1)("IMAGE" "PNG" NIL NIL NIL "BASE64" 12 NIL ("INLINE" NIL)) "MIXED"|

    structure = parse_mime_structure(source)
    body = select_text_parts(structure)
    assert body == %{plain: nil, html: nil}
    attachments = collect_attachments(structure, body)

    assert Enum.map(attachments, & &1.filename) == [
             "notes.txt",
             "attachment-2",
             "forwarded-message.eml",
             "attachment-4"
           ]

    assert Enum.at(attachments, 3).size == 9
    assert collect_attachments(nil, body) == []
  end

  test "decodes RFC2231 extended filenames and mixed continuations" do
    assert read_mime_param(%{"filename*" => "utf-8''r%C3%A9sum%C3%A9.pdf"}, "filename") ==
             "résumé.pdf"

    assert read_mime_param(
             %{
               "filename*0*" => "utf-8'en'r%C3%A9",
               "filename*1" => "sum",
               "filename*2*" => "%C3%A9.pdf"
             },
             "filename"
           ) == "résumé.pdf"

    assert read_mime_param(%{"name" => "=?UTF-8?B?csOpc3Vtw6kucGRm?="}, "name") ==
             "résumé.pdf"

    assert read_mime_param(%{}, "filename") == nil

    part = %{
      leaf("APPLICATION", "PDF")
      | disposition_params: %{"filename" => " \r\nfile\x00.pdf\t "}
    }

    assert attachment_filename(part) == "file .pdf"

    # NEL, line and paragraph separators and C1 controls too.
    part = %{
      leaf("APPLICATION", "PDF")
      | disposition_params: %{"filename" => "a\u0085b\u2028c\td\u0000.pdf"}
    }

    assert attachment_filename(part) == "a b c d .pdf"
  end

  test "normalizes invalid media type and generates fallback names" do
    assert normalized_mime_type(leaf("TEXT", "HTML")) == "text/html"
    assert normalized_mime_type(leaf("TEXT", "HTML\n")) == "application/octet-stream"

    assert normalized_mime_type(leaf("APPLICATION", "BAD;TYPE")) ==
             "application/octet-stream"

    assert attachment_filename(leaf("APPLICATION", "PDF")) == "attachment-1"
  end

  test "RFC2231 percent escapes require exactly two hexadecimal digits" do
    for value <- ["%+A", "%-A", "%G0", "%0G", "%A", "%", "%%20"] do
      expected = if value == "%%20", do: "% ", else: value
      assert read_mime_param(%{"filename*" => "utf-8''" <> value}, "filename") == expected
      assert read_mime_param(%{"filename*0*" => "utf-8''" <> value}, "filename") == expected
    end

    assert read_mime_param(%{"filename*" => "utf-8''%2b%2D%0a"}, "filename") == "+-\n"
  end

  test "decodes quoted printable soft breaks, hex escapes and unchanged malformed escapes" do
    assert decode_transfer_encoding("caf=E9= \t\r\nline=\nnext=XX", "quoted-printable") ==
             <<"caf", 233, "linenext=XX">>

    assert decode_transfer_encoding(<<0, 255>>, "unknown") == <<0, 255>>
    assert decode_transfer_encoding("==\r\n41", "quoted-printable") == "=41"
    assert decode_transfer_encoding("== \t\n41", "quoted-printable") == "=41"
    assert decode_transfer_encoding("=3D=\r\n41", "quoted-printable") == "=41"
    assert decode_transfer_encoding(<<255, "=00">>, "quoted-printable") == <<255, 0>>
  end

  test "invalid metadata UTF8 is replaced while raw transfer bytes stay intact" do
    assert decode_encoded_words(<<"plain", 0xE9>>) == "plain�"
    assert decode_encoded_words(<<"=?", 0xE9, "?Q?a?=">>) == "a"
    assert read_mime_param(%{"filename*" => <<0xFF, "''x">>}, "filename") == "x"

    values = [
      "TEXT",
      "PLAIN",
      ["NAME", <<0xFF>>, "CHARSET", <<0xFF>>],
      nil,
      nil,
      "7BIT",
      "3",
      "1",
      nil,
      ["ATTACHMENT"]
    ]

    part = parse_mime_structure(values)
    assert part.disposition == "attachment"
    assert part.disposition_params == %{}
    assert attachment_filename(part) == "�"
    assert decode_text_part("hello", part, nil) == %{charset: "�", bytes: "hello"}

    source = <<"\"TEXT\" \"PLAIN\" (\"CHARSET\" \"", 0xFF, "\") NIL NIL \"7BIT\" 3 1">>
    assert parse_mime_structure(source).params["charset"] == "�"
    assert decode_transfer_encoding(<<0xFF, 0x00, 0xE9>>, "7bit") == <<0xFF, 0x00, 0xE9>>
  end

  test "MIME token whitespace tolerates NBSP without altering quoted parameter text" do
    structure =
      parse_mime_structure(~s|"TEXT"\u00a0"PLAIN" ("NAME" "a\u00a0b") NIL NIL "7BIT" 5 1|)

    assert structure.type == "text"
    assert structure.params["name"] == "a\u00a0b"
    assert select_text_parts(structure).plain.part_id == "1"
  end

  test "base64 round trips every byte with padding, missing padding and whitespace" do
    bytes = :binary.list_to_bin(Enum.to_list(0..255))

    for length <- 0..256 do
      value = binary_part(bytes, 0, length)
      encoded = Base.encode64(value)
      assert decode_attachment(encoded, "BASE64") == {:ok, value}
      assert decode_attachment(String.trim_trailing(encoded, "="), "base64") == {:ok, value}

      folded = encoded |> String.codepoints() |> Enum.join("\r\n \t")
      assert decode_attachment(folded, "base64") == {:ok, value}
    end
  end

  test "attachment base64 rejects corruption while display decoding repairs invalid characters" do
    for encoded <- ["a", "a===", "====", "SGVsbG8=oops", "SG!VsbG8=", "SGVsbG8==", "SGVsbG8=\v"] do
      assert decode_attachment(encoded, "base64") == {:error, :malformed_content}
    end

    assert decode_transfer_encoding("SG!VsbG8=", "base64") == "Hello"
    assert decode_transfer_encoding("SGVsbG8=a", "base64") == <<"Hello", 26>>
  end

  test "built-in decoding covers UTF-8 and Latin-1 as Windows-1252; other charsets come back raw" do
    part = %{
      leaf("TEXT", "PLAIN", "1")
      | encoding: "quoted-printable",
        params: %{"charset" => "windows-1252"}
    }

    assert decode_text_part("=93caf=E9=94 =80", part, nil) == "“café” €"

    for label <- ["ISO-8859-1", "latin1", "us-ascii", " iso-8859-1\t"] do
      part = %{leaf("TEXT", "PLAIN", "1") | params: %{"charset" => label}}
      assert decode_text_part(<<"caf", 0xE9, 0x80>>, part, nil) == "café€"
    end

    utf8 = %{leaf("TEXT", "PLAIN", "1") | params: %{"charset" => "utf-8"}}
    assert decode_text_part(<<255, ?a>>, utf8, nil) == "�a"
    assert decode_text_part(<<0xEF, 0xBB, 0xBF, "hi">>, utf8, nil) == "hi"
    assert decode_text_part(<<"hi">>, %{utf8 | params: %{}}, nil) == "hi"

    sjis = %{leaf("TEXT", "PLAIN", "1") | params: %{"charset" => " Shift_JIS "}}

    assert decode_text_part(<<0x82, 0xA0>>, sjis, nil) ==
             %{charset: "Shift_JIS", bytes: <<0x82, 0xA0>>}

    assert decode_text_part(<<0x82, 0xA0>>, sjis, SampleDecoder) == "あ"
  end

  test "built-in decoding matches browsers' TextDecoder for UTF-8 and Windows-1252" do
    %{"cases" => cases} =
      Path.expand("../fixtures/charset_golden.json", __DIR__) |> File.read!() |> :json.decode()

    for %{"name" => name, "label" => label, "bytes" => bytes, "text" => text} <- cases do
      part = %{leaf("TEXT", "PLAIN", "1") | params: %{"charset" => label}}
      assert decode_text_part(Base.decode16!(bytes), part, nil) == text, name
    end
  end

  test "only identity encodings have a sound pre-download decoded size lower bound" do
    for encoding <- ["7bit", "8BIT", "binary", ""] do
      assert decoded_size_lower_bound(%{encoding: encoding, size: 123}) == 123
    end

    for encoding <- ["base64", "quoted-printable", "unknown"] do
      assert decoded_size_lower_bound(%{encoding: encoding, size: 123}) == nil
    end
  end

  test "encoded words decode B/Q and drop only RFC linear whitespace between successful words" do
    assert decode_encoded_words("=?UTF-8?B?Y2Fmw6k=?=") == "café"
    assert decode_encoded_words("=?ISO-8859-1?Q?caf=E9?=") == "café"
    assert decode_encoded_words("=?UTF-8?Q?one?= \r\n\t=?UTF-8?Q?two?=") == "onetwo"
    assert decode_encoded_words("=?UTF-8?Q?one_?= =?UTF-8?Q?_two?=") == "one  two"
    assert decode_encoded_words("ASCII =?UTF-8?Q?word?= text") == "ASCII word text"
    assert decode_encoded_words("=?UTF-8?Q?one?=\v=?UTF-8?Q?two?=") == "one\vtwo"
    assert decode_encoded_words("=?UTF-8?Q?one?= \n=?UTF-8?Q?two?=") == "one \ntwo"
    assert decode_encoded_words("=?UTF-8?Q?one?= =?unknown?Q?two?=") == "one two"
    assert decode_encoded_words("=?UTF-8?Q?one?= =?UTF-8?B?!!!?=") == "one !!!"
  end

  test "RFC 2231 parameters use the decoder with a trimmed label, else lossy UTF-8" do
    assert read_mime_param(%{"filename*" => "shift_jis''%82%A0"}, "filename", SampleDecoder) ==
             "あ"

    assert read_mime_param(%{"filename*" => " shift_jis ''%82%A0"}, "filename", SampleDecoder) ==
             "あ"

    assert read_mime_param(%{"filename*" => "shift_jis''%82%A0"}, "filename") == "\uFFFD\uFFFD"
  end

  test "encoded words use multibyte decoders and keep unknown charset failures distinct" do
    assert decode_encoded_words("=?shift_jis?B?gqA=?=", SampleDecoder) == "あ"
    assert decode_encoded_words("=?shift_jis?B?gqA=?=") == "gqA="
    assert decode_encoded_words("=?windows-1252?Q?=80?=") == "€"
    assert decode_encoded_words("=?unknown?B?SGk=?=") == "SGk="
    assert decode_encoded_words("=?\u00a0windows-1252\u00a0?B?Y2Fm6Q==?=") == "Y2Fm6Q=="
    assert decode_encoded_words("=?replacement?Q?data?=") == "data"
    assert decode_encoded_words("=?utf-8?Q?one?= =?unknown?B?SGk=?=") == "one SGk="

    assert decode_text_part(
             "café",
             %{encoding: "7bit", params: %{"charset" => "unknown"}},
             nil
           ) ==
             %{charset: "unknown", bytes: "café"}
  end
end
