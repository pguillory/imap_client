defmodule IMAPClient.TLSPeer do
  @moduledoc false

  use GenServer

  alias IMAPClient.SocketWait

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def port(server) do
    GenServer.call(server, :port)
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok, listener} =
      :ssl.listen(0,
        mode: :binary,
        active: false,
        packet: :raw,
        reuseaddr: true,
        ip: {127, 0, 0, 1},
        certfile: opts |> Keyword.fetch!(:certfile) |> String.to_charlist(),
        keyfile: opts |> Keyword.fetch!(:keyfile) |> String.to_charlist(),
        versions: [:"tlsv1.3", :"tlsv1.2"]
      )

    {:ok, {_address, port}} = :ssl.sockname(listener)
    parent = self()
    script = Keyword.fetch!(opts, :script)
    observer = Keyword.fetch!(opts, :observer)
    worker = spawn_link(fn -> accept(listener, parent, observer, script) end)
    {:ok, %{listener: listener, port: port, worker: worker}}
  end

  defp accept(listener, parent, observer, script) do
    case :ssl.transport_accept(listener, SocketWait.timeout_ms()) do
      {:ok, socket} ->
        try do
          case :ssl.handshake(socket, SocketWait.timeout_ms()) do
            {:ok, socket} ->
              send(observer, {:imap_tls_peer, parent, :connected})
              script.(socket)

            {:error, reason} ->
              send(observer, {:imap_tls_peer, parent, {:handshake_error, reason}})
          end
        after
          :ssl.close(socket, 100)
        end

      {:error, reason} ->
        send(observer, {:imap_tls_peer, parent, {:accept_error, reason}})
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
    :ssl.close(state.listener, 100)
    Process.exit(state.worker, :shutdown)
  end

  def line(socket) do
    :ok = :ssl.setopts(socket, packet: :line)
    result = SocketWait.recv(:ssl, socket)
    :ok = :ssl.setopts(socket, packet: :raw)

    case result do
      {:ok, line} -> String.trim_trailing(line, "\r\n")
      other -> other
    end
  end
end
