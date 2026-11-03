defmodule IMAPClient.SampleDecoder do
  # A test charset decoder: UTF-8, one Shift_JIS character, and a label that crashes.
  @moduledoc false

  @behaviour IMAPClient.CharsetDecoder

  @impl true
  def decode(bytes, label) do
    case String.downcase(label) do
      "utf-8" -> {:ok, String.replace_invalid(bytes)}
      "shift_jis" when bytes == <<0x82, 0xA0>> -> {:ok, "あ"}
      "x-crash" -> raise ArgumentError, "decoder failed on #{inspect(bytes)}"
      _ -> :error
    end
  end
end
