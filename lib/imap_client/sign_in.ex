defmodule IMAPClient.SignIn do
  # Internal to IMAPClient: the one sign-in shared by the session helpers (retry and
  # slow-sign-in reporting on) and `open_signed_in/2` (the caller chooses).
  @moduledoc false

  alias IMAPClient
  alias IMAPClient.Diagnostic
  alias IMAPClient.Error
  alias IMAPClient.Protocol

  # A sign-in this slow is reported even when it worked.
  @slow_signin_ms 5_000

  @doc """
  Connects and signs in on a fresh connection owned by the caller. Returns
  `{:ok, connection}` or `{:error, %Error{}}`; credentials that aren't safe IMAP text
  are refused before any connection opens.

  Options (both default false):
  * `:retry` - retry once on a fresh connection when the greeting or authentication timed out
    (Gmail sometimes takes longer than the authentication deadline, and nothing has touched a
    mailbox yet). A connect-stage timeout (likely unreachable) and refusals are not
    retried.
  * `:log_slow` - report slow (5 s or more), timed-out and retried attempts as
    `:signin_slow` diagnostics, timed before any cleanup. Off, the config's
    `:on_diagnostic` is never looked at.

  A failed attempt's connection is logged out if still usable and always closed.
  """
  def open(config, opts) do
    retry? = Keyword.get(opts, :retry, false)
    log_slow? = Keyword.get(opts, :log_slow, false)

    with {:ok, credentials} <- credentials(config) do
      attempt(config, credentials, 1, if(retry?, do: 2, else: 1), log_slow?)
    end
  end

  defp attempt(config, credentials, attempt, max_attempts, log_slow?) do
    with {:ok, connection} <- IMAPClient.start_link(Map.get(config, :connection_options, [])) do
      started = System.monotonic_time(:millisecond)

      result =
        try do
          transport_config = Map.take(config, [:host, :port, :use_tls, :cacertfile])

          with :ok <- IMAPClient.connect(connection, transport_config) do
            authenticate(connection, credentials)
          end
        catch
          # Cleanup across a failure: the connection must not outlive a sign-in that
          # raised, and the failure itself propagates unchanged.
          kind, reason ->
            close(connection)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      signin_ms = System.monotonic_time(:millisecond) - started
      # The session config's `:slow_signin_ms` overrides the reporting threshold.
      slow? = signin_ms >= Map.get(config, :slow_signin_ms, @slow_signin_ms)

      case result do
        :ok ->
          if log_slow? and (attempt > 1 or slow?),
            do: signin_slow(config, attempt, signin_ms, :ok, false)

          {:ok, connection}

        error ->
          retry? = attempt < max_attempts and retryable?(error)

          if log_slow? and (attempt > 1 or timeout?(error) or slow?),
            do: signin_slow(config, attempt, signin_ms, error, retry?)

          close(connection)

          if retry?,
            do: attempt(config, credentials, attempt + 1, max_attempts, log_slow?),
            else: error
      end
    end
  end

  defp retryable?({:error, %Error{code: :timeout, stage: stage}}) do
    stage in [:greeting, :authentication]
  end

  defp retryable?(_error) do
    false
  end

  defp timeout?(error) do
    match?({:error, %Error{code: :timeout}}, error)
  end

  defp signin_slow(config, attempt, signin_ms, result, retried?) do
    {outcome, stage} =
      case result do
        :ok -> {:ok, nil}
        {:error, %Error{code: :timeout, stage: stage}} -> {:timeout, stage}
        {:error, %Error{code: code}} -> {code, nil}
      end

    Diagnostic.emit(config, %{
      event: :signin_slow,
      attempt: attempt,
      signin_ms: signin_ms,
      outcome: outcome,
      stage: stage,
      retried: retried?
    })
  end

  @doc """
  Ends a signed-in connection: LOGOUT while it is still usable, then close and stop it.
  Safe for a caller that traps exits (no stray EXIT message is left behind) and for a
  connection that already stopped.
  """
  def close(connection) do
    try do
      if IMAPClient.live?(connection), do: IMAPClient.logout(connection)
      IMAPClient.close(connection)
    catch
      # Crossing a process boundary: the connection may already have stopped.
      :exit, _reason -> :ok
    end

    stop(connection)
  end

  defp stop(connection) do
    Process.unlink(connection)

    try do
      GenServer.stop(connection, :normal, :infinity)
    catch
      # Crossing a process boundary: the connection may already have stopped.
      :exit, _reason -> :ok
    after
      receive do
        {:EXIT, ^connection, _reason} -> :ok
      after
        0 -> :ok
      end
    end
  end

  defp authenticate(connection, {:login, username, password}) do
    IMAPClient.login(connection, username, password)
  end

  defp authenticate(connection, {mechanism, username, secret}) do
    IMAPClient.authenticate(connection, mechanism, username, secret)
  end

  defp credentials(config) do
    credentials =
      case config do
        %{auth: :xoauth2, username: username, access_token: token} ->
          {:xoauth2, username, token}

        %{auth: :plain, username: username, password: password} ->
          {:plain, username, password}

        %{username: username, password: password} when not is_map_key(config, :auth) ->
          {:login, username, password}

        %{auth: :login, username: username, password: password} ->
          {:login, username, password}

        _ ->
          nil
      end

    case credentials do
      {_mechanism, username, secret} = credentials ->
        if Protocol.safe_text?(username) and Protocol.safe_text?(secret) do
          {:ok, credentials}
        else
          {:error, Error.new(:invalid_argument, :authentication)}
        end

      nil ->
        {:error, Error.new(:invalid_argument, :authentication)}
    end
  end
end
