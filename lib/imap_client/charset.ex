defmodule IMAPClient.Charset do
  # Internal to IMAPClient. The built-in charset decoder and the call into an
  # application's decoder.
  @moduledoc false

  @behaviour IMAPClient.CharsetDecoder

  require Logger

  # WHATWG Encoding labels for UTF-8 and for windows-1252, which browsers also use for
  # US-ASCII and ISO-8859-1.
  @utf8_labels ~w(unicode-1-1-utf-8 unicode11utf8 unicode20utf8 utf-8 utf8 x-unicode20utf8)
  @windows_1252_labels ~w(ansi_x3.4-1968 ascii cp1252 cp819 csisolatin1 ibm819 iso-8859-1
                          iso-ir-100 iso8859-1 iso88591 iso_8859-1 iso_8859-1:1987 l1 latin1
                          us-ascii windows-1252 x-cp1252)

  # Windows-1252 differs from Latin-1 only in 0x80..0x9F. The five undefined bytes map to
  # the C1 control of the same value, as WHATWG specifies.
  @windows_1252_high {0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6,
                      0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F, 0x90, 0x2018, 0x2019,
                      0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A,
                      0x0153, 0x9D, 0x017E, 0x0178}

  @impl true
  def decode(bytes, label) when is_binary(bytes) and is_binary(label) do
    case String.downcase(String.trim(label, " \t\n\f\r")) do
      label when label in @utf8_labels -> {:ok, utf8(bytes)}
      label when label in @windows_1252_labels -> {:ok, windows_1252(bytes)}
      _ -> :error
    end
  end

  @doc """
  Lossy UTF-8 as a browser's TextDecoder: one leading BOM is dropped, and each maximal
  invalid subsequence becomes U+FFFD.
  """
  def utf8(<<0xEF, 0xBB, 0xBF, rest::binary>>) do
    String.replace_invalid(rest)
  end

  def utf8(bytes) do
    String.replace_invalid(bytes)
  end

  defp windows_1252(bytes) do
    for <<byte <- bytes>>, into: "" do
      if byte in 0x80..0x9F do
        <<elem(@windows_1252_high, byte - 0x80)::utf8>>
      else
        <<byte::utf8>>
      end
    end
  end

  @doc """
  Decodes with the application's decoder module (nil for the built-in one). Returns
  `{:ok, text}` or `:error`.
  """
  def decode_with(nil, bytes, label) do
    decode(bytes, label)
  end

  def decode_with(decoder, bytes, label) do
    case decoder.decode(bytes, label) do
      {:ok, text} when is_binary(text) -> {:ok, String.replace_invalid(text)}
      _ -> :error
    end
  catch
    # The decoder is application code outside the library's control: a failure means
    # this text can't be decoded, not that the session failed. Its reason may contain
    # message bytes, so only a fixed warning is logged.
    _kind, _reason ->
      Logger.warning("IMAP charset decoder failed")
      :error
  end
end
