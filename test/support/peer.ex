defmodule IMAPClient.Peer do
  @moduledoc false

  use GenServer, restart: :temporary

  alias IMAPClient.SocketWait

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def port(server) do
    GenServer.call(server, :port)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :raw,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, {_address, port}} = :inet.sockname(listener)
    # One script per accepted connection, in order.
    scripts = List.wrap(Keyword.fetch!(opts, :script))
    worker = spawn_link(fn -> serve(listener, scripts) end)

    {:ok, %{listener: listener, port: port, worker: worker}}
  end

  defp serve(_listener, []) do
    :ok
  end

  defp serve(listener, [script | scripts]) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        try do
          script.(socket)
        after
          :gen_tcp.close(socket)
        end

        serve(listener, scripts)

      {:error, :closed} ->
        :ok
    end
  end

  @impl true
  def handle_call(:port, _from, state) do
    {:reply, state.port, state}
  end

  @impl true
  def handle_info({:EXIT, worker, :normal}, %{worker: worker} = state) do
    {:noreply, state}
  end

  def handle_info({:EXIT, worker, reason}, %{worker: worker} = state) do
    {:stop, reason, state}
  end

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listener)
    Process.exit(state.worker, :shutdown)
  end

  def line(socket) do
    :ok = :inet.setopts(socket, packet: :line)
    result = SocketWait.recv(:gen_tcp, socket)
    _ = :inet.setopts(socket, packet: :raw)

    case result do
      {:ok, line} -> String.trim_trailing(line, "\r\n")
      other -> other
    end
  end
end
