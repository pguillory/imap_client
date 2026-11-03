defmodule IMAPClient.IOWorker do
  # Internal to IMAPClient.
  @moduledoc false

  alias IMAPClient.Transport

  # Internal dependency options keep deadline tests independent of scheduler latency.
  def start(owner, operation, opts \\ []) do
    ref = make_ref()

    {pid, monitor} =
      :erlang.spawn_opt(
        fn ->
          # A blocked LOGIN sender must not expose its closure or last message
          # through process inspection or an exception/crash report.
          Process.flag(:sensitive, true)

          result =
            try do
              perform(owner, ref, operation, opts)
            catch
              # A socket call that raises or exits (the socket or its TLS process
              # closed under it) means the connection is closed.
              _kind, _reason -> {:error, :closed}
            end

          if result != :quiet, do: send(owner, {:imap_io, ref, result})
        end,
        [:link, :monitor]
      )

    %{pid: pid, monitor: monitor, ref: ref}
  end

  defp perform(owner, ref, {:connect, config, deadline_ms}, opts) do
    owner_monitor = Process.monitor(owner)
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)

    with {:ok, raw} <- timed(deadline_ms, &Transport.connect_tcp(config, &1), clock),
         :ok <- ready(owner, ref, owner_monitor, {:raw_ready, raw}, :upgrade, deadline_ms, clock),
         {:ok, socket} <- Transport.upgrade(raw, config, deadline_ms, opts),
         :ok <-
           ready(owner, ref, owner_monitor, {:socket_ready, socket}, :adopt, deadline_ms, clock),
         :ok <- Transport.transfer(socket, owner),
         :ok <- ready(owner, ref, owner_monitor, {:connected, socket}, :ack, deadline_ms, clock) do
      :quiet
    end
  end

  defp perform(_owner, _ref, {:send, socket, bytes, deadline_ms}, _opts) do
    timed(deadline_ms, &Transport.send_bytes(socket, bytes, &1))
  end

  defp perform(_owner, _ref, {:activate, socket}, _opts) do
    Transport.activate(socket)
  end

  defp ready(owner, ref, monitor, event, acknowledgment, deadline_ms, clock) do
    send(owner, {:imap_io, ref, event})

    receive do
      {^acknowledgment, ^ref} -> :ok
      {:DOWN, ^monitor, :process, ^owner, _reason} -> {:error, :closed}
    after
      max(deadline_ms - clock.(), 0) -> {:error, :timeout}
    end
  end

  defp timed(deadline_ms, operation, clock \\ fn -> System.monotonic_time(:millisecond) end) do
    remaining_ms = deadline_ms - clock.()
    if remaining_ms > 0, do: operation.(remaining_ms), else: {:error, :timeout}
  end
end
