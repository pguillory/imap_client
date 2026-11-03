defmodule IMAPClient.CancellationTest do
  use ExUnit.Case, async: true

  import IMAPClient

  alias IMAPClient.Error
  alias IMAPClient.Peer
  alias IMAPClient.TLSPeer

  # Every test here connects, and appends, with these budgets; the APPEND tests
  # connect before their measured part. Each operation's deadline starts when it
  # is issued. In the stalled-handshake and backpressured-APPEND tests, the bounded
  # waits before the peer sees the abort total well under those deadlines, so only
  # cancellation can close the socket. The connection aborts with linger 0, so the
  # peer sees a reset or close promptly; a peer that still sees nothing within
  # @observe_ms has not been cancelled, and the test fails.
  @test_timeout_ms 60_000
  @connect_ms 2 * @test_timeout_ms
  @append_ms 2 * @test_timeout_ms
  @handshake_event_ms 45_000
  @event_ms 30_000
  @cancel_ms 20_000
  @observe_ms 10_000

  defp task(function) do
    start_supervised!(
      Supervisor.child_spec({Task, function}, id: make_ref(), restart: :temporary)
    )
  end

  defp peer(script) do
    start_supervised!({Peer, script: script})
  end

  defp connection(owner) do
    start_supervised!(
      {IMAPClient,
       owner: owner,
       timeouts: [
         connect_ms: @connect_ms,
         greeting_ms: 5_000,
         append_ms: @append_ms
       ]}
    )
  end

  defp owner do
    task(fn ->
      receive do
        :finish -> :ok
      end
    end)
  end

  defp cancel(:close, connection, _owner, _caller) do
    close(connection)
  end

  defp cancel(:caller, _connection, _owner, caller) do
    monitor = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}, @cancel_ms
  end

  defp cancel(:owner, connection, owner, _caller) do
    monitor = Process.monitor(connection)
    send(owner, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^connection, :normal}, @cancel_ms
  end

  defp drain(socket, bytes, deadline_ms) do
    remaining_ms = deadline_ms - now_ms()

    if remaining_ms > 0 do
      case :gen_tcp.recv(socket, 0, remaining_ms) do
        {:ok, data} -> drain(socket, bytes + byte_size(data), deadline_ms)
        {:error, reason} -> {reason, bytes}
      end
    else
      {:timeout, bytes}
    end
  end

  defp now_ms do
    System.monotonic_time(:millisecond)
  end

  defp drain_tls(socket, bytes, deadline_ms) do
    remaining_ms = deadline_ms - now_ms()

    if remaining_ms > 0 do
      case :ssl.recv(socket, 0, remaining_ms) do
        {:ok, data} -> drain_tls(socket, bytes + byte_size(data), deadline_ms)
        {:error, reason} -> {reason, bytes}
      end
    else
      {:timeout, bytes}
    end
  end

  defp tls_config(peer) do
    %{
      host: "127.0.0.1",
      port: Peer.port(peer),
      cacertfile: Path.expand("../fixtures/tls/ca.pem", __DIR__)
    }
  end

  defp result_expected?(:caller) do
    false
  end

  defp result_expected?(_action) do
    true
  end

  for action <- [:close, :caller, :owner] do
    @tag timeout: @test_timeout_ms
    test "#{action} cancellation aborts a stalled TLS handshake before its connect deadline" do
      parent = self()
      action = unquote(action)

      peer =
        peer(fn socket ->
          :ok = :inet.setopts(socket, show_econnreset: true)
          {:ok, _client_hello} = :gen_tcp.recv(socket, 0, :infinity)
          send(parent, {:handshake_started, self()})

          receive do
            :observe_close ->
              {reason, _bytes} = drain(socket, 0, now_ms() + @observe_ms)
              send(parent, {:handshake_closed, reason})
          end
        end)

      owner = owner()
      connection = connection(owner)

      caller =
        task(fn ->
          result = connect(connection, tls_config(peer))
          send(parent, {:connect_result, result})
        end)

      assert_receive {:handshake_started, peer_worker}, @handshake_event_ms
      cancel(action, connection, owner, caller)
      send(peer_worker, :observe_close)
      assert_receive {:handshake_closed, reason}, @handshake_event_ms
      assert reason in [:closed, :econnreset]
      refute live?(connection)

      if result_expected?(action) do
        assert_receive {:connect_result, {:error, %Error{code: :closed}}}, @handshake_event_ms
      end
    end

    @tag timeout: @test_timeout_ms
    test "#{action} cancellation aborts a backpressured APPEND without sending the remaining body" do
      parent = self()
      action = unquote(action)
      body = String.duplicate("x", 8 * 1024 * 1024)

      peer =
        peer(fn socket ->
          :ok = :inet.setopts(socket, recbuf: 1_024, show_econnreset: true)
          :ok = :gen_tcp.send(socket, "* OK ready\r\n")
          "A1 APPEND \"Drafts\" (\\Seen \\Draft) {8388608}" = Peer.line(socket)
          :ok = :gen_tcp.send(socket, "+ OK send literal\r\n")
          {:ok, "x"} = :gen_tcp.recv(socket, 1, :infinity)
          send(parent, {:literal_started, self()})

          # Stop reading until the test cancels. A small peer buffer keeps the large
          # APPEND backpressured rather than accepting it in memory.
          receive do
            :observe_close ->
              # Read what the client's kernel already buffered quickly, then its close. This fails
              # harmlessly if the socket already closed.
              _ = :inet.setopts(socket, recbuf: 262_144)
              {reason, bytes} = drain(socket, 1, now_ms() + @observe_ms)
              send(parent, {:append_closed, reason, bytes})
          end
        end)

      owner = owner()
      connection = connection(owner)

      assert :ok =
               connect(connection, %{
                 host: "127.0.0.1",
                 port: Peer.port(peer),
                 use_tls: false
               })

      caller =
        task(fn ->
          send(
            parent,
            {:append_result, append(connection, "Drafts", body, flags: ["\\Seen", "\\Draft"])}
          )
        end)

      assert_receive {:literal_started, peer_worker}, @event_ms
      cancel(action, connection, owner, caller)
      send(peer_worker, :observe_close)
      assert_receive {:append_closed, reason, bytes}, @event_ms
      assert reason in [:closed, :econnreset]
      assert bytes < byte_size(body)
      refute live?(connection)

      if result_expected?(action) do
        assert_receive {:append_result,
                        {:error, %Error{code: :closed, stage: :append, outcome_unknown?: true}}},
                       @event_ms
      end
    end
  end

  @tag timeout: @test_timeout_ms
  test "close aborts the local verified TLS transport during backpressured APPEND" do
    parent = self()
    fixtures = Path.expand("../fixtures/tls", __DIR__)
    body = String.duplicate("x", 8 * 1024 * 1024)

    peer =
      start_supervised!({TLSPeer,
       observer: parent,
       certfile: Path.join(fixtures, "localhost.pem"),
       keyfile: Path.join(fixtures, "localhost-key.pem"),
       script: fn socket ->
         :ok = :ssl.setopts(socket, recbuf: 1_024)
         :ok = :ssl.send(socket, "* OK ready\r\n")
         "A1 APPEND \"Drafts\" (\\Seen \\Draft) {8388608}" = TLSPeer.line(socket)
         :ok = :ssl.send(socket, "+ OK send literal\r\n")
         {:ok, "x"} = :ssl.recv(socket, 1, :infinity)
         send(parent, {:tls_literal_started, self()})

         receive do
           :observe_close ->
             # Read what the client's kernel already buffered quickly, then its close. This fails
             # harmlessly if the socket already closed.
             _ = :ssl.setopts(socket, recbuf: 262_144)
             {reason, bytes} = drain_tls(socket, 1, now_ms() + @observe_ms)
             send(parent, {:tls_append_closed, reason, bytes})
         end
       end})

    connection = connection(self())

    assert :ok =
             connect(connection, %{
               host: "127.0.0.1",
               port: TLSPeer.port(peer),
               cacertfile: Path.join(fixtures, "ca.pem")
             })

    task(fn ->
      send(
        parent,
        {:tls_append_result, append(connection, "Drafts", body, flags: ["\\Seen", "\\Draft"])}
      )
    end)

    assert_receive {:tls_literal_started, worker}, @event_ms
    assert :ok = close(connection)
    send(worker, :observe_close)
    assert_receive {:tls_append_closed, reason, bytes}, @event_ms
    assert reason in [:closed, :econnreset]
    assert bytes < byte_size(body)

    assert_receive {:tls_append_result, {:error, %Error{code: :closed, outcome_unknown?: true}}},
                   @event_ms
  end

  test "commands while greeting is pending return busy and never reach the socket" do
    parent = self()

    peer =
      peer(fn socket ->
        send(parent, {:greeting_pending, self()})

        receive do
          :finish_greeting ->
            :ok = :gen_tcp.send(socket, "* OK ready\r\n")
            send(parent, {:greeting_wire, :gen_tcp.recv(socket, 0, @event_ms)})
        end
      end)

    connection = connection(self())

    task(fn ->
      send(
        parent,
        {:greeted,
         connect(connection, %{
           host: "127.0.0.1",
           port: Peer.port(peer),
           use_tls: false
         })}
      )
    end)

    assert_receive {:greeting_pending, peer_worker}
    assert {:error, %Error{code: :busy}} = login(connection, "person", "password")
    send(peer_worker, :finish_greeting)
    assert_receive {:greeted, :ok}
    assert :ok = close(connection)
    assert_receive {:greeting_wire, {:error, :closed}}
  end
end
