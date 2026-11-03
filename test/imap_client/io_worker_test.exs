defmodule IMAPClient.IOWorkerTest do
  use ExUnit.Case, async: true

  import IMAPClient.IOWorker

  alias IMAPClient.Peer

  defp peer(script) do
    start_supervised!({Peer, script: script})
  end

  defp task(function) do
    start_supervised!(
      Supervisor.child_spec({Task, function}, id: make_ref(), restart: :temporary)
    )
  end

  defp tls_config(peer) do
    %{
      host: "127.0.0.1",
      port: Peer.port(peer),
      cacertfile: Path.expand("../fixtures/tls/ca.pem", __DIR__)
    }
  end

  test "TCP establishment and TLS handshake share one original absolute deadline" do
    parent = self()
    clock_agent = start_supervised!({Agent, fn -> 0 end})

    peer =
      peer(fn socket ->
        # The peer holds the socket open; the injected TLS connector returns the result.
        :gen_tcp.recv(socket, 0, :infinity)
      end)

    # Advance a controlled clock at the real TCP handoff, then observe the exact
    # TLS budget instead of timing scheduler delivery of a timeout. Real TLS
    # handshakes stay covered by the cancellation and certificate tests.
    opts = [
      clock: fn -> Agent.get(clock_agent, & &1) end,
      tls_connect: fn socket, options, timeout_ms ->
        send(parent, {:tls_connect, socket, Keyword.fetch!(options, :verify), timeout_ms})
        {:error, :timeout}
      end
    ]

    task(fn ->
      job = start(self(), {:connect, tls_config(peer), 8_000}, opts)

      receive do
        {:imap_io, ref, {:raw_ready, raw}} ->
          try do
            send(parent, {:raw_handoff, self(), raw})

            receive do
              :continue_upgrade -> send(job.pid, {:upgrade, ref})
            end

            receive do
              {:imap_io, ^ref, result} ->
                send(parent, {:shared_deadline_result, result})
            end
          after
            IMAPClient.Transport.abort(raw)
          end
      end
    end)

    assert_receive {:raw_handoff, worker_owner, raw}
    :ok = Agent.update(clock_agent, fn _ -> 4_000 end)
    send(worker_owner, :continue_upgrade)
    assert_receive {:tls_connect, ^raw, :verify_peer, 4_000}
    assert_receive {:shared_deadline_result, {:error, :timeout}}
  end
end
