defmodule IMAPClient.Framer do
  # Internal to IMAPClient.
  @moduledoc false

  defstruct buffer: "",
            scan_from_bytes: 0,
            logical: [],
            literal: [],
            remaining: nil,
            logical_size_bytes: 0,
            logical_limit_bytes: 64 * 1024 * 1024 + 1024 * 1024,
            reject_list_literals?: false,
            literal_limit_bytes: 1024 * 1024,
            line_limit_bytes: 1024 * 1024

  def new(opts \\ []) do
    struct!(__MODULE__, opts)
  end

  # Literal payload is retained as chunks until complete, avoiding a growing
  # full-body copy every time the socket delivers another packet.
  def feed(state, bytes) do
    consume(state, bytes, [])
  end

  defp consume(%{remaining: remaining} = state, bytes, lines) when is_integer(remaining) do
    take = min(remaining, byte_size(bytes))
    <<part::binary-size(take), rest::binary>> = bytes
    state = %{state | remaining: remaining - take, literal: [part | state.literal]}

    if state.remaining == 0 do
      value = state.literal |> Enum.reverse() |> IO.iodata_to_binary() |> quote_bytes()

      consume(
        %{state | remaining: nil, literal: [], logical: [value | state.logical]},
        rest,
        lines
      )
    else
      {:ok, Enum.reverse(lines), state}
    end
  end

  defp consume(state, bytes, lines) do
    buffer = state.buffer <> bytes

    start = max(state.scan_from_bytes - 1, 0)

    case :binary.match(buffer, "\r\n", scope: {start, byte_size(buffer) - start}) do
      :nomatch ->
        # A trailing CR may be the first half of CRLF, not response text.
        text_size = byte_size(buffer) - if(String.ends_with?(buffer, "\r"), do: 1, else: 0)

        if text_size > state.line_limit_bytes,
          do: {:error, :response_too_large},
          else:
            {:ok, Enum.reverse(lines),
             %{state | buffer: buffer, scan_from_bytes: byte_size(buffer)}}

      {offset, 2} when offset > state.line_limit_bytes ->
        {:error, :response_too_large}

      {offset, 2} ->
        <<line::binary-size(offset), "\r\n", rest::binary>> = buffer
        state = %{state | buffer: "", scan_from_bytes: 0}

        case literal_marker(line, state.logical != []) do
          {_prefix, _length} when state.reject_list_literals? ->
            {:error, :unsupported_literal}

          {prefix, length} when is_integer(length) and length <= state.literal_limit_bytes ->
            size = state.logical_size_bytes + byte_size(prefix) + length

            if size > state.logical_limit_bytes do
              {:error, :response_too_large}
            else
              consume(
                %{
                  state
                  | logical: [prefix | state.logical],
                    remaining: length,
                    logical_size_bytes: size
                },
                rest,
                lines
              )
            end

          {_prefix, _length} ->
            {:error, :response_too_large}

          nil ->
            if state.logical_size_bytes + byte_size(line) > state.logical_limit_bytes do
              {:error, :response_too_large}
            else
              logical = [line | state.logical] |> Enum.reverse() |> IO.iodata_to_binary()
              state = %{state | logical: [], logical_size_bytes: 0}

              if rest == "",
                do: {:ok, Enum.reverse([logical | lines]), state},
                else: consume(state, rest, [logical | lines])
            end
        end
    end
  end

  defp literal_marker(line, continuing?) do
    # resp-text in OK/NO/BAD/BYE is free text, even when it ends with {123}.
    data? = continuing? or Regex.match?(~r/^\*\s+(?:\d+\s+FETCH|LIST|LSUB|STATUS)\b/i, line)

    if data? do
      case Regex.run(~r/~?\{(\d+)\+?\}\z/, line, return: :index) do
        [{_start, _}, {_number_start, number_size}] when number_size > 20 ->
          {"", :too_large}

        [{start, _}, {number_start, number_size}] ->
          length = binary_part(line, number_start, number_size) |> String.to_integer()
          {binary_part(line, 0, start), length}

        _ ->
          nil
      end
    end
  end

  defp quote_bytes(bytes) do
    escaped =
      bytes
      |> :binary.replace("\\", "\\\\", [:global])
      |> :binary.replace("\"", "\\\"", [:global])

    "\"" <> escaped <> "\""
  end
end
