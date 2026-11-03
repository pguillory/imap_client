defmodule IMAPClient.CharsetDecoder do
  @moduledoc """
  Decodes message text in a named character set.

  The library decodes UTF-8, US-ASCII and Latin-1 (as Windows-1252, like browsers) by
  itself. To cover more character sets, implement this behaviour and pass the module as
  `:charset_decoder` in the session config (and to `IMAPClient.fetch_envelopes/3`).
  It then replaces the built-in decoding for every charset-labelled decode, so it must
  handle UTF-8 and Latin-1 too (`encoding_rs` does; see the README): MIME text bodies, RFC 2047 encoded
  words in headers and RFC 2231 parameters such as attachment file names.

  `decode/2` gets the raw bytes and the charset label as the message declared it. Body
  and parameter labels arrive trimmed, with an empty label already replaced by
  `"utf-8"`; encoded-word labels arrive as written. Return `{:ok, text}` with valid
  UTF-8, or `:error` when the label is unknown. On `:error` (or if the decoder raises),
  a text body comes back as `%{charset: label, bytes: bytes}`, an encoded word keeps its
  encoded payload, and a parameter is read as lossy UTF-8.
  """

  @callback decode(bytes :: binary(), label :: String.t()) :: {:ok, String.t()} | :error
end
