defmodule IMAPClient.TransportTest do
  use ExUnit.Case, async: true

  import IMAPClient.Transport

  alias IMAPClient.Peer

  @event_ms 30_000

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

  defp now_ms do
    System.monotonic_time(:millisecond)
  end

  # Any ClientHello byte makes the peer's recv return {:ok, _}, so its long
  # window only bounds failure reporting. The peer's recv outlasts the test's
  # own waits, and the test limit outlasts the peer.
  @tag timeout: 4 * @event_ms
  test "TLS upgrade with an exhausted connect deadline sends no ClientHello" do
    parent = self()

    peer =
      peer(fn socket ->
        send(parent, :expired_deadline_peer_ready)
        send(parent, {:expired_deadline_wire, :gen_tcp.recv(socket, 0, 3 * @event_ms)})
      end)

    caller =
      task(fn ->
        {:ok, raw} = connect_tcp(tls_config(peer), @event_ms)

        try do
          receive do
            :upgrade ->
              send(
                parent,
                {:expired_deadline_result, upgrade(raw, tls_config(peer), now_ms() - 1)}
              )
          end
        after
          abort(raw)
        end
      end)

    # A reset before accept can make accept itself fail on macOS. Establish
    # the peer first so this observes upgrade's wire behavior, not that race.
    assert_receive :expired_deadline_peer_ready, @event_ms
    send(caller, :upgrade)
    assert_receive {:expired_deadline_result, {:error, :timeout}}, @event_ms
    assert_receive {:expired_deadline_wire, {:error, :closed}}, @event_ms
  end
end
