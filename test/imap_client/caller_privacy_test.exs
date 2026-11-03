defmodule IMAPClient.CallerPrivacyTest do
  use ExUnit.Case, async: true

  import IMAPClient

  alias IMAPClient.Error
  alias IMAPClient.Peer
  alias IMAPClient.SocketWait

  # A killed GenServer includes its call arguments in the exit it sends callers.
  # LOGIN must turn every such exit into a safe error before it reaches a logger.
  test "killing a connection during LOGIN returns no credential-bearing exit" do
    parent = self()

    peer =
      start_supervised!(
        {Peer,
         script: fn socket ->
           :ok = :gen_tcp.send(socket, "* OK ready\r\n")
           "A1 LOGIN \"person\" \"private-password\"" = Peer.line(socket)
           send(parent, :login_received)
           SocketWait.recv(:gen_tcp, socket)
         end}
      )

    connection = start_supervised!({IMAPClient, owner: self()})

    assert :ok =
             connect(connection, %{
               host: "127.0.0.1",
               port: Peer.port(peer),
               use_tls: false
             })

    caller =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             result = login(connection, "person", "private-password")
             send(parent, {:login_result, result})
           end},
          restart: :temporary
        )
      )

    monitor = Process.monitor(caller)
    assert_receive :login_received
    Process.exit(connection, :kill)
    assert_receive {:login_result, {:error, %Error{code: :closed, stage: :authentication}}}
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
  end

  test "an unavailable connection preserves mutation ambiguity" do
    connection = start_supervised!({IMAPClient, owner: self()})
    GenServer.stop(connection)

    assert {:error, %Error{code: :closed, stage: :append, outcome_unknown?: true}} =
             append(connection, "Drafts", "message", flags: ["\\Seen", "\\Draft"])
  end
end
