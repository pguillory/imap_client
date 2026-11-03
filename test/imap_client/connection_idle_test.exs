defmodule IMAPClient.ConnectionIdleTest do
  use ExUnit.Case, async: true

  import IMAPClient

  alias IMAPClient.Error
  alias IMAPClient.Peer
  alias IMAPClient.SocketWait

  defp connected(script, timeout_ms \\ 1_000) do
    peer = start_supervised!({Peer, script: script})

    connection =
      start_supervised!(
        {IMAPClient, owner: self(), timeouts: [command_ms: timeout_ms, greeting_ms: 1_000]}
      )

    :ok =
      connect(connection, %{host: "127.0.0.1", port: Peer.port(peer), use_tls: false})

    connection
  end

  test "IDLE delivers updates before and after continuation and DONE completion admits the next command" do
    parent = self()

    connection =
      connected(fn socket ->
        :ok = :gen_tcp.send(socket, "* OK ready\r\n")
        "A1 IDLE" = Peer.line(socket)
        :ok = :gen_tcp.send(socket, "* 1 EXISTS\r\n+ OK idling\r\n* 2 EXISTS\r\n")
        command = Peer.line(socket)
        send(parent, {:idle_wire, command})

        if command == "DONE" do
          :ok = :gen_tcp.send(socket, "* 3 EXISTS\r\nA1 OK idle complete\r\n")
          "A2 CAPABILITY" = Peer.line(socket)
          :ok = :gen_tcp.send(socket, "* CAPABILITY IMAP4rev1 IDLE\r\nA2 OK done\r\n")
          SocketWait.recv(:gen_tcp, socket)
        end
      end)

    assert {:ok, ref} = start_idle(connection)
    assert_receive {:imap_idle, ^ref, {:update, "* 1 EXISTS"}}
    assert_receive {:imap_idle, ^ref, {:update, "* 2 EXISTS"}}
    assert :ok = end_idle(connection)
    assert_receive {:idle_wire, "DONE"}
    assert_receive {:imap_idle, ^ref, {:update, "* 3 EXISTS"}}
    assert_receive {:imap_idle, ^ref, :ended}
    assert {:ok, capabilities} = capabilities(connection)
    assert capabilities == MapSet.new(["IMAP4REV1", "IDLE"])
    assert :ok = close(connection)
  end

  test "commands during IDLE are rejected without sending bytes before DONE" do
    parent = self()

    connection =
      connected(fn socket ->
        :ok = :gen_tcp.send(socket, "* OK ready\r\n")
        "A1 IDLE" = Peer.line(socket)
        :ok = :gen_tcp.send(socket, "+ idling\r\n")
        first = Peer.line(socket)
        send(parent, {:first_idle_wire, first})
        :ok = :gen_tcp.send(socket, "A1 OK complete\r\n")
        SocketWait.recv(:gen_tcp, socket)
      end)

    assert {:ok, _ref} = start_idle(connection)
    assert {:error, %Error{code: :busy}} = store(connection, [1], "\\Seen", "+")
    assert {:error, %Error{code: :busy}} = capabilities(connection)
    assert {:error, %Error{code: :busy}} = start_idle(connection)
    assert :ok = end_idle(connection)
    assert_receive {:first_idle_wire, "DONE"}
    assert :ok = close(connection)
  end

  test "BYE during IDLE emits a closed error and poisons the connection" do
    connection =
      connected(fn socket ->
        :ok = :gen_tcp.send(socket, "* OK ready\r\n")
        "A1 IDLE" = Peer.line(socket)
        :ok = :gen_tcp.send(socket, "+ idling\r\n* BYE server closing\r\n")
        SocketWait.recv(:gen_tcp, socket)
      end)

    assert {:ok, ref} = start_idle(connection)
    assert_receive {:imap_idle, ^ref, {:error, %Error{code: :closed, stage: :idle}}}
    refute live?(connection)
  end

  test "missing IDLE continuation expires the entry deadline and closes the socket" do
    parent = self()

    connection =
      connected(
        fn socket ->
          :ok = :gen_tcp.send(socket, "* OK ready\r\n")
          "A1 IDLE" = Peer.line(socket)
          send(parent, {:entry_timeout_socket, SocketWait.recv(:gen_tcp, socket)})
        end,
        500
      )

    assert {:error, %Error{code: :timeout, stage: :idle, timeout_ms: 500}} =
             start_idle(connection)

    assert_receive {:entry_timeout_socket, {:error, :closed}}
    refute live?(connection)
  end

  test "missing DONE completion expires the command deadline and notifies the subscriber" do
    parent = self()

    connection =
      connected(
        fn socket ->
          :ok = :gen_tcp.send(socket, "* OK ready\r\n")
          "A1 IDLE" = Peer.line(socket)
          :ok = :gen_tcp.send(socket, "+ idling\r\n")
          "DONE" = Peer.line(socket)
          send(parent, {:done_timeout_socket, SocketWait.recv(:gen_tcp, socket)})
        end,
        500
      )

    assert {:ok, ref} = start_idle(connection)

    assert {:error, %Error{code: :timeout, stage: :idle, timeout_ms: 500}} =
             end_idle(connection)

    assert_receive {:imap_idle, ^ref, {:error, %Error{code: :timeout, stage: :idle}}}
    assert_receive {:done_timeout_socket, {:error, :closed}}
    refute live?(connection)
  end

  for {description, response} <- [
        {"a foreign tag", "A99 OK foreign completion\r\n"},
        {"an extra continuation", "+ unexpected continuation\r\n"}
      ] do
    test "#{description} during IDLE is a fatal protocol error" do
      response = unquote(response)

      connection =
        connected(fn socket ->
          :ok = :gen_tcp.send(socket, "* OK ready\r\n")
          "A1 IDLE" = Peer.line(socket)
          :ok = :gen_tcp.send(socket, "+ idling\r\n" <> response)
          SocketWait.recv(:gen_tcp, socket)
        end)

      assert {:ok, ref} = start_idle(connection)
      assert_receive {:imap_idle, ^ref, {:error, %Error{code: :protocol, stage: :idle}}}
      refute live?(connection)
    end
  end

  test "subscriber normal exit after IDLE entry closes the authenticated socket" do
    parent = self()

    subscriber =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             receive do
               :finish -> :ok
             end
           end},
          restart: :temporary
        )
      )

    connection =
      connected(fn socket ->
        :ok = :gen_tcp.send(socket, "* OK ready\r\n")
        "A1 IDLE" = Peer.line(socket)
        :ok = :gen_tcp.send(socket, "+ idling\r\n")
        send(parent, {:subscriber_socket, SocketWait.recv(:gen_tcp, socket)})
      end)

    assert {:ok, _ref} = start_idle(connection, subscriber)
    monitor = Process.monitor(subscriber)
    send(subscriber, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^subscriber, :normal}
    assert_receive {:subscriber_socket, {:error, :closed}}
    refute live?(connection)
  end

  defp subscriber do
    start_supervised!(
      Supervisor.child_spec(
        {Task,
         fn ->
           receive do
             :finish -> :ok
           end
         end},
        id: make_ref(),
        restart: :temporary
      )
    )
  end

  test "a distinct subscriber dying before the continuation cancels IDLE entry promptly" do
    parent = self()
    subscriber = subscriber()

    connection =
      connected(
        fn socket ->
          :ok = :gen_tcp.send(socket, "* OK ready\r\n")
          "A1 IDLE" = Peer.line(socket)
          send(parent, :idle_entry_received)
          send(parent, {:entry_subscriber_socket, SocketWait.recv(:gen_tcp, socket)})
        end,
        2_000
      )

    start_supervised!(
      Supervisor.child_spec(
        {Task,
         fn ->
           send(parent, {:idle_entry_result, start_idle(connection, subscriber)})
         end},
        id: make_ref(),
        restart: :temporary
      )
    )

    assert_receive :idle_entry_received
    monitor = Process.monitor(subscriber)
    send(subscriber, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^subscriber, :normal}
    assert_receive {:idle_entry_result, {:error, %Error{code: :closed, stage: :idle}}}
    assert_receive {:entry_subscriber_socket, {:error, :closed}}
    refute live?(connection)
  end

  test "an IDLE refusal releases the admission monitor so later subscriber death is harmless" do
    subscriber = subscriber()

    connection =
      connected(fn socket ->
        :ok = :gen_tcp.send(socket, "* OK ready\r\n")
        "A1 IDLE" = Peer.line(socket)
        :ok = :gen_tcp.send(socket, "A1 NO unavailable\r\n")
        "A2 CAPABILITY" = Peer.line(socket)
        :ok = :gen_tcp.send(socket, "* CAPABILITY IMAP4rev1 IDLE\r\nA2 OK done\r\n")
        SocketWait.recv(:gen_tcp, socket)
      end)

    assert {:error, %Error{code: :no, stage: :idle}} =
             start_idle(connection, subscriber)

    monitor = Process.monitor(subscriber)
    send(subscriber, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^subscriber, :normal}
    assert {:ok, capabilities} = capabilities(connection)
    assert capabilities == MapSet.new(["IMAP4REV1", "IDLE"])
    assert live?(connection)
    assert :ok = close(connection)
  end

  test "the actual start_link parent's exit notifies a separate active IDLE subscriber" do
    parent = self()

    subscriber =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             receive do
               {:imap_idle, ref, event} -> send(parent, {:parent_exit_idle, ref, event})
             end

             receive do
               :finish -> :ok
             end
           end},
          id: make_ref(),
          restart: :temporary
        )
      )

    owner =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             {:ok, connection} = start_link()
             send(parent, {:parent_owned_connection, connection})

             receive do
               :finish -> :ok
             end
           end},
          id: make_ref(),
          restart: :temporary
        )
      )

    peer =
      start_supervised!(
        {Peer,
         script: fn socket ->
           :ok = :gen_tcp.send(socket, "* OK ready\r\n")
           "A1 IDLE" = Peer.line(socket)
           :ok = :gen_tcp.send(socket, "+ OK idling\r\n")
           send(parent, {:parent_exit_socket, SocketWait.recv(:gen_tcp, socket)})
         end}
      )

    assert_receive {:parent_owned_connection, connection}

    assert :ok =
             connect(connection, %{
               host: "127.0.0.1",
               port: Peer.port(peer),
               use_tls: false
             })

    assert {:ok, ref} = start_idle(connection, subscriber)
    monitor = Process.monitor(connection)
    send(owner, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^connection, :normal}
    assert_receive {:parent_exit_idle, ^ref, {:error, %Error{code: :closed, stage: :idle}}}
    assert_receive {:parent_exit_socket, {:error, :closed}}
    send(subscriber, :finish)
  end
end
