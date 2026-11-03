defmodule IMAPClient.SocketWait do
  @moduledoc """
  The bound for a test-side wait on another process's socket work: a peer waiting
  for the client's connection, next command or close, a test reading a server's
  reply, or a held response waiting for the test's release. Such a wait often begins
  before the test's own assert window, and the other side may be slow on a loaded
  Mac, so it needs a bound well past that window, or it times out first and the test
  fails for the wrong reason. It costs nothing when the test passes: a recv returns
  as soon as bytes or a close arrive.
  """

  @timeout_ms 30_000

  @doc "The bound, in milliseconds."
  def timeout_ms do
    @timeout_ms
  end

  @doc """
  Reads `length` bytes (0 for whatever arrives) from a `:gen_tcp` or `:ssl` socket,
  waiting up to `timeout_ms/0` for the other end's bytes or close. Returns what
  `:gen_tcp.recv/3` or `:ssl.recv/3` returns.
  """
  def recv(transport, socket, length \\ 0) when transport in [:gen_tcp, :ssl] do
    transport.recv(socket, length, @timeout_ms)
  end
end
