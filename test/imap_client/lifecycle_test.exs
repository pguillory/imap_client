defmodule IMAPClient.LifecycleTest do
  use ExUnit.Case, async: true

  import IMAPClient

  alias IMAPClient.Error
  alias IMAPClient.Peer
  alias IMAPClient.SocketWait

  defp peer(script) do
    start_supervised!(Supervisor.child_spec({Peer, script: script}, id: make_ref()))
  end

  defp config(peer) do
    %{host: "127.0.0.1", port: Peer.port(peer), use_tls: false}
  end

  defp connection(opts \\ []) do
    opts =
      Keyword.merge(
        [owner: self(), timeouts: [command_ms: 5_000, greeting_ms: 5_000]],
        opts
      )

    start_supervised!(Supervisor.child_spec({IMAPClient, opts}, id: make_ref()))
  end

  defp task(function) do
    start_supervised!(
      Supervisor.child_spec({Task, function}, id: make_ref(), restart: :temporary)
    )
  end

  defp drain_to_close(socket, deadline_ms) do
    remaining_ms = deadline_ms - System.monotonic_time(:millisecond)

    if remaining_ms > 0 do
      case :gen_tcp.recv(socket, 0, remaining_ms) do
        {:ok, _tls_control_bytes} -> drain_to_close(socket, deadline_ms)
        result -> result
      end
    else
      {:error, :timeout}
    end
  end

  test "invalid timeout options raise before starting a linked process" do
    assert_raise ArgumentError, "invalid IMAP connection options", fn ->
      start_link(timeouts: [command_ms: -1])
    end
  end

  test "the connect deadline aborts an in-flight TLS handshake" do
    parent = self()

    peer =
      peer(fn socket ->
        send(parent, {:client_hello, :gen_tcp.recv(socket, 0, 20_000)})
        # OTP may send cancellation alerts before the transport reaches EOF.
        deadline_ms = System.monotonic_time(:millisecond) + SocketWait.timeout_ms()
        send(parent, {:tls_timeout_socket, drain_to_close(socket, deadline_ms)})
      end)

    connection = connection(timeouts: [connect_ms: 2_000])

    task(fn ->
      result =
        connect(connection, %{
          host: "127.0.0.1",
          port: Peer.port(peer),
          use_tls: true,
          cacertfile: Path.expand("../fixtures/tls/ca.pem", __DIR__)
        })

      send(parent, {:connect_result, result})
    end)

    # The peer never answers the ClientHello, so the connect deadline expires
    # during the handshake.
    assert_receive {:client_hello, {:ok, client_hello}}, 20_000
    assert byte_size(client_hello) > 0

    assert_receive {:connect_result,
                    {:error, %Error{code: :timeout, stage: :connect, timeout_ms: 2_000}}},
                   10_000

    assert_receive {:tls_timeout_socket, {:error, :closed}}
    refute live?(connection)
  end

  for reason <- [:normal, :shutdown] do
    test "owner #{reason} exit closes the socket and stops the connection" do
      parent = self()
      reason = unquote(reason)

      owner =
        task(fn ->
          receive do
            :finish -> exit(reason)
          end
        end)

      peer =
        peer(fn socket ->
          :ok = :gen_tcp.send(socket, "* OK ready\r\n")
          send(parent, {:owner_socket, SocketWait.recv(:gen_tcp, socket)})
        end)

      connection = connection(owner: owner)
      assert :ok = connect(connection, config(peer))
      connection_monitor = Process.monitor(connection)
      owner_monitor = Process.monitor(owner)
      send(owner, :finish)
      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, ^reason}
      assert_receive {:DOWN, ^connection_monitor, :process, ^connection, :normal}
      assert_receive {:owner_socket, {:error, :closed}}
    end
  end

  test "a separate caller dying during an exchange poisons the connection and closes its socket" do
    parent = self()

    peer =
      peer(fn socket ->
        :ok = :gen_tcp.send(socket, "* OK ready\r\n")
        "A1 UID SEARCH ALL" = Peer.line(socket)
        send(parent, :search_received)
        send(parent, {:caller_socket, SocketWait.recv(:gen_tcp, socket)})
      end)

    connection = connection()
    assert :ok = connect(connection, config(peer))
    caller = task(fn -> search_uids(connection, "ALL") end)
    assert_receive :search_received
    monitor = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}
    assert_receive {:caller_socket, {:error, :closed}}
    refute live?(connection)
    assert {:error, %Error{code: :closed}} = capabilities(connection)
  end

  test "close during a pending mutation resolves the caller and late completion cannot resurrect it" do
    parent = self()

    peer =
      peer(fn socket ->
        :ok = :gen_tcp.send(socket, "* OK ready\r\n")
        "A1 UID STORE 1 +FLAGS (\\Seen)" = Peer.line(socket)
        send(parent, {:store_received, self()})
        send(parent, {:closed_before_late, SocketWait.recv(:gen_tcp, socket)})

        receive do
          :late_completion ->
            result = :gen_tcp.send(socket, "A1 OK stored\r\n")
            send(parent, {:late_completion_attempted, result})
        end
      end)

    connection = connection()
    assert :ok = connect(connection, config(peer))

    task(fn ->
      send(parent, {:store_result, store(connection, [1], "\\Seen", "+")})
    end)

    assert_receive {:store_received, worker}
    assert :ok = close(connection)

    assert_receive {:store_result,
                    {:error, %Error{code: :closed, stage: :store, outcome_unknown?: true}}}

    assert_receive {:closed_before_late, {:error, :closed}}
    send(worker, :late_completion)
    assert_receive {:late_completion_attempted, _result}
    refute live?(connection)
    assert {:error, %Error{code: :closed}} = capabilities(connection)
    assert :ok = close(connection)
  end

  test "a socket without a greeting expires the greeting deadline rather than the connect deadline" do
    parent = self()

    peer =
      peer(fn socket ->
        send(parent, {:greeting_timeout_socket, SocketWait.recv(:gen_tcp, socket)})
      end)

    connection =
      connection(timeouts: [connect_ms: 5_000, greeting_ms: 500])

    assert {:error, %Error{code: :timeout, stage: :greeting, timeout_ms: 500}} =
             connect(connection, config(peer))

    assert_receive {:greeting_timeout_socket, {:error, :closed}}
    refute live?(connection)
  end

  test "a malformed greeting fails immediately and closes the socket" do
    parent = self()

    peer =
      peer(fn socket ->
        :ok = :gen_tcp.send(socket, "A1 OK not an untagged greeting\r\n")
        send(parent, {:bad_greeting_socket, SocketWait.recv(:gen_tcp, socket)})
      end)

    connection = connection()

    assert {:error, %Error{code: :protocol, stage: :greeting}} =
             connect(connection, config(peer))

    assert_receive {:bad_greeting_socket, {:error, :closed}}
    refute live?(connection)
  end

  test "a second connect is rejected while the original socket remains usable and owned" do
    parent = self()

    peer =
      peer(fn socket ->
        :ok = :gen_tcp.send(socket, "* OK original connection\r\n")
        "A1 CAPABILITY" = Peer.line(socket)
        :ok = :gen_tcp.send(socket, "* CAPABILITY IMAP4rev1\r\nA1 OK done\r\n")
        send(parent, {:original_socket, SocketWait.recv(:gen_tcp, socket)})
      end)

    connection = connection()
    assert :ok = connect(connection, config(peer))

    assert {:error, %Error{code: :closed, stage: :connect}} =
             connect(connection, config(peer))

    assert {:ok, capabilities} = capabilities(connection)
    assert capabilities == MapSet.new(["IMAP4REV1"])
    assert :ok = close(connection)
    assert_receive {:original_socket, {:error, :closed}}
    refute live?(connection)
  end
end
