defmodule IMAPClient.Text do
  # Internal. Cleans untrusted header text, such as an attachment file name, for display
  # on one line.
  @moduledoc false

  defguardp control?(cp) when cp in 0x00..0x1F or cp in 0x7F..0x9F

  # JavaScript's String.prototype.trim whitespace: ECMAScript WhiteSpace plus
  # LineTerminator, which includes NBSP and the BOM but not NEL.
  defguardp whitespace?(cp)
            when cp in [9, 10, 11, 12, 13, 32, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F] or
                   cp in [0x205F, 0x3000, 0xFEFF] or cp in 0x2000..0x200A

  @doc """
  The text on one line and trimmed: each run of control characters (C0, DEL, C1) and
  line or paragraph separators becomes one space, then leading and trailing whitespace
  goes. Invalid UTF-8 bytes are kept and count as content.
  """
  def one_line(text) when is_binary(text) do
    text |> flatten(false, []) |> IO.iodata_to_binary() |> trim()
  end

  defp flatten(<<cp::utf8, rest::binary>>, in_run?, acc)
       when control?(cp) or cp in [0x2028, 0x2029] do
    flatten(rest, true, if(in_run?, do: acc, else: [acc, ?\s]))
  end

  defp flatten(<<cp::utf8, rest::binary>>, _in_run?, acc) do
    flatten(rest, false, [acc, <<cp::utf8>>])
  end

  defp flatten(<<byte, rest::binary>>, _in_run?, acc) do
    flatten(rest, false, [acc, byte])
  end

  defp flatten(<<>>, _in_run?, acc) do
    acc
  end

  defp trim(text) do
    case content(text, 0, nil, nil) do
      {nil, nil} -> ""
      {first, last} -> binary_part(text, first, last - first)
    end
  end

  # The byte offsets where non-whitespace content starts and ends.
  defp content(<<cp::utf8, rest::binary>>, at, first, last) do
    size = byte_size(<<cp::utf8>>)

    if whitespace?(cp) do
      content(rest, at + size, first, last)
    else
      content(rest, at + size, first || at, at + size)
    end
  end

  defp content(<<_invalid, rest::binary>>, at, first, _last) do
    content(rest, at + 1, first || at, at + 1)
  end

  defp content(<<>>, _at, first, last) do
    {first, last}
  end
end
