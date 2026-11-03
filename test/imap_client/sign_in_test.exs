defmodule IMAPClient.SignInTest do
  use ExUnit.Case, async: true

  import IMAPClient

  alias IMAPClient.Error
  alias IMAPClient.FakeServer

  # The session helpers' retrying, reporting use is covered in session_test.exs; this
  # covers the long-lived session's use: no retry, no reporting, caller-owned cleanup.

  defp fake do
    server = start_supervised!({FakeServer, mailboxes: %{"INBOX" => %{messages: []}}})
    {server, FakeServer.endpoint(server)}
  end

  defp commands(server, command) do
    Enum.count(FakeServer.commands(server), &(&1.command == command))
  end

  test "with retry and reporting off a LOGIN timeout is one attempt and needs no callback" do
    {server, config} = fake()
    # Transport.watch_config's shape: no :on_diagnostic, :connection_options or trust.
    refute Map.has_key?(config, :on_diagnostic)
    config = Map.put(config, :connection_options, timeouts: [authentication_ms: 300])
    :ok = FakeServer.script_next(server, :login, :stall)

    assert {:error, %Error{code: :timeout, stage: :authentication}} =
             open_signed_in(config, retry: false, log_slow: false)

    assert commands(server, :login) == 1
  end

  test "with reporting off a slow sign-in that worked reports nothing" do
    {_server, config} = fake()
    parent = self()

    config =
      config
      |> Map.put(:slow_signin_ms, 0)
      |> Map.put(:on_diagnostic, &send(parent, {:diagnostic, &1}))

    assert {:ok, connection} = open_signed_in(config, retry: false, log_slow: false)
    :ok = close_signed_in(connection)
    refute_received {:diagnostic, _}
  end

  test "unsafe credentials are refused before any connection opens" do
    {server, config} = fake()

    assert {:error, %Error{code: :invalid_argument, stage: :authentication}} =
             open_signed_in(%{config | password: "bad\r\npassword"},
               retry: false,
               log_slow: false
             )

    assert FakeServer.commands(server) == []
  end

  test "the caller owns the connection until close_signed_in logs out and stops it" do
    {server, config} = fake()
    Process.flag(:trap_exit, true)
    assert {:ok, connection} = open_signed_in(config, retry: false, log_slow: false)
    assert live?(connection)
    assert {:ok, capabilities} = capabilities(connection)
    assert MapSet.member?(capabilities, "IDLE")

    :ok = close_signed_in(connection)
    refute Process.alive?(connection)
    assert commands(server, :logout) == 1
    refute_received {:EXIT, ^connection, _}
    # A second close of a stopped connection is harmless.
    :ok = close_signed_in(connection)
  end
end
