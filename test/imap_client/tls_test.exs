defmodule IMAPClient.TLSTest do
  use ExUnit.Case, async: true

  import IMAPClient

  alias IMAPClient.Error
  alias IMAPClient.Peer
  alias IMAPClient.TLSPeer
  alias IMAPClient.SocketWait

  @fixtures Path.expand("../fixtures/tls", __DIR__)

  defp fixture(name) do
    Path.join(@fixtures, name)
  end

  defp connection do
    # These cases assert certificate outcomes, so setup needs scheduling room.
    start_supervised!(
      {IMAPClient,
       owner: self(),
       timeouts: [
         connect_ms: 30_000,
         greeting_ms: 5_000,
         authentication_ms: 5_000,
         command_ms: 5_000
       ]}
    )
  end

  defp peer(script, certificate \\ "localhost") do
    start_supervised!(
      {TLSPeer,
       observer: self(),
       certfile: fixture(certificate <> ".pem"),
       keyfile: fixture(certificate <> "-key.pem"),
       script: script}
    )
  end

  defp config(peer, overrides \\ %{}) do
    Map.merge(
      %{host: "localhost", port: TLSPeer.port(peer), cacertfile: fixture("ca.pem")},
      overrides
    )
  end

  defp greeting(socket) do
    :ok = :ssl.send(socket, "* OK test server\r\n")
    SocketWait.recv(:ssl, socket)
  end

  test "trusted certificate and matching hostname permit LOGIN over TLS" do
    parent = self()

    peer =
      peer(fn socket ->
        :ok = :ssl.send(socket, "* OK test server\r\n")
        command = TLSPeer.line(socket)
        send(parent, {:tls_command, command})

        if command == ~s|A1 LOGIN "person@example.test" "test-app-password"| do
          :ok = :ssl.send(socket, "A1 OK authenticated\r\n")
          SocketWait.recv(:ssl, socket)
        end
      end)

    connection = connection()
    assert :ok = connect(connection, config(peer))
    assert :ok = login(connection, "person@example.test", "test-app-password")
    assert_receive {:imap_tls_peer, ^peer, :connected}
    assert_receive {:tls_command, ~s|A1 LOGIN "person@example.test" "test-app-password"|}
    assert live?(connection)
    assert :ok = close(connection)
  end

  test "an untrusted test CA is rejected with the default system trust store" do
    peer = peer(&greeting/1)
    connection = connection()

    assert {:error, %Error{code: :closed, stage: :connect}} =
             connect(connection, Map.delete(config(peer), :cacertfile))

    refute live?(connection)
    assert_receive {:imap_tls_peer, ^peer, {:handshake_error, _reason}}
  end

  test "a trusted certificate for a different hostname is rejected" do
    peer = peer(&greeting/1, "wrong-host")
    connection = connection()

    assert {:error, %Error{code: :closed, stage: :connect}} =
             connect(connection, config(peer))

    refute live?(connection)
    assert_receive {:imap_tls_peer, ^peer, {:handshake_error, _reason}}
  end

  test "a trusted IP SAN verifies an IP literal without DNS SNI" do
    parent = self()

    peer =
      peer(fn socket ->
        {:ok, information} = :ssl.connection_information(socket, [:sni_hostname])
        send(parent, {:server_sni, Keyword.get(information, :sni_hostname)})
        greeting(socket)
      end)

    connection = connection()
    assert :ok = connect(connection, config(peer, %{host: "127.0.0.1"}))
    assert live?(connection)
    assert_receive {:imap_tls_peer, ^peer, :connected}
    assert_receive {:server_sni, nil}
    assert :ok = close(connection)
  end

  test "a DNS-only certificate does not verify an IP literal" do
    peer = peer(&greeting/1, "dns-only")
    connection = connection()

    assert {:error, %Error{code: :closed, stage: :connect}} =
             connect(connection, config(peer, %{host: "127.0.0.1"}))

    refute live?(connection)
    assert_receive {:imap_tls_peer, ^peer, {:handshake_error, _reason}}
  end

  test "a nonexistent trust override fails closed" do
    peer = peer(&greeting/1)
    connection = connection()
    missing = fixture("does-not-exist.pem")
    refute File.exists?(missing)

    assert {:error, %Error{code: :closed, stage: :connect}} =
             connect(connection, config(peer, %{cacertfile: missing}))

    refute live?(connection)
  end

  test "verified TLS PREAUTH skips LOGIN and preserves the next command tag" do
    parent = self()

    peer =
      peer(fn socket ->
        :ok = :ssl.send(socket, "* PREAUTH authenticated test session\r\n")
        command = TLSPeer.line(socket)
        send(parent, {:tls_command, command})

        if command == "A1 CAPABILITY" do
          :ok = :ssl.send(socket, "* CAPABILITY IMAP4rev1 IDLE\r\nA1 OK capabilities\r\n")
          SocketWait.recv(:ssl, socket)
        end
      end)

    connection = connection()
    assert :ok = connect(connection, config(peer))
    assert :ok = login(connection, "person@example.test", "test-app-password")
    assert {:ok, capabilities} = capabilities(connection)
    assert capabilities == MapSet.new(["IMAP4REV1", "IDLE"])
    assert_receive {:tls_command, "A1 CAPABILITY"}
    assert :ok = close(connection)
  end

  test "plaintext PREAUTH is refused before any credentials or commands are sent" do
    parent = self()

    peer =
      start_supervised!(
        {Peer,
         script: fn socket ->
           :ok = :gen_tcp.send(socket, "* PREAUTH unauthenticated transport\r\n")
           send(parent, {:plaintext_after_preauth, SocketWait.recv(:gen_tcp, socket)})
         end}
      )

    connection = connection()

    assert {:error, %Error{code: :protocol}} =
             connect(connection, %{
               host: "127.0.0.1",
               port: Peer.port(peer),
               use_tls: false
             })

    assert {:error, %Error{code: :closed}} = login(connection, "person", "password")
    refute live?(connection)
    assert_receive {:plaintext_after_preauth, {:error, :closed}}
  end
end
