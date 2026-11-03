defmodule IMAPClient.MailboxName do
  # Internal to IMAPClient.
  #
  # Mailbox names on the wire are modified UTF-7 (RFC 3501 section 5.1.3): printable
  # ASCII stands for itself, "&" is "&-", and any other run of characters is "&", the
  # modified base64 ("," for "/", no padding) of its UTF-16BE code units, and "-".
  # Callers see and pass ordinary Unicode names (a Gmail "Envoyés" folder); names are
  # decoded where LIST is parsed and encoded where a mailbox is sent. Known limitation:
  # a server name with a bare "&" (not valid modified UTF-7) is shown as sent but
  # encodes to "&-" and can't be selected; major providers encode correctly.
  @moduledoc false

  import Bitwise

  @alphabet ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+,"
  @values @alphabet |> Enum.with_index() |> Map.new()

  defguardp direct?(code) when code >= 0x20 and code <= 0x7E

  @doc """
  A Unicode mailbox name in modified UTF-7, for the wire. A binary that is not valid
  UTF-8 is returned unchanged.
  """
  def encode(name) when is_binary(name) do
    if String.valid?(name), do: encode(String.to_charlist(name), [], []), else: name
  end

  defp encode([], shifted, out) do
    IO.iodata_to_binary(Enum.reverse(flush(shifted, out)))
  end

  defp encode([code | rest], shifted, out) when direct?(code) do
    out = flush(shifted, out)
    encode(rest, [], [if(code == ?&, do: "&-", else: <<code>>) | out])
  end

  defp encode([code | rest], shifted, out) do
    encode(rest, [code | shifted], out)
  end

  defp flush([], out) do
    out
  end

  defp flush(shifted, out) do
    bytes = :unicode.characters_to_binary(Enum.reverse(shifted), :utf8, {:utf16, :big})
    base64 = bytes |> Base.encode64(padding: false) |> String.replace("/", ",")
    ["&" <> base64 <> "-" | out]
  end

  @doc """
  A wire mailbox name decoded to Unicode. Anything that isn't canonical modified UTF-7
  (so that encoding the result gives back exactly the input) is returned unchanged: an
  unterminated shift, a character outside the alphabet, nonzero padding, a shifted
  printable character, a control character or unpaired surrogate, or two adjacent
  shifts.
  """
  def decode(raw) when is_binary(raw) do
    case decode(raw, false, []) do
      {:ok, out} -> IO.iodata_to_binary(Enum.reverse(out))
      :error -> raw
    end
  end

  defp decode(<<>>, _after_shift?, out) do
    {:ok, out}
  end

  defp decode(<<"&-", rest::binary>>, _after_shift?, out) do
    decode(rest, false, ["&" | out])
  end

  defp decode(<<"&", rest::binary>>, after_shift?, out) do
    with false <- after_shift?,
         [b64, rest] <- :binary.split(rest, "-"),
         {:ok, text} <- decode_shift(b64) do
      decode(rest, true, [text | out])
    else
      _ -> :error
    end
  end

  defp decode(<<code, rest::binary>>, _after_shift?, out) when direct?(code) do
    decode(rest, false, [<<code>> | out])
  end

  defp decode(_raw, _after_shift?, _out) do
    :error
  end

  # One shift's base64 as UTF-8 text, or :error unless it is canonical.
  defp decode_shift(b64) do
    with {:ok, bytes, buffer, bits} <- shift_bytes(b64, 0, 0, []),
         # Leftover bits must be zero padding shorter than one base64 digit.
         true <- bits < 6 and buffer == 0,
         true <- bytes != [] and rem(length(bytes), 2) == 0,
         units = units(bytes),
         true <- Enum.all?(units, &shiftable?/1),
         true <- paired?(units) do
      {:ok, :unicode.characters_to_binary(:binary.list_to_bin(bytes), {:utf16, :big}, :utf8)}
    else
      _ -> :error
    end
  end

  defp shift_bytes(<<>>, buffer, bits, bytes) do
    {:ok, Enum.reverse(bytes), buffer, bits}
  end

  defp shift_bytes(<<char, rest::binary>>, buffer, bits, bytes) do
    case Map.fetch(@values, char) do
      {:ok, value} ->
        buffer = buffer <<< 6 ||| value
        bits = bits + 6

        if bits >= 8 do
          bits = bits - 8
          byte = buffer >>> bits &&& 0xFF
          shift_bytes(rest, buffer &&& (1 <<< bits) - 1, bits, [byte | bytes])
        else
          shift_bytes(rest, buffer, bits, bytes)
        end

      :error ->
        :error
    end
  end

  defp units([high, low | rest]) do
    [high <<< 8 ||| low | units(rest)]
  end

  defp units([]) do
    []
  end

  # A shift must not encode a character that stands for itself. Control characters
  # and unpaired surrogates come only from a broken or hostile server and would make
  # an unselectable name: it is shown as sent instead.
  defp shiftable?(unit) do
    unit >= 0x20 and not direct?(unit) and not (unit >= 0x7F and unit <= 0x9F)
  end

  defp paired?([high, low | rest]) when high in 0xD800..0xDBFF do
    low in 0xDC00..0xDFFF and paired?(rest)
  end

  defp paired?([unit | rest]) do
    unit not in 0xD800..0xDFFF and paired?(rest)
  end

  defp paired?([]) do
    true
  end
end
