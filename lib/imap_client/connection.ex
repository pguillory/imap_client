defmodule IMAPClient.Connection do
  # Internal to IMAPClient.
  @moduledoc false

  use GenServer, restart: :temporary

  alias IMAPClient.Charset
  alias IMAPClient.Error
  alias IMAPClient.Framer
  alias IMAPClient.IOWorker
  alias IMAPClient.Protocol
  alias IMAPClient.Transport

  # Whole-stage budgets, not per-packet timeouts.
  @timeouts %{
    connect_ms: 10_000,
    greeting_ms: 10_000,
    authentication_ms: 20_000,
    command_ms: 30_000,
    body_fetch_ms: 60_000,
    append_ms: 120_000,
    logout_ms: 5_000
  }

  @status_items %{
    messages: "MESSAGES",
    recent: "RECENT",
    uid_next: "UIDNEXT",
    uid_validity: "UIDVALIDITY",
    unseen: "UNSEEN"
  }

  def start_link(opts) do
    owner = Keyword.get(opts, :owner, self())
    timeouts = Map.merge(@timeouts, Map.new(Keyword.get(opts, :timeouts, [])))
    body_limit = Keyword.get(opts, :max_body_literal_bytes, 64 * 1024 * 1024)

    if !is_pid(owner) or
         !Enum.all?(timeouts, fn {key, value} ->
           Map.has_key?(@timeouts, key) and is_integer(value) and value > 0
         end) or
         !is_integer(body_limit) or body_limit < 1 do
      raise ArgumentError, "invalid IMAP connection options"
    end

    GenServer.start_link(__MODULE__, {owner, timeouts, body_limit})
  end

  def request(connection, operation) do
    GenServer.call(connection, operation, :infinity)
  end

  # Server

  @impl true
  def init({owner, timeouts, body_limit}) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       owner: owner,
       owner_monitor: Process.monitor(owner),
       socket: nil,
       raw_socket: nil,
       io_job: nil,
       outbound: nil,
       needs_activation?: false,
       peer_closed?: false,
       deferred: :queue.new(),
       deferred_size_bytes: 0,
       status: :new,
       preauthenticated?: false,
       pending: nil,
       idle: nil,
       counter: 0,
       timeouts: timeouts,
       body_limit_bytes: body_limit,
       framer: Framer.new()
     }}
  end

  @impl true
  def handle_call(:live?, _from, state) do
    {:reply, state.status == :live, state}
  end

  def handle_call(:close, _from, state) do
    state = poison(state, Error.new(:closed, pending_stage(state)))
    {:reply, :ok, %{state | status: :closed}}
  end

  def handle_call({:connect, config}, from, %{status: :new} = state) do
    if valid_config?(config) do
      state =
        pending(
          %{state | status: :connecting},
          from,
          :connect,
          :connect,
          state.timeouts.connect_ms
        )

      job = IOWorker.start(self(), {:connect, config, state.pending.deadline_ms})
      {:noreply, %{state | io_job: Map.put(job, :kind, :connect)}}
    else
      {:reply, {:error, Error.new(:invalid_argument, :connect)}, state}
    end
  end

  def handle_call({:connect, _}, _from, state) do
    {:reply, {:error, Error.new(:closed, :connect)}, state}
  end

  def handle_call(_operation, _from, %{pending: pending} = state) when pending != nil do
    {:reply, {:error, Error.new(:busy)}, state}
  end

  def handle_call(_operation, _from, %{status: status} = state) when status != :live do
    {:reply, {:error, Error.new(:closed)}, state}
  end

  def handle_call(:end_idle, from, %{idle: idle} = state) when idle != nil do
    state = pending(state, from, :idle_end, :idle, state.timeouts.command_ms)
    state = put_in(state.pending.tag, idle.tag)
    {:noreply, write(state, "DONE\r\n")}
  end

  def handle_call(:end_idle, _from, state) do
    {:reply, {:error, Error.new(:closed, :idle)}, state}
  end

  def handle_call(_operation, _from, %{idle: idle} = state) when idle != nil do
    {:reply, {:error, Error.new(:busy, :idle)}, state}
  end

  def handle_call({:login, _username, _password}, _from, %{preauthenticated?: true} = state) do
    {:reply, :ok, state}
  end

  def handle_call({:authenticate, _, _, _}, _from, %{preauthenticated?: true} = state) do
    {:reply, :ok, state}
  end

  def handle_call(operation, from, state) do
    case prepare(operation, state) do
      {:done, result} ->
        {:reply, result, state}

      {:error, stage} ->
        {:reply, {:error, Error.new(:invalid_argument, stage)}, state}

      {:command, stage, timeout_key, segments} ->
        # The pending operation never keeps credentials. The encoded SASL response
        # waits in the pending segments until the "+", redacted by format_status/1.
        operation =
          case operation do
            {:login, _, _} -> :login
            {:authenticate, mechanism, _, _} -> {:authenticate, mechanism}
            operation -> operation
          end

        state = pending(state, from, operation, stage, Map.fetch!(state.timeouts, timeout_key))
        {:noreply, start_command(state, segments)}
    end
  end

  defp valid_config?(%{host: host} = config) do
    is_binary(host) and host != "" and Protocol.safe_text?(host) and
      Map.get(config, :use_tls, true) in [true, false] and
      is_integer(Map.get(config, :port, 993)) and Map.get(config, :port, 993) in 1..65_535 and
      (is_nil(Map.get(config, :cacertfile)) or is_binary(config.cacertfile))
  end

  defp valid_config?(_) do
    false
  end

  defp pending(state, from, operation, stage, timeout_ms) do
    ref = make_ref()
    timer = Process.send_after(self(), {:deadline, ref}, timeout_ms)
    caller_monitor = Process.monitor(elem(from, 0))

    subscriber_monitor =
      case operation do
        {:idle_start, subscriber} -> Process.monitor(subscriber)
        _ -> nil
      end

    pending = %{
      from: from,
      operation: operation,
      stage: stage,
      timeout_ms: timeout_ms,
      deadline_ms: now_ms() + timeout_ms,
      ref: ref,
      timer: timer,
      caller_monitor: caller_monitor,
      subscriber_monitor: subscriber_monitor,
      tag: nil,
      lines: [],
      phase: :completion,
      segments: [],
      response_size_bytes: 0
    }

    %{state | pending: pending}
  end

  defp start_command(state, segments) do
    counter = state.counter + 1
    tag = "A#{counter}"
    limit = if state.pending.stage == :body, do: state.body_limit_bytes, else: 1024 * 1024
    reject_literals? = state.pending.operation in [:list_special_use, :list_special_fallback]

    logical_limit =
      if state.pending.stage == :body,
        do: state.body_limit_bytes + 1024 * 1024,
        else: 65 * 1024 * 1024

    state = %{
      state
      | counter: counter,
        framer: %{
          state.framer
          | literal_limit_bytes: limit,
            logical_limit_bytes: logical_limit,
            reject_list_literals?: reject_literals?
        }
    }

    state = %{state | pending: %{state.pending | tag: tag, segments: [tag <> " " | segments]}}
    send_segments(state)
  end

  defp send_segments(state) do
    {text, rest} = Enum.split_while(state.pending.segments, &is_binary/1)

    case rest do
      [] ->
        state = %{state | pending: %{state.pending | segments: [], phase: :completion}}
        write(state, [text, "\r\n"])

      [{:sasl, response}] ->
        state = %{
          state
          | pending: %{state.pending | segments: [{:sasl, response}], phase: :sasl_challenge}
        }

        write(state, [text, "\r\n"])

      [{:literal, bytes} | tail] ->
        state = %{
          state
          | pending: %{state.pending | segments: [{:bytes, bytes} | tail], phase: :continuation}
        }

        write(state, [text, "{#{byte_size(bytes)}}\r\n"])
    end
  end

  # The base64 initial response goes out once and then leaves the pending state.
  defp sasl_response(%{pending: %{segments: [{:sasl, response}]}} = state) do
    write(%{state | pending: %{state.pending | segments: [], phase: :sasl_result}}, [
      response,
      "\r\n"
    ])
  end

  defp continue_literal(%{pending: %{segments: [{:bytes, bytes} | tail]}} = state) do
    write(%{state | pending: %{state.pending | segments: tail}}, bytes, :segments)
  end

  defp write(state, bytes, after_write \\ :done)

  defp write(%{peer_closed?: true} = state, _bytes, _after_write) do
    poison(state, Error.new(:closed, pending_stage(state)))
  end

  defp write(state, bytes, after_write) do
    resume(%{state | outbound: %{bytes: IO.iodata_to_binary(bytes), after_write: after_write}})
  end

  defp resume(%{io_job: job} = state) when job != nil do
    state
  end

  defp resume(%{socket: nil} = state) do
    state
  end

  defp resume(%{outbound: %{bytes: "", after_write: after_write}} = state) do
    state = %{state | outbound: nil}
    if after_write == :segments, do: send_segments(state), else: resume(state)
  end

  defp resume(%{outbound: %{bytes: bytes} = outbound} = state) when bytes != "" do
    if state.pending.deadline_ms <= now_ms() do
      poison(state, timeout_error(state))
    else
      size = min(byte_size(bytes), 32 * 1024)
      <<chunk::binary-size(size), rest::binary>> = bytes
      job = IOWorker.start(self(), {:send, state.socket, chunk, state.pending.deadline_ms})
      %{state | io_job: Map.put(job, :kind, :send), outbound: %{outbound | bytes: rest}}
    end
  end

  defp resume(state) do
    case :queue.out(state.deferred) do
      {{:value, {:line, line}}, rest} ->
        state = %{
          state
          | deferred: rest,
            deferred_size_bytes: state.deferred_size_bytes - byte_size(line)
        }

        resume(response(line, state))

      {{:value, {:closed, error}}, rest} ->
        poison(%{state | deferred: rest}, error)

      {:empty, _queue} ->
        if state.needs_activation? do
          job = IOWorker.start(self(), {:activate, state.socket})
          %{state | io_job: Map.put(job, :kind, :activate), needs_activation?: false}
        else
          state
        end
    end
  end

  @impl true
  def handle_info(
        {:imap_io, ref, {:raw_ready, raw}},
        %{io_job: %{ref: ref, kind: :connect}} = state
      ) do
    send(state.io_job.pid, {:upgrade, ref})
    {:noreply, %{state | raw_socket: raw}}
  end

  def handle_info(
        {:imap_io, ref, {:socket_ready, socket}},
        %{io_job: %{ref: ref, kind: :connect}} = state
      ) do
    send(state.io_job.pid, {:adopt, ref})
    {:noreply, %{state | socket: socket}}
  end

  def handle_info(
        {:imap_io, ref, {:connected, _socket}},
        %{io_job: %{ref: ref, kind: :connect}} = state
      ) do
    if now_ms() >= state.pending.deadline_ms do
      {:noreply, poison(state, timeout_error(state))}
    else
      send(state.io_job.pid, {:ack, ref})
      state = clear_job(state)
      previous = state.pending
      Process.cancel_timer(previous.timer)
      Process.demonitor(previous.caller_monitor, [:flush])

      state =
        pending(
          %{state | pending: nil},
          previous.from,
          :greeting,
          :greeting,
          state.timeouts.greeting_ms
        )

      {:noreply, resume(%{state | needs_activation?: true})}
    end
  end

  def handle_info({:imap_io, ref, :ok}, %{io_job: %{ref: ref}} = state) do
    {:noreply, resume(clear_job(state))}
  end

  def handle_info({:imap_io, ref, {:error, reason}}, %{io_job: %{ref: ref}} = state) do
    state = clear_job(state)

    error =
      if reason == :timeout and state.pending,
        do: timeout_error(state),
        else: Error.new(:closed, pending_stage(state))

    {:noreply, poison(state, error)}
  end

  def handle_info({:imap_io, _ref, {:raw_ready, raw}}, state) do
    Transport.abort(raw)
    {:noreply, state}
  end

  def handle_info({:imap_io, _ref, _result}, state) do
    {:noreply, state}
  end

  def handle_info({kind, socket, bytes}, %{socket: {transport, socket}} = state)
      when (kind == :tcp and transport == :gen_tcp) or (kind == :ssl and transport == :ssl) do
    state =
      case Framer.feed(state.framer, bytes) do
        {:ok, lines, framer} ->
          state = %{state | framer: framer, needs_activation?: true}
          state = Enum.reduce(lines, state, &defer_line/2)
          resume(state)

        {:error, :response_too_large} ->
          poison(
            state,
            Error.new(:response_too_large, pending_stage(state),
              outcome_unknown?: mutation_stage?(pending_stage(state))
            )
          )

        {:error, :unsupported_literal} ->
          poison(state, Error.new(:protocol, pending_stage(state)))
      end

    {:noreply, state}
  end

  def handle_info({kind, socket}, %{socket: {_transport, socket}} = state)
      when kind in [:tcp_closed, :ssl_closed] do
    {:noreply, defer_close(state)}
  end

  def handle_info({kind, socket, _reason}, %{socket: {_transport, socket}} = state)
      when kind in [:tcp_error, :ssl_error] do
    {:noreply, defer_close(state)}
  end

  def handle_info({:deadline, ref}, %{pending: %{ref: ref}} = state) do
    {:noreply, poison(state, timeout_error(state))}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    cond do
      ref == state.owner_monitor ->
        {:stop, :normal, poison(state, Error.new(:closed, pending_stage(state)))}

      state.pending && ref == state.pending.caller_monitor ->
        {:noreply, poison(state, Error.new(:closed, pending_stage(state)))}

      state.pending && ref == state.pending.subscriber_monitor ->
        {:noreply, poison(state, Error.new(:closed, :idle))}

      state.idle && ref == state.idle.monitor ->
        {:noreply, poison(state, Error.new(:closed, :idle))}

      state.io_job && ref == state.io_job.monitor ->
        {:noreply, poison(state, Error.new(:closed, pending_stage(state)))}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, owner, _reason}, %{owner: owner} = state) do
    {:stop, :normal, poison(state, Error.new(:closed, pending_stage(state)))}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  defp defer_line(_line, %{socket: nil} = state) do
    state
  end

  defp defer_line(line, state) do
    size = state.deferred_size_bytes + byte_size(line)
    previous = if state.pending, do: state.pending.response_size_bytes, else: 0

    if size + previous > response_limit(state) do
      poison(
        state,
        Error.new(:response_too_large, pending_stage(state),
          outcome_unknown?: mutation_stage?(pending_stage(state))
        )
      )
    else
      %{state | deferred: :queue.in({:line, line}, state.deferred), deferred_size_bytes: size}
    end
  end

  defp defer_close(state) do
    error = Error.new(:closed, pending_stage(state))
    state = cancel_job(%{state | peer_closed?: true})

    case state.outbound do
      nil ->
        resume(%{
          state
          | deferred: :queue.in({:closed, error}, state.deferred),
            needs_activation?: false
        })

      %{bytes: "", after_write: :done} ->
        resume(%{
          state
          | outbound: nil,
            deferred: :queue.in({:closed, error}, state.deferred),
            needs_activation?: false
        })

      _unsent ->
        poison(state, error)
    end
  end

  defp response_limit(%{pending: %{stage: :body}} = state) do
    2 * state.body_limit_bytes + 2 * 1024 * 1024
  end

  defp response_limit(_state) do
    65 * 1024 * 1024
  end

  defp response(_line, %{socket: nil} = state) do
    state
  end

  defp response(line, state) do
    line =
      if state.pending && state.pending.stage == :body,
        do: line,
        else: Charset.utf8(line)

    limit = response_limit(state)

    size = if state.pending, do: state.pending.response_size_bytes + byte_size(line), else: 0

    if size > limit do
      poison(
        state,
        Error.new(:response_too_large, pending_stage(state),
          outcome_unknown?: mutation_stage?(pending_stage(state))
        )
      )
    else
      state = if state.pending, do: put_in(state.pending.response_size_bytes, size), else: state
      response_line(line, state)
    end
  end

  defp response_line(line, state) do
    cond do
      state.pending && now_ms() >= state.pending.deadline_ms ->
        poison(state, timeout_error(state))

      Protocol.bye?(line) and !(state.pending && state.pending.operation == :logout) ->
        poison(state, Error.new(:closed, pending_stage(state)))

      state.pending && state.pending.operation == :greeting ->
        greeting(line, state)

      state.pending ->
        command_response(line, state)

      state.idle ->
        idle_response(line, state)

      String.starts_with?(line, "*") ->
        state

      true ->
        poison(state, Error.new(:protocol))
    end
  end

  defp greeting(line, state) do
    case Regex.run(~r/^\*\s+(OK|PREAUTH)(?:\s|$)/i, line) do
      [_, status] ->
        preauthenticated? = String.upcase(status) == "PREAUTH"

        if preauthenticated? and elem(state.socket, 0) != :ssl do
          poison(state, Error.new(:protocol, :greeting))
        else
          finish(%{state | status: :live, preauthenticated?: preauthenticated?}, :ok)
        end

      _ ->
        poison(state, Error.new(:protocol, :greeting))
    end
  end

  defp command_response(line, state) do
    pending = state.pending

    case Protocol.tagged_status(line) do
      {tag, status} when tag not in ["*", "+"] ->
        cond do
          tag != pending.tag ->
            poison(state, Error.new(:protocol, pending.stage))

          status in [:no, :bad] ->
            refused(line, status, state)

          pending.phase in [:continuation, :sasl_challenge, :sasl_error_ack] or
              match?({:idle_start, _}, pending.operation) ->
            poison(state, Error.new(:protocol, pending.stage))

          true ->
            complete(line, state)
        end

      _ ->
        cond do
          String.starts_with?(line, "*") ->
            if pending.operation == :idle_end, do: notify_idle(state, {:update, line})
            %{state | pending: %{pending | lines: [line | pending.lines]}}

          String.starts_with?(line, "+") and match?({:idle_start, _}, pending.operation) ->
            enter_idle(state)

          String.starts_with?(line, "+") and pending.phase == :continuation ->
            continue_literal(state)

          String.starts_with?(line, "+") and pending.phase == :sasl_challenge ->
            sasl_response(state)

          # An XOAUTH2 failure arrives as one challenge with an error report, which the
          # client must answer with an empty response before the tagged NO.
          String.starts_with?(line, "+") and pending.phase == :sasl_result and
              pending.operation == {:authenticate, :xoauth2} ->
            write(%{state | pending: %{pending | phase: :sasl_error_ack}}, "\r\n")

          true ->
            poison(state, Error.new(:protocol, pending.stage))
        end
    end
  end

  defp refused(_line, :bad, %{pending: %{operation: :list_special_use}} = state) do
    state = %{state | pending: %{state.pending | operation: :list_special_fallback, lines: []}}
    start_command(state, [~s|LIST "" "*"|])
  end

  defp refused(line, status, state) do
    error = Error.refusal(status, line, state.pending.stage)

    # The server already said why in the XOAUTH2 error challenge: the token was refused.
    error =
      if state.pending.phase == :sasl_error_ack,
        do: %{error | code: :auth_rejected},
        else: error

    if state.pending.operation == :idle_end,
      do: poison(state, Error.new(:protocol, :idle)),
      else: finish(state, {:error, error})
  end

  defp complete(completion, state) do
    lines = Enum.reverse(state.pending.lines)
    result = result(state.pending.operation, lines, completion)
    if state.pending.operation == :idle_end, do: notify_idle(state, :ended)
    state = if state.pending.operation == :idle_end, do: clear_idle(state), else: state

    case result do
      {:error, :invalid_response} ->
        poison(state, Error.new(:protocol, state.pending.stage))

      _ ->
        logout? = state.pending.operation == :logout
        state = finish(state, result)

        if logout?,
          do: %{poison(state, Error.new(:closed, :logout)) | status: :closed},
          else: state
    end
  end

  defp enter_idle(%{pending: %{operation: {:idle_start, subscriber}}} = state) do
    idle = %{
      tag: state.pending.tag,
      ref: make_ref(),
      subscriber: subscriber,
      monitor: state.pending.subscriber_monitor
    }

    Enum.each(Enum.reverse(state.pending.lines), fn line ->
      send(subscriber, {:imap_idle, idle.ref, {:update, line}})
    end)

    # Reuse admission's monitor without a gap, including a DOWN already queued
    # while the server's continuation was arriving.
    state = %{state | idle: idle, pending: %{state.pending | subscriber_monitor: nil}}
    finish(state, {:ok, idle.ref})
  end

  defp idle_response(line, state) do
    case Protocol.tagged_status(line) do
      {tag, :ok} when tag == state.idle.tag ->
        notify_idle(state, :ended)
        clear_idle(state)

      _ ->
        if String.starts_with?(line, "*") do
          notify_idle(state, {:update, line})
          state
        else
          poison(state, Error.new(:protocol, :idle))
        end
    end
  end

  defp notify_idle(%{idle: nil}, _event) do
    :ok
  end

  defp notify_idle(state, event) do
    send(state.idle.subscriber, {:imap_idle, state.idle.ref, event})
  end

  defp clear_idle(%{idle: nil} = state) do
    state
  end

  defp clear_idle(state) do
    Process.demonitor(state.idle.monitor, [:flush])
    %{state | idle: nil}
  end

  defp finish(state, result) do
    Process.cancel_timer(state.pending.timer)
    Process.demonitor(state.pending.caller_monitor, [:flush])

    if state.pending.subscriber_monitor,
      do: Process.demonitor(state.pending.subscriber_monitor, [:flush])

    GenServer.reply(state.pending.from, result)

    %{
      state
      | pending: nil,
        framer: %{
          state.framer
          | literal_limit_bytes: 1024 * 1024,
            logical_limit_bytes: 65 * 1024 * 1024,
            reject_list_literals?: false
        }
    }
  end

  defp poison(state, error) do
    state = cancel_job(state)
    state = if state.pending, do: finish(state, {:error, error}), else: state
    notify_idle(state, {:error, error})
    state = clear_idle(state)
    Transport.abort(state.raw_socket)

    %{
      state
      | socket: nil,
        raw_socket: nil,
        status: :poisoned,
        framer: Framer.new(),
        outbound: nil,
        deferred: :queue.new(),
        deferred_size_bytes: 0,
        needs_activation?: false
    }
  end

  defp clear_job(%{io_job: nil} = state) do
    state
  end

  defp clear_job(state) do
    Process.demonitor(state.io_job.monitor, [:flush])
    %{state | io_job: nil}
  end

  defp cancel_job(%{io_job: nil} = state) do
    state
  end

  defp cancel_job(state) do
    Process.exit(state.io_job.pid, :kill)
    clear_job(state)
  end

  defp pending_stage(%{pending: %{stage: stage}}) do
    stage
  end

  defp pending_stage(%{idle: idle}) when idle != nil do
    :idle
  end

  defp pending_stage(_) do
    nil
  end

  defp timeout_error(state) do
    Error.new(:timeout, state.pending.stage, timeout_ms: state.pending.timeout_ms)
  end

  defp mutation_stage?(stage) do
    stage in [:store, :copy, :move, :expunge, :append]
  end

  defp now_ms do
    System.monotonic_time(:millisecond)
  end

  @impl true
  def terminate(_reason, state) do
    cancel_job(state)
    # OTP handles the start_link parent's EXIT before our handle_info clauses.
    # A still-active subscriber must hear that path too; poison already clears
    # idle, so its ordinary termination path never sends a duplicate event.
    notify_idle(state, {:error, Error.new(:closed, pending_stage(state))})
    Transport.abort(state.raw_socket)
  end

  @impl true
  def format_status(status) do
    Map.new(status, fn {key, _value} ->
      {key, if(key == :log, do: [], else: :redacted_imap_connection)}
    end)
  end

  defp prepare({:login, username, password}, _state) do
    if Protocol.safe_text?(username) and Protocol.safe_text?(password),
      do:
        {:command, :authentication, :authentication_ms,
         ["LOGIN #{Protocol.quote_string(username)} #{Protocol.quote_string(password)}"]},
      else: {:error, :authentication}
  end

  defp prepare({:authenticate, mechanism, username, secret}, _state) do
    case sasl_initial_response(mechanism, username, secret) do
      {:ok, response} ->
        name = mechanism |> Atom.to_string() |> String.upcase()

        {:command, :authentication, :authentication_ms,
         ["AUTHENTICATE " <> name, {:sasl, response}]}

      :error ->
        {:error, :authentication}
    end
  end

  defp prepare(:noop, _) do
    {:command, :noop, :command_ms, ["NOOP"]}
  end

  defp prepare({:status, folder, items}, _) do
    if Protocol.safe_text?(folder) and is_list(items) and items != [] and
         Enum.all?(items, &Map.has_key?(@status_items, &1)) do
      names = Enum.map_join(items, " ", &Map.fetch!(@status_items, &1))
      {:command, :status, :command_ms, ["STATUS #{Protocol.quote_mailbox(folder)} (#{names})"]}
    else
      {:error, :status}
    end
  end

  defp prepare(:logout, _) do
    {:command, :logout, :logout_ms, ["LOGOUT"]}
  end

  defp prepare(:capabilities, _) do
    {:command, :capability, :command_ms, ["CAPABILITY"]}
  end

  defp prepare({kind, folder}, _) when kind in [:select, :examine] do
    if Protocol.safe_text?(folder),
      do:
        {:command, :select, :command_ms,
         [String.upcase(Atom.to_string(kind)) <> " " <> Protocol.quote_mailbox(folder)]},
      else: {:error, :select}
  end

  defp prepare({kind, segments}, _) when kind in [:search, :search_strict] do
    segments = if is_binary(segments), do: [segments], else: segments

    if valid_segments?(segments),
      do: {:command, :search, :command_ms, ["UID SEARCH " | segments]},
      else: {:error, :search}
  end

  defp prepare({:fetch, [], _items}, _) do
    {:done, {:ok, %{messages: %{}, other_lines: [], completion: ""}}}
  end

  defp prepare({:fetch, uids, items}, _) do
    if valid_uids?(uids) and Protocol.safe_text?(items),
      do: {:command, :fetch, :command_ms, ["UID FETCH #{Enum.join(uids, ",")} (#{items})"]},
      else: {:error, :fetch}
  end

  defp prepare({:fetch_body_response, uid, section}, state) do
    prepare({:fetch_body, uid, section}, state)
  end

  defp prepare({:fetch_body, uid, section}, _) do
    if valid_uids?([uid]) and is_binary(section) and
         Regex.match?(~r/\A(?:\d+(?:\.\d+)*(?:\.(?:MIME|TEXT|HEADER))?|TEXT|HEADER|)\z/i, section),
       do: {:command, :body, :body_fetch_ms, ["UID FETCH #{uid} (BODY.PEEK[#{section}])"]},
       else: {:error, :body}
  end

  defp prepare({:store, [], _flags, _action}, _) do
    {:done, :ok}
  end

  defp prepare({:store, uids, flags, action}, _) do
    if valid_uids?(uids) and is_binary(flags) and
         Enum.all?(String.split(flags, " "), &valid_flag?/1) and action in ["+", "-", ""],
       do:
         {:command, :store, :command_ms,
          ["UID STORE #{Enum.join(uids, ",")} #{action}FLAGS (#{flags})"]},
       else: {:error, :store}
  end

  defp prepare({kind, [], _folder}, _) when kind in [:copy, :move] do
    {:done, :ok}
  end

  defp prepare({kind, uids, folder}, _) when kind in [:copy, :move] do
    if valid_uids?(uids) and Protocol.safe_text?(folder),
      do:
        {:command, kind, :command_ms,
         [
           "UID #{String.upcase(Atom.to_string(kind))} #{Enum.join(uids, ",")} #{Protocol.quote_mailbox(folder)}"
         ]},
      else: {:error, kind}
  end

  defp prepare({:expunge, []}, _) do
    {:done, :ok}
  end

  defp prepare({:expunge, uids}, _) do
    if valid_uids?(uids),
      do: {:command, :expunge, :command_ms, ["UID EXPUNGE #{Enum.join(uids, ",")}"]},
      else: {:error, :expunge}
  end

  defp prepare(:list, _) do
    {:command, :list, :command_ms, [~s|LIST "" "*"|]}
  end

  defp prepare(:list_special_use, _) do
    {:command, :list, :command_ms, [~s|LIST "" "*" RETURN (SPECIAL-USE)|]}
  end

  defp prepare({:append, folder, bytes, opts}, _) do
    opts = if Keyword.keyword?(opts), do: opts, else: [flags: :invalid]
    flags = Keyword.get(opts, :flags, [])
    date = Keyword.get(opts, :internal_date)

    if Protocol.safe_text?(folder) and is_binary(bytes) and is_list(flags) and
         Enum.all?(flags, &valid_flag?/1) and
         (is_nil(date) or Protocol.valid_internal_date?(date)) do
      date = if date, do: ~s|"#{Protocol.internal_date(date)}" |, else: ""

      {:command, :append, :append_ms,
       [
         "APPEND #{Protocol.quote_mailbox(folder)} (#{Enum.join(flags, " ")}) #{date}",
         {:literal, bytes}
       ]}
    else
      {:error, :append}
    end
  end

  defp prepare({:idle_start, subscriber}, _) do
    if is_pid(subscriber), do: {:command, :idle, :command_ms, ["IDLE"]}, else: {:error, :idle}
  end

  defp prepare(_, _) do
    {:error, nil}
  end

  # A system flag (\\Seen) or a keyword ($Label): an IMAP atom (printable ASCII
  # without atom-specials), never \\Recent, which only the server may set.
  defp valid_flag?(flag) do
    is_binary(flag) and Regex.match?(~r/\A\\?[\x21-\x7E]+\z/, flag) and
      not Regex.match?(~r/.[\\]|[(){%*"\]]/, flag) and String.downcase(flag) != "\\recent"
  end

  # XOAUTH2 separates its fields with 0x01, so neither value may contain one.
  defp sasl_initial_response(:plain, username, password) do
    if Protocol.safe_text?(username) and Protocol.safe_text?(password) do
      {:ok, Base.encode64(<<0, username::binary, 0, password::binary>>)}
    else
      :error
    end
  end

  defp sasl_initial_response(:xoauth2, username, token) do
    if Protocol.safe_text?(username) and Protocol.safe_text?(token) and
         !String.contains?(username <> token, <<1>>) do
      {:ok, Base.encode64("user=#{username}\x01auth=Bearer #{token}\x01\x01")}
    else
      :error
    end
  end

  defp sasl_initial_response(_mechanism, _username, _secret) do
    :error
  end

  defp valid_uids?(uids) do
    is_list(uids) and uids != [] and
      Enum.all?(uids, &(is_integer(&1) and &1 in 1..4_294_967_295))
  end

  defp valid_segments?(segments) do
    is_list(segments) and segments != [] and
      Enum.all?(segments, fn
        {:literal, bytes} -> is_binary(bytes) and Protocol.safe_text?(bytes)
        text -> Protocol.safe_text?(text)
      end)
  end

  defp result(:capabilities, lines, _) do
    capabilities =
      Enum.flat_map(lines, fn line ->
        case Regex.run(~r/^\*\s+CAPABILITY\s+(.*)$/i, line) do
          [_, capabilities] -> capabilities |> String.upcase() |> String.split()
          _ -> []
        end
      end)

    {:ok, MapSet.new(capabilities)}
  end

  defp result({:search, _}, lines, _) do
    {:ok, Protocol.search_uids(lines) || []}
  end

  defp result({:search_strict, _}, lines, completion) do
    {:ok, %{uids: Protocol.search_uids(lines), lines: lines, completion: completion}}
  end

  defp result({:fetch, _, _}, lines, completion) do
    {:ok, Map.put(Protocol.metadata(lines), :completion, completion)}
  end

  defp result({:fetch_body, uid, section}, lines, completion) do
    with {:ok, response} <- result({:fetch_body_response, uid, section}, lines, completion) do
      if response.body == :missing,
        do: {:error, Error.new(:no_data, :body)},
        else: {:ok, response.body}
    end
  end

  defp result({:fetch_body_response, uid, section}, lines, completion) do
    with {:ok, body} <- Protocol.body(lines, uid, section) do
      other_lines =
        lines
        |> Enum.reject(&Regex.match?(~r/^\*\s+\d+\s+FETCH\b/i, &1))
        |> Enum.map(&Charset.utf8/1)

      {:ok, %{body: body, other_lines: other_lines, completion: Charset.utf8(completion)}}
    end
  end

  defp result({:examine, _}, lines, _) do
    validity = response_number(lines, "UIDVALIDITY")
    next = response_number(lines, "UIDNEXT")

    if validity && next,
      do: {:ok, %{uid_validity: validity, uid_next: next, lines: lines}},
      else: {:error, :invalid_response}
  end

  defp result(kind, lines, _) when kind in [:list, :list_special_use, :list_special_fallback] do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, folders} ->
      case Protocol.list_folder(line, kind != :list) do
        {:ok, folder} -> {:cont, {:ok, [folder | folders]}}
        :other -> {:cont, {:ok, folders}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, folders} -> {:ok, Enum.reverse(folders)}
      error -> error
    end
  end

  defp result(:noop, lines, _) do
    {:ok, lines}
  end

  defp result({:status, folder, _items}, lines, _) do
    {:ok, Protocol.status(lines, folder)}
  end

  defp result({:append, _folder, _bytes, _opts}, _lines, completion) do
    {:ok, Protocol.append_uid(completion)}
  end

  defp result(_, _, _) do
    :ok
  end

  defp response_number(lines, code) do
    Enum.find_value(lines, fn line ->
      case Regex.run(~r/^\*\s+OK\s+\[#{code}\s+(\d+)\]/i, line) do
        [_, number] ->
          case Protocol.positive_integer(number) do
            {:ok, number} -> number
            _ -> nil
          end

        _ ->
          nil
      end
    end)
  end
end
