defmodule IMAPClient.FakeServer.Peer do
  # Internal to the fake; deliberately independent of the client wire parser.
  @moduledoc false

  # A fake must not become an unbounded in-memory mail sink through malformed input.
  @max_command_bytes 16 * 1024 * 1024

  def wait(server) do
    monitor = Process.monitor(server)

    receive do
      {:socket, socket} ->
        greeting = GenServer.call(server, :register)
        :ok = :gen_tcp.send(socket, greeting)
        :ok = :inet.setopts(socket, active: :once)

        loop(%{
          server: server,
          monitor: monitor,
          socket: socket,
          buffer: "",
          assembled: "",
          literal: nil,
          # True while an AUTHENTICATE exchange waits for the client's next SASL line.
          sasl: false,
          stalled: false,
          # A response held by a {:hold, owner} script: %{ref, bytes, owner monitor}.
          held: nil
        })

      {:DOWN, ^monitor, _, _, _} ->
        :ok
    end
  end

  defp loop(state) do
    receive do
      {:tcp, socket, bytes} when socket == state.socket ->
        case consume(%{state | buffer: state.buffer <> bytes}) do
          {:ok, state} ->
            :inet.setopts(socket, active: :once)
            loop(state)

          :close ->
            :gen_tcp.close(socket)
        end

      {:push, bytes} ->
        :gen_tcp.send(state.socket, bytes)
        loop(state)

      {:release, ref} when state.held != nil and state.held.ref == ref ->
        release(state)

      {:DOWN, monitor, _, _, _} when state.held != nil and state.held.monitor == monitor ->
        release(state)

      {:tcp_closed, _} ->
        :ok

      {:tcp_error, _, _} ->
        :gen_tcp.close(state.socket)

      {:DOWN, monitor, _, _, _} when monitor == state.monitor ->
        :gen_tcp.close(state.socket)

      :close ->
        :gen_tcp.close(state.socket)
    end
  end

  # The held response goes out, then any command that arrived meanwhile is read.
  defp release(state) do
    Process.demonitor(state.held.monitor, [:flush])
    :gen_tcp.send(state.socket, state.held.bytes)

    case consume(%{state | held: nil}) do
      {:ok, state} -> loop(state)
      :close -> :gen_tcp.close(state.socket)
    end
  end

  defp consume(%{buffer: buffer, assembled: assembled})
       when byte_size(buffer) + byte_size(assembled) > @max_command_bytes do
    :close
  end

  defp consume(%{held: held} = state) when held != nil do
    {:ok, state}
  end

  defp consume(%{stalled: true} = state) do
    {:ok, %{state | buffer: ""}}
  end

  defp consume(%{literal: count, buffer: buffer} = state) when is_integer(count) do
    if byte_size(buffer) >= count do
      <<literal::binary-size(count), rest::binary>> = buffer
      consume(%{state | literal: nil, assembled: state.assembled <> literal, buffer: rest})
    else
      {:ok, state}
    end
  end

  defp consume(%{sasl: true} = state) do
    case :binary.match(state.buffer, "\r\n") do
      :nomatch ->
        {:ok, state}

      {position, 2} ->
        <<line::binary-size(position), "\r\n", rest::binary>> = state.buffer
        reply = GenServer.call(state.server, {:sasl, line})
        respond(%{state | buffer: rest, sasl: false}, reply)
    end
  end

  defp consume(state) do
    case :binary.match(state.buffer, "\r\n") do
      :nomatch ->
        {:ok, state}

      {position, 2} ->
        <<line::binary-size(position), "\r\n", rest::binary>> = state.buffer

        case Regex.run(~r/\{([0-9]+)(\+)?\}$/, line) do
          [_, count] ->
            continue_literal(state, line, rest, String.to_integer(count))

          [_, _, "+"] ->
            :gen_tcp.send(state.socket, "* BAD nonsynchronizing literal unsupported\r\n")
            :close

          nil ->
            complete(%{state | buffer: rest}, state.assembled <> line)
        end
    end
  end

  defp continue_literal(state, line, rest, count) do
    cond do
      count > @max_command_bytes ->
        :close

      rest != "" ->
        # Synchronizing literals cannot be pipelined before the continuation.
        :gen_tcp.send(state.socket, "* BAD literal before continuation\r\n")
        :close

      GenServer.call(state.server, {:continue, state.assembled <> line}) ->
        :gen_tcp.send(state.socket, "+ literal follows\r\n")

        {:ok,
         %{state | buffer: rest, assembled: state.assembled <> line <> "\r\n", literal: count}}

      true ->
        tag = line |> String.split(" ", parts: 2) |> hd()
        :gen_tcp.send(state.socket, [tag, " NO command state invalid\r\n"])
        {:ok, %{state | buffer: "", assembled: "", literal: nil}}
    end
  end

  defp complete(state, command) do
    reply =
      case parse(command) do
        {:ok, tokens} -> GenServer.call(state.server, {:command, tokens})
        :error -> "* BAD malformed command\r\n"
      end

    respond(state, reply)
  end

  defp respond(state, reply) do
    case reply do
      :close ->
        :close

      {:sasl, bytes} ->
        :gen_tcp.send(state.socket, bytes)
        consume(%{state | assembled: "", sasl: true})

      :stall ->
        {:ok, %{state | assembled: "", buffer: "", stalled: true}}

      {:hold, owner, bytes} ->
        ref = make_ref()
        send(owner, {:imap_fake_held, {self(), ref}})
        held = %{ref: ref, bytes: bytes, monitor: Process.monitor(owner)}
        {:ok, %{state | assembled: "", held: held}}

      {:close_after, bytes} ->
        :gen_tcp.send(state.socket, bytes)
        :close

      bytes ->
        :gen_tcp.send(state.socket, bytes)
        consume(%{state | assembled: ""})
    end
  end

  @doc false
  def parse(binary) do
    case scan(binary, [], false) do
      {:ok, values, ""} -> {:ok, values}
      _ -> :error
    end
  end

  defp scan("", values, false) do
    {:ok, Enum.reverse(values), ""}
  end

  defp scan("", _, true) do
    :error
  end

  defp scan(<<" ", rest::binary>>, values, nested) do
    scan(rest, values, nested)
  end

  defp scan(<<")", rest::binary>>, values, true) do
    {:ok, Enum.reverse(values), rest}
  end

  defp scan(<<")", _::binary>>, _, false) do
    :error
  end

  defp scan(<<"(", rest::binary>>, values, nested) do
    with {:ok, child, rest} <- scan(rest, [], true),
         do: continue_scan(rest, [child | values], nested)
  end

  defp scan(<<"\"", rest::binary>>, values, nested) do
    with {:ok, value, rest} <- quoted(rest, ""), do: continue_scan(rest, [value | values], nested)
  end

  defp scan(<<"{", rest::binary>>, values, nested) do
    case :binary.match(rest, "}\r\n") do
      {position, 3} ->
        <<count::binary-size(position), "}\r\n", rest::binary>> = rest

        with {count, ""} <- Integer.parse(count),
             true <- count >= 0 and byte_size(rest) >= count do
          <<value::binary-size(count), rest::binary>> = rest
          continue_scan(rest, [{:literal, value} | values], nested)
        else
          _ -> :error
        end

      :nomatch ->
        :error
    end
  end

  defp scan(binary, values, nested) do
    case atom(binary, "", false) do
      {:ok, "", _} -> :error
      {:ok, value, rest} -> scan(rest, [value | values], nested)
      :error -> :error
    end
  end

  defp continue_scan("", values, nested) do
    scan("", values, nested)
  end

  defp continue_scan(<<byte, _::binary>> = rest, values, nested) when byte in [32, ?)] do
    scan(rest, values, nested)
  end

  defp continue_scan(_, _, _) do
    :error
  end

  defp quoted(<<"\"", rest::binary>>, value) do
    {:ok, value, rest}
  end

  defp quoted(<<"\\", escaped, rest::binary>>, value) when escaped in [?", ?\\] do
    quoted(rest, <<value::binary, escaped>>)
  end

  defp quoted(<<byte, rest::binary>>, value) when byte not in [0, 10, 13, ?\\] do
    quoted(rest, <<value::binary, byte>>)
  end

  defp quoted(_, _) do
    :error
  end

  defp atom("", value, false) do
    {:ok, value, ""}
  end

  defp atom("", _, true) do
    :error
  end

  defp atom(<<byte, _::binary>> = rest, value, false) when byte in [32, ?(, ?)] do
    {:ok, value, rest}
  end

  defp atom(<<"[", rest::binary>>, value, false) do
    atom(rest, value <> "[", true)
  end

  defp atom(<<"]", rest::binary>>, value, true) do
    atom(rest, value <> "]", false)
  end

  defp atom(<<byte, rest::binary>>, value, bracket) when byte not in [0, 10, 13, ?", ?{] do
    atom(rest, <<value::binary, byte>>, bracket)
  end

  defp atom(_, _, _) do
    :error
  end
end
