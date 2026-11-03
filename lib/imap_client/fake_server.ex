defmodule IMAPClient.FakeServer do
  @moduledoc """
  A stateful, loopback-only IMAP server for tests and development, which the real
  client talks to over TCP. It parses and enforces the server side independently of
  the client: authentication, selected-mailbox state and capabilities.

  Start an isolated instance with `start_supervised!({IMAPClient.FakeServer, opts})`
  in a test, or under an application's own supervisor in development. It listens on
  127.0.0.1 only. `endpoint/1` returns a session config for it; `mailbox/2`, `commands/1`, `remove_message/3`,
  `script_next/3`, `release/1`, `push_idle/2`, `add_message/3`, `set_uid_validity/3`,
  `queue_untagged/2` and `drop_connections/1` are test setup/inspection APIs.

  Options are `:name` (default nil), `:username`/`:password` (fake-only defaults;
  `:passwords` lists more passwords LOGIN and AUTHENTICATE PLAIN accept for that
  username), `:access_token` (the one XOAUTH2 token accepted),
  `:capabilities` (default IMAP4rev1, IDLE, MOVE, UIDPLUS, SPECIAL-USE, AUTH=PLAIN,
  AUTH=XOAUTH2),
  `:greeting` (`:ok` or `:preauth`), and `:mailboxes`. Mailboxes are a name-keyed
  map with `:messages`, `:uid_validity`, `:uid_next`, and `:flags`. Messages have
  `:uid`, `:flags`, raw IMAP inner `:envelope`/`:bodystructure` strings,
  `:headers`, `:internal_date` and a `:sections` map of section to raw bytes.

  `script_next/3` scripts a command atom (`:search`, `:fetch`, etc.) with `:stall`,
  `:close`, `{:refuse, :no | :bad, code}` (code may be nil, or one of TRYCREATE,
  NONEXISTENT, AUTHENTICATIONFAILED, UNAVAILABLE, INUSE, ALERT or WEBALERT),
  `{:omit, :search | :metadata | :body}`, `{:remove, mailbox, uid}` (remove
  just before the matching command), or `{:arrive, mailbox, message}` (add the
  message just before the matching command and announce it with an untagged
  EXISTS ahead of that command's response), or `{:hold, owner}` (run the command now
  but hold its response: the connection sends `owner` `{:imap_fake_held, held}` and
  answers only after `release/1` with that `held`, or once `owner` exits; the server
  itself keeps serving every other connection; not for LOGOUT). Commands the held
  connection sends meanwhile wait and are answered in order after it, `push_idle/2`
  bytes still go out at once, and a disconnect ends the held connection. Scripts are consumed by that command
  only. History contains command kinds and UIDs, never credentials or APPEND content.
  The setup-only `:fetch_body` kind matches body section FETCH requests while
  skipping metadata FETCH (including HEADER.FIELDS). History still says `:fetch`.
  A DONE that ends an IDLE is recorded as `:done`.
  The independent server parser deliberately does not use the client codec.

  This models the client's wire subset, rather than a complete mail service.
  SEARCH compares stored header/envelope text and raw section bytes; MIME charset
  decoding/indexing is not modeled. Mailbox updates are delivered to IDLE peers
  only through `push_idle/2`, and to other connected peers only through
  `queue_untagged/2`. TLS verification uses separate local fixture peers.
  AUTHENTICATE supports PLAIN and XOAUTH2 without SASL-IR; a refused XOAUTH2 token
  gets an error challenge and then NO, as real servers do. STARTTLS, ACLs, mailbox
  creation/deletion and general SEARCH extensions are outside this fake's command
  contract and are refused.
  """

  use GenServer

  alias IMAPClient.FakeServer.Peer

  # IMAP UIDs and UID set endpoints are nonzero unsigned 32-bit integers.
  @max_uid 4_294_967_295

  @doc "Starts an isolated fake listener; returns `{:ok, pid}` or a listener/start error."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Returns loopback client options, including the configured fake-only credentials."
  def endpoint(server) do
    GenServer.call(server, :endpoint)
  end

  @doc "Returns sanitized command records in arrival order, without message or credential data."
  def commands(server) do
    GenServer.call(server, :commands)
  end

  @doc "Returns the current mailbox map, or nil when it does not exist."
  def mailbox(server, name) do
    GenServer.call(server, {:mailbox, name})
  end

  @doc "Enqueues one script for the next matching command; returns :ok or {:error, :invalid_script}."
  def script_next(server, command, action) do
    GenServer.call(server, {:fail, command, action})
  end

  @doc "Sends the response a `{:hold, owner}` script held (see `script_next/3`)."
  def release({peer, ref}) when is_pid(peer) and is_reference(ref) do
    send(peer, {:release, ref})
    :ok
  end

  @doc "Removes a UID without reusing it; returns :ok or {:error, :nonexistent} for an unknown mailbox."
  def remove_message(server, name, uid) do
    GenServer.call(server, {:remove, name, uid})
  end

  @doc "Sends one untagged line to IDLE peers; returns :ok or {:error, :invalid_update}."
  def push_idle(server, line) do
    GenServer.call(server, {:push_idle, line})
  end

  @doc """
  Adds an arriving message at the mailbox's UIDNEXT, which then advances. Takes the
  message fields of the `:mailboxes` option except `:uid`. Returns `{:ok, uid}` or
  `{:error, :nonexistent}`, or `{:error, :invalid_message}` when the message is not a
  map. Connected peers are not told: announce it explicitly with `push_idle/2` or
  `queue_untagged/2`, as a test needs.
  """
  def add_message(server, name, message) do
    GenServer.call(server, {:add_message, name, message})
  end

  @doc """
  Replaces the mailbox's UIDVALIDITY (a positive 32-bit integer), as when a server
  rebuilds it; messages keep their UIDs. Returns :ok, `{:error, :nonexistent}` or
  `{:error, :invalid_uid_validity}`.
  """
  def set_uid_validity(server, name, uid_validity) do
    GenServer.call(server, {:set_uid_validity, name, uid_validity})
  end

  @doc """
  Queues one untagged line for every connected peer, sent ahead of the response to
  that peer's next command (a server may send EXISTS inside any response). Returns
  :ok or {:error, :invalid_update}.
  """
  def queue_untagged(server, line) do
    GenServer.call(server, {:queue_untagged, line})
  end

  @doc "Closes every connected peer's socket without BYE, like a silent network cut; returns :ok."
  def drop_connections(server) do
    GenServer.call(server, :drop_connections)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, listener} <-
           :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true]),
         {:ok, {_, port}} <- :inet.sockname(listener) do
      server = self()
      acceptor = spawn_link(fn -> accept(listener, server) end)

      {:ok,
       %{
         listener: listener,
         acceptor: acceptor,
         port: port,
         username: Keyword.get(opts, :username, "fake-user"),
         password: Keyword.get(opts, :password, "fake-password"),
         access_token: Keyword.get(opts, :access_token, "fake-access-token"),
         passwords: Keyword.get(opts, :passwords, []),
         capabilities:
           Keyword.get(opts, :capabilities, [
             "IMAP4rev1",
             "IDLE",
             "MOVE",
             "UIDPLUS",
             "SPECIAL-USE",
             "AUTH=PLAIN",
             "AUTH=XOAUTH2"
           ])
           |> Enum.map(&String.upcase/1),
         greeting: Keyword.get(opts, :greeting, :ok),
         mailboxes: normalize_mailboxes(Keyword.get(opts, :mailboxes, %{"INBOX" => %{}})),
         peers: %{},
         failures: [],
         commands: []
       }}
    end
  end

  defp accept(listener, server) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        peer = spawn(fn -> Peer.wait(server) end)
        :ok = :gen_tcp.controlling_process(socket, peer)
        send(peer, {:socket, socket})
        accept(listener, server)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        exit(reason)
    end
  end

  defp normalize_mailboxes(mailboxes) do
    Map.new(mailboxes, fn {name, mailbox} ->
      messages = Enum.map(Map.get(mailbox, :messages, []), &normalize_message/1)
      next = Enum.reduce(messages, 1, &max(&1.uid + 1, &2))

      {name,
       %{
         messages: Enum.sort_by(messages, & &1.uid),
         uid_validity: Map.get(mailbox, :uid_validity, 1),
         uid_next: max(Map.get(mailbox, :uid_next, next), next),
         flags: Map.get(mailbox, :flags, [])
       }}
    end)
  end

  defp normalize_message(message) do
    message =
      Map.merge(
        %{
          flags: [],
          envelope: "NIL NIL NIL NIL NIL NIL NIL NIL NIL NIL",
          bodystructure: "\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 0 0",
          headers: "",
          internal_date: "01-Jan-2026 00:00:00 +0000",
          sections: %{}
        },
        message
      )

    %{message | flags: Enum.map(message.flags, &canonical_flag/1)}
  end

  @impl true
  def handle_call(:endpoint, _from, state) do
    {:reply,
     %{
       host: "127.0.0.1",
       port: state.port,
       use_tls: false,
       username: state.username,
       password: state.password,
       access_token: state.access_token
     }, state}
  end

  def handle_call(:commands, _from, state) do
    {:reply, Enum.reverse(state.commands), state}
  end

  def handle_call({:mailbox, name}, _from, state) do
    {:reply, Map.get(state.mailboxes, name), state}
  end

  def handle_call({:fail, kind, action}, _from, state) do
    if valid_failure?(kind, action) do
      {:reply, :ok, %{state | failures: state.failures ++ [{kind, action}]}}
    else
      {:reply, {:error, :invalid_script}, state}
    end
  end

  def handle_call({:remove, name, uid}, _from, state) do
    case Map.fetch(state.mailboxes, name) do
      {:ok, mailbox} ->
        mailbox = %{mailbox | messages: Enum.reject(mailbox.messages, &(&1.uid == uid))}
        {:reply, :ok, put_in(state.mailboxes[name], mailbox)}

      :error ->
        {:reply, {:error, :nonexistent}, state}
    end
  end

  def handle_call({:push_idle, line}, _from, state) do
    if untagged_line?(line) do
      Enum.each(state.peers, fn {peer, session} ->
        if session.idle, do: send(peer, {:push, line <> "\r\n"})
      end)

      {:reply, :ok, state}
    else
      {:reply, {:error, :invalid_update}, state}
    end
  end

  def handle_call({:add_message, name, message}, _from, state) when is_map(message) do
    case Map.fetch(state.mailboxes, name) do
      {:ok, mailbox} ->
        uid = mailbox.uid_next
        message = normalize_message(Map.put(message, :uid, uid))
        mailbox = %{mailbox | messages: mailbox.messages ++ [message], uid_next: uid + 1}
        {:reply, {:ok, uid}, put_in(state.mailboxes[name], mailbox)}

      :error ->
        {:reply, {:error, :nonexistent}, state}
    end
  end

  def handle_call({:add_message, _name, _message}, _from, state) do
    {:reply, {:error, :invalid_message}, state}
  end

  def handle_call({:set_uid_validity, name, uid_validity}, _from, state) do
    cond do
      not (is_integer(uid_validity) and uid_validity in 1..@max_uid) ->
        {:reply, {:error, :invalid_uid_validity}, state}

      Map.has_key?(state.mailboxes, name) ->
        {:reply, :ok, put_in(state.mailboxes[name].uid_validity, uid_validity)}

      true ->
        {:reply, {:error, :nonexistent}, state}
    end
  end

  def handle_call({:queue_untagged, line}, _from, state) do
    if untagged_line?(line) do
      peers =
        Map.new(state.peers, fn {peer, session} ->
          {peer, %{session | untagged: session.untagged ++ [line <> "\r\n"]}}
        end)

      {:reply, :ok, %{state | peers: peers}}
    else
      {:reply, {:error, :invalid_update}, state}
    end
  end

  def handle_call(:drop_connections, _from, state) do
    Enum.each(Map.keys(state.peers), &send(&1, :close))
    {:reply, :ok, state}
  end

  def handle_call(:register, {peer, _}, state) do
    Process.monitor(peer)

    session = %{
      authenticated: state.greeting == :preauth,
      selected: nil,
      readonly: false,
      idle: nil,
      sasl: nil,
      untagged: []
    }

    greeting =
      if state.greeting == :preauth, do: "* PREAUTH fake ready\r\n", else: "* OK fake ready\r\n"

    {:reply, greeting, put_in(state.peers[peer], session)}
  end

  def handle_call({:continue, prefix}, {peer, _}, state) do
    # A server must refuse an APPEND before requesting its potentially large literal
    # when its state already makes that command invalid.
    session = Map.fetch!(state.peers, peer)
    authenticated = session.authenticated or not Regex.match?(~r/^\S+\s+(APPEND|UID)\b/i, prefix)
    {:reply, authenticated and is_nil(session.idle), state}
  end

  def handle_call({:sasl, line}, {peer, _}, state) do
    session = Map.fetch!(state.peers, peer)
    {reply, session} = sasl_step(line, session, state)
    {:reply, reply, put_in(state.peers[peer], session)}
  end

  def handle_call({:command, tokens}, {peer, _}, state) do
    session = Map.fetch!(state.peers, peer)
    {reply, session, state} = execute(tokens, session, state)
    {reply, session} = with_untagged(reply, session)
    {:reply, reply, put_in(state.peers[peer], session)}
  end

  defp untagged_line?(line) do
    is_binary(line) and String.starts_with?(line, "* ") and
      not String.contains?(line, ["\r", "\n"])
  end

  # Queued untagged lines go out with the next response that has bytes to send.
  defp with_untagged(reply, %{untagged: []} = session) do
    {reply, session}
  end

  defp with_untagged({:hold, owner, bytes}, session) do
    {{:hold, owner, [session.untagged, bytes]}, %{session | untagged: []}}
  end

  defp with_untagged({:close_after, bytes}, session) do
    {{:close_after, [session.untagged, bytes]}, %{session | untagged: []}}
  end

  defp with_untagged(reply, session) when is_binary(reply) or is_list(reply) do
    {[session.untagged, reply], %{session | untagged: []}}
  end

  defp with_untagged(reply, session) do
    {reply, session}
  end

  defp valid_failure?(kind, action) do
    kind in [
      :login,
      :authenticate,
      :noop,
      :status,
      :logout,
      :capability,
      :select,
      :examine,
      :search,
      :fetch,
      :fetch_body,
      :store,
      :copy,
      :move,
      :expunge,
      :list,
      :append,
      :idle
    ] and
      (action in [:stall, :close] or
         match?({:omit, kind} when kind in [:search, :metadata, :body], action) or
         match?({:remove, name, uid} when is_binary(name) and is_integer(uid) and uid > 0, action) or
         match?({:arrive, name, message} when is_binary(name) and is_map(message), action) or
         (kind != :logout and match?({:hold, owner} when is_pid(owner), action)) or
         match?({:refuse, status, nil} when status in [:no, :bad], action) or
         match?(
           {:refuse, status, code}
           when status in [:no, :bad] and
                  code in [
                    "TRYCREATE",
                    "NONEXISTENT",
                    "AUTHENTICATIONFAILED",
                    "UNAVAILABLE",
                    "INUSE",
                    "ALERT",
                    "WEBALERT"
                  ],
           action
         ))
  end

  defp execute([tag, command | args], session, state)
       when is_binary(tag) and is_binary(command) do
    command = String.upcase(command)
    {kind, args} = command_kind(command, args)
    state = %{state | commands: [history(kind, args) | state.commands]}

    cond do
      not Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._-]*$/, tag) ->
        {"* BAD invalid tag\r\n", session, state}

      session.idle ->
        {status(tag, :bad), session, state}

      kind == :unknown ->
        {status(tag, :bad), session, state}

      kind not in [:login, :authenticate, :capability, :logout, :noop] and
          not session.authenticated ->
        {status(tag, :no), session, state}

      true ->
        # A SELECT/EXAMINE attempt deselects the old mailbox even when the new
        # mailbox is refused, including a scripted refusal.
        session =
          if kind in [:select, :examine],
            do: %{session | selected: nil, readonly: false},
            else: session

        script_kinds =
          if kind == :fetch and body_fetch_args?(args), do: [:fetch, :fetch_body], else: [kind]

        case take_failure(state.failures, script_kinds) do
          {:none, failures} ->
            dispatch(kind, tag, args, session, %{state | failures: failures}, nil)

          {action, failures} ->
            state = %{state | failures: failures}

            case action do
              :stall ->
                {:stall, session, state}

              :close ->
                {:close, session, state}

              {:refuse, status, code} ->
                {status(tag, status, code), session, state}

              {:omit, item} ->
                dispatch(kind, tag, args, session, state, item)

              # The connection holds the response (FakeServer.Peer); only bytes can be held.
              {:hold, owner} ->
                case dispatch(kind, tag, args, session, state, nil) do
                  {reply, session, state} when is_binary(reply) or is_list(reply) ->
                    {{:hold, owner, reply}, session, state}

                  other ->
                    other
                end

              {:remove, name, uid} ->
                state =
                  case Map.fetch(state.mailboxes, name) do
                    {:ok, mailbox} ->
                      put_in(state.mailboxes[name], %{
                        mailbox
                        | messages: Enum.reject(mailbox.messages, &(&1.uid == uid))
                      })

                    :error ->
                      state
                  end

                dispatch(kind, tag, args, session, state, nil)

              {:arrive, name, message} ->
                case Map.fetch(state.mailboxes, name) do
                  {:ok, mailbox} ->
                    uid = mailbox.uid_next
                    message = normalize_message(Map.put(message, :uid, uid))
                    messages = mailbox.messages ++ [message]
                    mailbox = %{mailbox | messages: messages, uid_next: uid + 1}
                    exists = "* #{length(messages)} EXISTS\r\n"
                    session = %{session | untagged: session.untagged ++ [exists]}

                    dispatch(
                      kind,
                      tag,
                      args,
                      session,
                      put_in(state.mailboxes[name], mailbox),
                      nil
                    )

                  :error ->
                    dispatch(kind, tag, args, session, state, nil)
                end
            end
        end
    end
  end

  defp execute(["DONE"], %{idle: tag} = session, state) when not is_nil(tag) do
    state = %{state | commands: [%{command: :done} | state.commands]}
    {status(tag, :ok), %{session | idle: nil}, state}
  end

  defp execute(_, session, state) do
    {"* BAD invalid command\r\n", session, state}
  end

  defp command_kind("UID", [command | args]) when is_binary(command) do
    kind = %{
      "SEARCH" => :search,
      "FETCH" => :fetch,
      "STORE" => :store,
      "COPY" => :copy,
      "MOVE" => :move,
      "EXPUNGE" => :expunge
    }

    {Map.get(kind, String.upcase(command), :unknown), args}
  end

  defp command_kind(command, args) do
    kind = %{
      "LOGIN" => :login,
      "AUTHENTICATE" => :authenticate,
      "NOOP" => :noop,
      "STATUS" => :status,
      "LOGOUT" => :logout,
      "CAPABILITY" => :capability,
      "SELECT" => :select,
      "EXAMINE" => :examine,
      "LIST" => :list,
      "APPEND" => :append,
      "IDLE" => :idle
    }

    {Map.get(kind, command, :unknown), args}
  end

  defp history(kind, [uids | _])
       when kind in [:fetch, :store, :copy, :move, :expunge] and is_binary(uids) do
    if valid_uid_set?(uids), do: %{command: kind, uid_set: uids}, else: %{command: kind}
  end

  defp history(kind, _) do
    %{command: kind}
  end

  defp take_failure([], _) do
    {:none, []}
  end

  defp take_failure([{kind, action} = head | rest], kinds) do
    if kind in kinds do
      {action, rest}
    else
      {action, rest} = take_failure(rest, kinds)
      {action, [head | rest]}
    end
  end

  defp body_fetch_args?([_, items]) when is_list(items) do
    body_fetch_items?(items)
  end

  defp body_fetch_args?(_) do
    false
  end

  defp body_fetch_items?(items) do
    Enum.any?(items, fn
      item when is_binary(item) ->
        item = String.upcase(item)

        String.starts_with?(item, "BODY.PEEK[") and
          not String.starts_with?(item, "BODY.PEEK[HEADER")

      _ ->
        false
    end)
  end

  defp dispatch(:login, tag, [username, password], session, state, _) do
    if not session.authenticated and text(username) == state.username and
         text(password) in [state.password | state.passwords] do
      {status(tag, :ok), %{session | authenticated: true}, state}
    else
      {status(tag, :no, "AUTHENTICATIONFAILED"), session, state}
    end
  end

  # SASL-IR is not advertised, so the initial response must follow a continuation.
  defp dispatch(:authenticate, tag, [mechanism], session, state, _) when is_binary(mechanism) do
    mechanism = String.upcase(mechanism)

    if not session.authenticated and mechanism in ["PLAIN", "XOAUTH2"] and
         "AUTH=#{mechanism}" in state.capabilities do
      {{:sasl, "+ \r\n"}, %{session | sasl: %{tag: tag, mechanism: mechanism, stage: :response}},
       state}
    else
      {status(tag, :no), session, state}
    end
  end

  defp dispatch(:noop, tag, [], session, state, _) do
    {status(tag, :ok), session, state}
  end

  defp dispatch(:status, tag, [name, items], session, state, _) when is_list(items) do
    names = Enum.map(items, &(&1 |> text() |> to_string() |> String.upcase()))
    known = ~w(MESSAGES RECENT UIDNEXT UIDVALIDITY UNSEEN)

    with true <- names != [] and Enum.all?(names, &(&1 in known)),
         {:ok, mailbox} <- Map.fetch(state.mailboxes, text(name)) do
      values =
        Enum.map_join(names, " ", fn item ->
          value =
            case item do
              "MESSAGES" -> length(mailbox.messages)
              "RECENT" -> 0
              "UIDNEXT" -> mailbox.uid_next
              "UIDVALIDITY" -> mailbox.uid_validity
              "UNSEEN" -> Enum.count(mailbox.messages, &("\\Seen" not in &1.flags))
            end

          "#{item} #{value}"
        end)

      {["* STATUS ", quote_string(text(name)), " (", values, ")\r\n", status(tag, :ok)], session,
       state}
    else
      false -> {status(tag, :bad), session, state}
      :error -> {status(tag, :no, "NONEXISTENT"), session, state}
    end
  end

  defp dispatch(:capability, tag, [], session, state, _) do
    {["* CAPABILITY ", Enum.join(state.capabilities, " "), "\r\n", status(tag, :ok)], session,
     state}
  end

  defp dispatch(:logout, tag, [], session, state, _) do
    {{:close_after, ["* BYE closing\r\n", status(tag, :ok)]}, session, state}
  end

  defp dispatch(kind, tag, [name], session, state, _) when kind in [:select, :examine] do
    name = text(name)

    case Map.fetch(state.mailboxes, name) do
      {:ok, mailbox} ->
        readonly = kind == :examine

        reply = [
          "* FLAGS (\\Seen \\Answered \\Flagged \\Deleted \\Draft)\r\n",
          "* ",
          to_string(length(mailbox.messages)),
          " EXISTS\r\n",
          "* OK [UIDVALIDITY ",
          to_string(mailbox.uid_validity),
          "] stable\r\n",
          "* OK [UIDNEXT ",
          to_string(mailbox.uid_next),
          "] next\r\n",
          status(tag, :ok, if(readonly, do: "READ-ONLY", else: "READ-WRITE"))
        ]

        {reply, %{session | selected: name, readonly: readonly}, state}

      :error ->
        {status(tag, :no, "NONEXISTENT"), session, state}
    end
  end

  defp dispatch(:list, tag, args, session, state, _) do
    special? = Enum.any?(args, &is_list/1)

    cond do
      special? and "SPECIAL-USE" not in state.capabilities ->
        {status(tag, :bad), session, state}

      args not in [["", "*"]] and
        args != [["SPECIAL-USE"], "", "*"] and args != ["", "*", "RETURN", ["SPECIAL-USE"]] ->
        {status(tag, :bad), session, state}

      true ->
        lines =
          Enum.map(Enum.sort(state.mailboxes), fn {name, mailbox} ->
            ["* LIST (", Enum.join(mailbox.flags, " "), ") \"/\" ", quote_string(name), "\r\n"]
          end)

        {[lines, status(tag, :ok)], session, state}
    end
  end

  defp dispatch(:append, tag, [name, flags, date, {:literal, body}], session, state, omitted)
       when is_list(flags) and is_binary(date) do
    if Regex.match?(
         ~r/\A[ 0-9][0-9]-[A-Z][a-z]{2}-[0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} [+-][0-9]{4}\z/,
         date
       ) do
      append(tag, name, flags, date, body, session, state, omitted)
    else
      {status(tag, :bad), session, state}
    end
  end

  defp dispatch(:append, tag, [name, flags, {:literal, body}], session, state, omitted)
       when is_list(flags) do
    append(tag, name, flags, nil, body, session, state, omitted)
  end

  defp dispatch(:idle, tag, [], session, state, _) do
    if "IDLE" in state.capabilities do
      {"+ idling\r\n", %{session | idle: tag}, state}
    else
      {status(tag, :bad), session, state}
    end
  end

  defp dispatch(kind, tag, args, %{selected: selected} = session, state, omitted)
       when kind in [:search, :fetch, :store, :copy, :move, :expunge] and not is_nil(selected) do
    mailbox = Map.fetch!(state.mailboxes, selected)

    cond do
      session.readonly and kind in [:store, :move, :expunge] ->
        {status(tag, :no), session, state}

      kind == :move and "MOVE" not in state.capabilities ->
        {status(tag, :bad), session, state}

      kind == :expunge and "UIDPLUS" not in state.capabilities ->
        {status(tag, :bad), session, state}

      true ->
        selected_command(kind, tag, args, mailbox, session, state, omitted)
    end
  end

  defp dispatch(_, tag, _, session, state, _) do
    {status(tag, :bad), session, state}
  end

  defp append(tag, name, flags, date, body, session, state, _omitted) do
    name = text(name)

    case Map.fetch(state.mailboxes, name) do
      {:ok, mailbox} ->
        with {:ok, flags} <- normalize_flags(flags) do
          message =
            %{uid: mailbox.uid_next, flags: flags, sections: %{"" => body, "TEXT" => body}}
            |> then(
              &if(date, do: Map.put(&1, :internal_date, String.trim_leading(date)), else: &1)
            )
            |> normalize_message()

          mailbox = %{
            mailbox
            | messages: mailbox.messages ++ [message],
              uid_next: mailbox.uid_next + 1
          }

          code =
            if "UIDPLUS" in state.capabilities,
              do: "APPENDUID #{mailbox.uid_validity} #{message.uid}",
              else: nil

          reply = status(tag, :ok, code)
          {reply, session, put_in(state.mailboxes[name], mailbox)}
        else
          :error ->
            {status(tag, :bad), session, state}
        end

      :error ->
        {status(tag, :no, "TRYCREATE"), session, state}
    end
  end

  defp selected_command(:search, tag, criteria, mailbox, session, state, omitted)
       when criteria != [] do
    case search_mailbox(mailbox.messages, criteria) do
      {:ok, messages} ->
        line =
          if omitted == :search,
            do: [],
            else: ["* SEARCH", Enum.map(messages, &[" ", to_string(&1.uid)]), "\r\n"]

        {[line, status(tag, :ok)], session, state}

      :error ->
        {status(tag, :bad), session, state}
    end
  end

  defp selected_command(:fetch, tag, [uids, items], mailbox, session, state, omitted)
       when is_list(items) do
    with {:ok, messages} <- by_uid(mailbox.messages, uids),
         true <- valid_fetch_items?(items) do
      lines =
        Enum.flat_map(Enum.with_index(mailbox.messages, 1), fn {message, index} ->
          if message in messages, do: fetch_line(message, index, items, omitted), else: []
        end)

      {[lines, status(tag, :ok)], session, state}
    else
      _ -> {status(tag, :bad), session, state}
    end
  end

  defp selected_command(:store, tag, [uids, action, flags], mailbox, session, state, _)
       when is_list(flags) and is_binary(action) do
    with {:ok, messages} <- by_uid(mailbox.messages, uids),
         true <-
           String.upcase(action) in [
             "+FLAGS.SILENT",
             "-FLAGS.SILENT",
             "FLAGS.SILENT",
             "+FLAGS",
             "-FLAGS",
             "FLAGS"
           ],
         {:ok, flags} <- normalize_flags(flags) do
      messages =
        Enum.map(mailbox.messages, fn message ->
          if message in messages do
            flags =
              cond do
                String.starts_with?(action, "+") -> Enum.uniq(message.flags ++ flags)
                String.starts_with?(action, "-") -> message.flags -- flags
                true -> flags
              end

            %{message | flags: flags}
          else
            message
          end
        end)

      {status(tag, :ok), session,
       put_in(state.mailboxes[session.selected], %{mailbox | messages: messages})}
    else
      _ -> {status(tag, :bad), session, state}
    end
  end

  defp selected_command(kind, tag, [uids, destination], mailbox, session, state, _)
       when kind in [:copy, :move] do
    with {:ok, messages} <- by_uid(mailbox.messages, uids),
         {:ok, target} <- Map.fetch(state.mailboxes, text(destination)) do
      {copied, next} =
        Enum.map_reduce(messages, target.uid_next, fn message, uid ->
          {%{message | uid: uid}, uid + 1}
        end)

      target = %{target | messages: target.messages ++ copied, uid_next: next}
      state = put_in(state.mailboxes[text(destination)], target)

      state =
        if kind == :move do
          current = Map.fetch!(state.mailboxes, session.selected)

          put_in(state.mailboxes[session.selected], %{
            current
            | messages: Enum.reject(current.messages, &(&1 in messages))
          })
        else
          state
        end

      {status(tag, :ok), session, state}
    else
      :error -> {status(tag, :no, "TRYCREATE"), session, state}
      _ -> {status(tag, :bad), session, state}
    end
  end

  defp selected_command(:expunge, tag, [uids], mailbox, session, state, _) do
    case by_uid(mailbox.messages, uids) do
      {:ok, messages} ->
        removed = Enum.filter(messages, &("\\Deleted" in &1.flags))

        {lines, _} =
          Enum.map_reduce(mailbox.messages, 1, fn message, index ->
            if message in removed,
              do: {["* ", to_string(index), " EXPUNGE\r\n"], index},
              else: {[], index + 1}
          end)

        mailbox = %{mailbox | messages: mailbox.messages -- removed}
        {[lines, status(tag, :ok)], session, put_in(state.mailboxes[session.selected], mailbox)}

      :error ->
        {status(tag, :bad), session, state}
    end
  end

  defp selected_command(_, tag, _, _, session, state, _) do
    {status(tag, :bad), session, state}
  end

  defp normalize_flags(flags) do
    if Enum.all?(flags, fn
         flag when is_binary(flag) ->
           Regex.match?(~r/^(?:\\(?:Seen|Answered|Flagged|Deleted|Draft)|[A-Za-z0-9_-]+)$/i, flag)

         _ ->
           false
       end) do
      {:ok, flags |> Enum.map(&canonical_flag/1) |> Enum.uniq()}
    else
      :error
    end
  end

  defp canonical_flag(flag) do
    case String.downcase(flag) do
      "\\seen" -> "\\Seen"
      "\\answered" -> "\\Answered"
      "\\flagged" -> "\\Flagged"
      "\\deleted" -> "\\Deleted"
      "\\draft" -> "\\Draft"
      "\\recent" -> "\\Recent"
      keyword -> keyword
    end
  end

  defp valid_fetch_items?(items) do
    items != [] and
      Enum.all?(items, fn
        item when is_binary(item) ->
          String.upcase(item) in [
            "UID",
            "FLAGS",
            "ENVELOPE",
            "BODYSTRUCTURE",
            "INTERNALDATE",
            "RFC822.SIZE"
          ] or
            Regex.match?(
              ~r/^BODY\.PEEK\[(?:|HEADER|TEXT|[1-9][0-9]*(?:\.[1-9][0-9]*)*(?:\.MIME|\.HEADER|\.TEXT)?|HEADER\.FIELDS \([A-Za-z0-9 -]+\))\]$/i,
              item
            )

        _ ->
          false
      end)
  end

  defp fetch_line(message, index, items, omitted) do
    body? = body_fetch_items?(items)

    if (omitted == :body and body?) or (omitted == :metadata and not body?) do
      []
    else
      fields =
        Enum.map(items, fn item ->
          case String.upcase(item) do
            "UID" ->
              ["UID ", to_string(message.uid)]

            "FLAGS" ->
              ["FLAGS (", Enum.join(message.flags, " "), ")"]

            "ENVELOPE" ->
              ["ENVELOPE (", message.envelope, ")"]

            "BODYSTRUCTURE" ->
              ["BODYSTRUCTURE (", message.bodystructure, ")"]

            "INTERNALDATE" ->
              ["INTERNALDATE ", quote_string(message.internal_date)]

            "RFC822.SIZE" ->
              ["RFC822.SIZE ", to_string(byte_size(Map.get(message.sections, "", "")))]

            _ ->
              section = binary_part(item, 10, byte_size(item) - 11)

              body =
                cond do
                  String.upcase(section) == "HEADER" ->
                    message.headers

                  String.starts_with?(String.upcase(section), "HEADER.FIELDS") ->
                    header_fields(message.headers, section)

                  true ->
                    Map.get(message.sections, section)
                end

              if is_binary(body) do
                ["BODY[", section, "] {", to_string(byte_size(body)), "}\r\n", body]
              else
                ["BODY[", section, "] NIL"]
              end
          end
        end)

      fields =
        if Enum.any?(items, &(String.upcase(&1) == "UID")),
          do: fields,
          else: [["UID ", to_string(message.uid)] | fields]

      [["* ", to_string(index), " FETCH (", Enum.intersperse(fields, " "), ")\r\n"]]
    end
  end

  defp header_fields(headers, section) do
    [_, fields] = Regex.run(~r/\(([^)]+)\)/, section)
    fields = fields |> String.upcase() |> String.split(" ", trim: true)
    lines = headers |> String.split("\r\n") |> Enum.take_while(&(&1 != ""))

    blocks =
      Enum.reduce(lines, [], fn line, blocks ->
        if String.starts_with?(line, [" ", "\t"]) and blocks != [] do
          [previous | rest] = blocks
          [previous <> "\r\n" <> line | rest]
        else
          [line | blocks]
        end
      end)

    selected =
      blocks
      |> Enum.reverse()
      |> Enum.filter(fn block ->
        block |> String.split(":", parts: 2) |> hd() |> String.upcase() |> then(&(&1 in fields))
      end)

    Enum.map_join(selected, "", &(&1 <> "\r\n")) <> "\r\n"
  end

  defp by_uid(messages, set, maximum \\ nil)

  defp by_uid(messages, set, maximum) when is_binary(set) do
    maximum = maximum || Enum.reduce(messages, 1, &max(&1.uid, &2))
    parts = String.split(set, ",")

    if valid_uid_set?(set) do
      {:ok,
       Enum.filter(messages, fn message ->
         Enum.any?(parts, fn part ->
           numbers =
             part
             |> String.split(":")
             |> Enum.map(fn
               "*" -> maximum
               value -> String.to_integer(value)
             end)

           case numbers do
             [uid] -> message.uid == uid
             [first, last] -> message.uid >= min(first, last) and message.uid <= max(first, last)
           end
         end)
       end)}
    else
      :error
    end
  end

  defp by_uid(_, _, _) do
    :error
  end

  defp valid_uid_set?(set) do
    set
    |> String.split(",")
    |> Enum.all?(fn part ->
      Regex.match?(~r/^(?:[1-9][0-9]*|\*)(?::(?:[1-9][0-9]*|\*))?$/, part) and
        Enum.all?(String.split(part, ":"), fn
          "*" -> true
          value -> String.to_integer(value) <= @max_uid
        end)
    end)
  end

  defp search_mailbox(messages, criteria) do
    # `maximum` is the UID that `*` names.
    scope = %{maximum: Enum.reduce(messages, 1, &max(&1.uid, &2))}

    case criteria do
      [prefix, charset | rest] when is_binary(prefix) and is_binary(charset) ->
        if String.upcase(prefix) == "CHARSET" do
          if String.upcase(charset) in ["UTF-8", "US-ASCII"] and rest != [],
            do: search(messages, rest, scope),
            else: :error
        else
          search(messages, criteria, scope)
        end

      _ ->
        search(messages, criteria, scope)
    end
  end

  defp search(messages, [], _scope) do
    {:ok, messages}
  end

  defp search(messages, [criterion | rest], scope) when is_binary(criterion) do
    case String.upcase(criterion) do
      "ALL" ->
        search(messages, rest, scope)

      "UNSEEN" ->
        search(Enum.reject(messages, &("\\Seen" in &1.flags)), rest, scope)

      key when key in ["FROM", "SUBJECT", "TEXT"] ->
        search_text(messages, key, rest, scope)

      key when key in ["SINCE", "BEFORE"] ->
        search_date(messages, key, rest, scope)

      "UID" ->
        case rest do
          [set | rest] ->
            with {:ok, messages} <- by_uid(messages, set, scope.maximum),
                 do: search(messages, rest, scope)

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp search(_, _, _) do
    :error
  end

  defp search_text(messages, key, [value | rest], scope)
       when is_binary(value) or is_tuple(value) do
    needle = String.downcase(text(value))

    filtered =
      Enum.filter(messages, fn message ->
        haystack =
          case key do
            "TEXT" ->
              message.headers <> message.envelope <> Enum.join(Map.values(message.sections), " ")

            _ ->
              case Regex.run(~r/^#{key}:\s*(.*)$/im, message.headers, capture: :all_but_first) do
                [value] -> value
                _ -> envelope_text(message.envelope, key)
              end
          end

        String.contains?(String.downcase(haystack), needle)
      end)

    search(filtered, rest, scope)
  end

  defp search_text(_, _, _, _) do
    :error
  end

  defp envelope_text(envelope, key) do
    case Peer.parse("(" <> envelope <> ")") do
      {:ok, [fields]} when is_list(fields) ->
        case {key, Enum.at(fields, if(key == "SUBJECT", do: 1, else: 2))} do
          {"SUBJECT", value} when is_binary(value) and value != "NIL" ->
            value

          {"FROM", addresses} when is_list(addresses) ->
            Enum.map_join(addresses, " ", fn
              [name, _, mailbox, host] when is_binary(mailbox) and is_binary(host) ->
                if is_binary(name),
                  do: name <> " " <> mailbox <> "@" <> host,
                  else: mailbox <> "@" <> host

              _ ->
                ""
            end)

          _ ->
            ""
        end

      _ ->
        ""
    end
  end

  defp search_date(messages, key, [value | rest], scope) when is_binary(value) do
    with {:ok, target} <- date(value) do
      filtered =
        Enum.filter(messages, fn message ->
          case date(message.internal_date |> String.split(" ") |> hd()) do
            {:ok, date} ->
              if key == "SINCE",
                do: Date.compare(date, target) != :lt,
                else: Date.compare(date, target) == :lt

            _ ->
              false
          end
        end)

      search(filtered, rest, scope)
    end
  end

  defp search_date(_, _, _, _) do
    :error
  end

  defp date(value) do
    case Regex.run(~r/^(\d{1,2})-([A-Za-z]{3})-(\d{4})$/, value) do
      [_, day, month, year] ->
        months = ~w(jan feb mar apr may jun jul aug sep oct nov dec)

        case Enum.find_index(months, &(&1 == String.downcase(month))) do
          nil ->
            :error

          month ->
            case Date.new(String.to_integer(year), month + 1, String.to_integer(day)) do
              {:ok, date} -> {:ok, date}
              {:error, _} -> :error
            end
        end

      _ ->
        :error
    end
  end

  defp sasl_step(
         line,
         %{sasl: %{tag: tag, mechanism: mechanism, stage: :response}} = session,
         state
       ) do
    session = %{session | sasl: nil}

    case {mechanism, Base.decode64(line)} do
      {"PLAIN", {:ok, decoded}} ->
        case String.split(decoded, <<0>>) do
          [_authzid, username, password]
          when username == state.username and password != "" ->
            if password in [state.password | state.passwords] do
              {status(tag, :ok), %{session | authenticated: true}}
            else
              {status(tag, :no, "AUTHENTICATIONFAILED"), session}
            end

          _ ->
            {status(tag, :no, "AUTHENTICATIONFAILED"), session}
        end

      {"XOAUTH2", {:ok, decoded}} ->
        if decoded == "user=#{state.username}\x01auth=Bearer #{state.access_token}\x01\x01" do
          {status(tag, :ok), %{session | authenticated: true}}
        else
          # As real servers do: a JSON error report in a challenge, then NO after the
          # client's empty response.
          error = Base.encode64(~s|{"status":"401","schemes":"Bearer","scope":"imap"}|)

          {{:sasl, "+ #{error}\r\n"},
           %{session | sasl: %{tag: tag, mechanism: mechanism, stage: :error_ack}}}
        end

      _ ->
        {status(tag, :bad), session}
    end
  end

  defp sasl_step("", %{sasl: %{tag: tag, stage: :error_ack}} = session, _state) do
    {status(tag, :no, "AUTHENTICATIONFAILED"), %{session | sasl: nil}}
  end

  defp sasl_step(_line, %{sasl: %{tag: tag}} = session, _state) do
    {status(tag, :bad), %{session | sasl: nil}}
  end

  defp text({:literal, value}) do
    value
  end

  defp text(value) when is_binary(value) do
    value
  end

  defp text(_) do
    nil
  end

  defp quote_string(value) do
    "\"" <> (value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")) <> "\""
  end

  defp status(tag, kind, code \\ nil) do
    [
      tag,
      " ",
      kind |> Atom.to_string() |> String.upcase(),
      if(code, do: " [#{code}]", else: ""),
      " completed\r\n"
    ]
  end

  @impl true
  def handle_info({:DOWN, _, :process, peer, _}, state) do
    {:noreply, %{state | peers: Map.delete(state.peers, peer)}}
  end

  def handle_info({:EXIT, acceptor, reason}, %{acceptor: acceptor} = state) do
    {:stop, reason, state}
  end

  @impl true
  def terminate(_, state) do
    :gen_tcp.close(state.listener)
    Enum.each(state.peers, fn {peer, _} -> send(peer, :close) end)
    :ok
  end

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:log, _value} -> {:log, []}
      {key, _value} -> {key, :redacted_fake_imap_server}
    end)
  end
end
