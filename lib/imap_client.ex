defmodule IMAPClient do
  @moduledoc """
  An IMAP client with verified TLS, byte-counted literals, IDLE and per-stage deadlines.

  There are two layers.

  **Connections.** `start_link/1` starts a connection process owned by the caller, then
  `connect/2`, `login/3` or `authenticate/4`, and the commands below. Commands return
  `:ok` or `{:ok, value}`; expected network and server failures return
  `{:error, %IMAPClient.Error{}}`. `close/1` closes the socket but leaves the unusable
  process; stop it with `GenServer.stop/1` or through its supervisor.

  A connection monitors its owner and the current caller. Owner death stops it; the
  death of a caller or IDLE subscriber poisons and closes it. A connection never retries a
  command and has no pool or reconnect policy. Overlapping commands, and any command other
  than `end_idle/1`, `close/1` or `live?/1` during IDLE, return a `:busy` error.

  Calls wait for whole-stage deadlines owned by the connection, never GenServer's
  default five-second timeout. An error after a mutation can have
  `outcome_unknown?: true`: the server may have done it, so don't retry automatically.

  Mailbox names are Unicode: LIST results are decoded from modified UTF-7, and SELECT,
  EXAMINE, STATUS, COPY, MOVE and APPEND encode them. Plain TCP needs an explicit
  `use_tls: false`; there is no STARTTLS.

  **Sessions.** The session helpers (`search/2`, `read/3`, `read_many/3`, `move/4`, the
  flag helpers, folder listing, `append/4` with a config and `download_attachment/5`) take
  a session config, open one connection, sign in, do their work, then always log out and
  close. The session config is the `connect/2` config plus:

  * credentials: `:username` and `:password` (LOGIN), `auth: :plain` with `:password`
    (AUTHENTICATE PLAIN), or `auth: :xoauth2` with `:access_token` (AUTHENTICATE XOAUTH2;
    the application obtains and refreshes the OAuth token);
  * `:retry_sign_in` - default true: a sign-in whose greeting or authentication timed
    out is retried once on a fresh connection, before any mailbox is touched;
  * `:connection_options` - `start_link/1` options;
  * `:charset_decoder` - a module implementing `IMAPClient.CharsetDecoder`;
  * `:on_diagnostic` - a one-argument function called in the session caller with
    `%{event: :signin_slow | :fetch_incomplete | :connection_test_failed, ...}` maps.
    A sign-in is reported as slow from `:slow_signin_ms` (default 5,000).
    Events contain no credentials but may carry untrusted server text in
    `:other_lines` and `:completion`; don't log those. A failing callback is caught and
    only a fixed warning is logged.
  """

  alias IMAPClient.Connection
  alias IMAPClient.Error
  alias IMAPClient.Session
  alias IMAPClient.SignIn
  alias IMAPClient.Envelopes

  @doc """
  Starts a caller-owned connection process without opening a socket.

  Options:
  * `:owner` - PID to monitor; defaults to the process calling `start_link/1`.
    Pass the test/caller PID explicitly when a supervisor starts the connection.
  * `:timeouts` - map/keyword of positive millisecond overrides: `:connect_ms`
    10,000, `:greeting_ms` 10,000, `:authentication_ms` 20,000, `:command_ms`
    30,000, `:body_fetch_ms` 60,000, `:append_ms` 120,000, `:logout_ms` 5,000.
    Unknown/nonpositive timeout entries raise `ArgumentError`.
  * `:max_body_literal_bytes` - largest BODY literal; default 64 MiB. Metadata
    literals and physical response lines are limited to 1 MiB.
  """
  defdelegate start_link(opts \\ []), to: Connection

  @doc false
  defdelegate child_spec(opts), to: Connection

  @doc """
  Opens the socket and reads its greeting. A connection may only connect once.

  Config is a map with `:host`, optional `:port` (993 TLS/143 TCP), `:use_tls`
  (default true) and `:cacertfile` (optional CA trust override, never a
  verification bypass). TLS validates the trust chain and hostname/IP SAN.
  Verified-TLS PREAUTH needs no LOGIN; plaintext PREAUTH is refused.
  """
  @spec connect(pid(), map()) :: :ok | {:error, Error.t()}
  def connect(connection, config) do
    call(connection, {:connect, config})
  end

  @doc "Authenticates with LOGIN; does nothing after a verified-TLS PREAUTH greeting."
  def login(connection, username, password) do
    call(connection, {:login, username, password})
  end

  @doc """
  Authenticates with SASL: `:plain` with a password, or `:xoauth2` with an OAuth 2.0
  access token the application obtained. Waits for the server's continuation before
  sending the initial response, so it works whether or not the server advertises
  SASL-IR. A refused token usually returns code `:auth_rejected` (a server that refuses
  with a bare NO and no recognizable reason gives `:no`). Does nothing after a
  verified-TLS PREAUTH greeting.
  """
  @spec authenticate(pid(), :plain | :xoauth2, String.t(), String.t()) ::
          :ok | {:error, Error.t()}
  def authenticate(connection, mechanism, username, secret) do
    call(connection, {:authenticate, mechanism, username, secret})
  end

  @doc """
  Sends NOOP and returns `{:ok, lines}`: the untagged responses the server sent with it,
  such as EXISTS or EXPUNGE. Useful as a keepalive between IDLEs. The lines are
  untrusted server text.
  """
  def noop(connection) do
    call(connection, :noop)
  end

  @doc """
  Runs STATUS on a mailbox without selecting it. `items` is a list of `:messages`,
  `:recent`, `:uid_next`, `:uid_validity` and `:unseen`. Returns `{:ok, map}` with the
  items the server reported.
  """
  def status(connection, mailbox, items \\ [:messages, :uid_next, :uid_validity, :unseen]) do
    call(connection, {:status, mailbox, items})
  end

  @doc "Sends LOGOUT, accepting the expected BYE. Always close afterwards, including on error."
  def logout(connection) do
    call(connection, :logout)
  end

  @doc "Closes and permanently invalidates the connection; safe to call repeatedly."
  def close(connection) do
    call(connection, :close)
    :ok
  end

  @doc "Returns whether the connection is usable, including while a command or IDLE is active."
  def live?(connection) do
    call(connection, :live?) == true
  end

  @doc "Returns `{:ok, MapSet.t()}` of uppercase capability strings."
  def capabilities(connection) do
    call(connection, :capabilities)
  end

  @doc "Selects a mailbox for subsequent operations; a rejected mailbox has code `:mailbox_no`."
  def select(connection, mailbox) do
    call(connection, {:select, mailbox})
  end

  @doc "Opens a read-only mailbox and returns `{:ok, %{uid_validity: n, uid_next: n, lines: lines}}`."
  def examine(connection, mailbox) do
    call(connection, {:examine, mailbox})
  end

  @doc "Runs UID SEARCH with command text or text/`{:literal, binary}` segments; returns UIDs."
  def search_uids(connection, criteria) do
    call(connection, {:search, criteria})
  end

  @doc "Runs UID SEARCH, returning a map with `uids: nil` if the server omitted SEARCH, plus lines/completion."
  def search_strict(connection, criteria) do
    call(connection, {:search_strict, criteria})
  end

  @doc "Fetches top-level metadata by UID; values are binaries/nil/nested lists, keyed by uppercase item names."
  def fetch(connection, uids, items) do
    call(connection, {:fetch, uids, items})
  end

  @doc "Fetches a BODY.PEEK section as raw bytes. Missing body is `:no_data`; NIL/empty body is an empty binary."
  def fetch_body(connection, uid, section) do
    call(connection, {:fetch_body, uid, section})
  end

  @doc "Fetches a raw BODY response with body bytes or `:missing`, non-FETCH other_lines and completion diagnostics."
  def fetch_body_response(connection, uid, section) do
    call(connection, {:fetch_body_response, uid, section})
  end

  @doc """
  Fetches ENVELOPE and INTERNALDATE for UIDs in the selected mailbox, read-only (neither
  sets \\Seen). Returns `{:ok, %{envelopes: map, other_lines: lines}}`.

  `envelopes` maps each requested UID to `%{uid, envelope, internal_date_ms}`, with the
  envelope shaped as in `search/2`. A UID is left out unless both its envelope and a
  parseable INTERNALDATE came back; it may have been withheld or expunged. Envelope text
  is untrusted sender text and may contain control characters. `other_lines` are the
  response's other untagged lines (such as EXISTS), untrusted server text. An empty UID
  list sends nothing. Option `:charset_decoder` decodes RFC 2047 words in the envelope,
  as in a session config. Errors are those of `fetch/3`.
  """
  def fetch_envelopes(connection, uids, opts \\ []) do
    Envelopes.fetch_envelopes(connection, uids, Keyword.get(opts, :charset_decoder))
  end

  @doc """
  Fetches only INTERNALDATE for UIDs in the selected mailbox, read-only. Returns
  `{:ok, %{dates: map, other_lines: lines}}`, where `dates` maps each requested UID whose
  parseable INTERNALDATE came back to Unix milliseconds. An empty UID list sends nothing.
  Errors are those of `fetch/3`.
  """
  def fetch_internal_dates(connection, uids) do
    Envelopes.fetch_internal_dates(connection, uids)
  end

  @doc """
  A day as an IMAP SEARCH date (`"5-Oct-2026"`, RFC 3501 date), taken in UTC from Unix
  milliseconds. SEARCH SINCE compares dates only, disregarding time and timezone.
  """
  def search_date(ms) do
    Envelopes.search_date(ms)
  end

  @doc "Stores flags on UIDs, with action `\"+\"`, `\"-\"` or `\"\"`; missing UIDs are server no-ops."
  def store(connection, uids, flags, action) do
    call(connection, {:store, uids, flags, action})
  end

  @doc "Copies UIDs to an existing mailbox. No retries; missing UIDs are server no-ops."
  def copy(connection, uids, mailbox) do
    call(connection, {:copy, uids, mailbox})
  end

  @doc "Runs UID MOVE; caller must first verify the server advertises MOVE."
  def move_uids(connection, uids, mailbox) do
    call(connection, {:move, uids, mailbox})
  end

  @doc "Expunges only the given UIDs; caller must verify UIDPLUS. Never issues plain EXPUNGE."
  def uid_expunge(connection, uids) do
    call(connection, {:expunge, uids})
  end

  @doc "Lists mailbox maps with name, flags and delimiter, including literal mailbox names."
  def list(connection) do
    call(connection, :list)
  end

  @doc "Lists SPECIAL-USE flags, falling back to ordinary LIST only after BAD under the same deadline."
  def list_special_use(connection) do
    call(connection, :list_special_use)
  end

  @doc """
  Appends a raw RFC 5322 message to a mailbox with a synchronizing literal, streamed in
  32 KiB writes. Pass a connection, or a session config to open, sign in and clean up one
  short-lived connection around it. Options: `:flags`, a list such as
  `["\\\\Seen", "\\\\Draft"]` (default none), and `:internal_date`, a `DateTime`.
  Returns `{:ok, %{uid: uid, uid_validity: validity}}`: the new message's UID and its
  mailbox's UIDVALIDITY from the server's APPENDUID (RFC 4315, servers that advertise
  UIDPLUS), or both `nil` when the tagged OK carries none, a UID set or a number
  outside 1..4294967295. They are never guessed from UIDNEXT.
  A timeout or closed connection has an unknown outcome: don't retry automatically.
  """
  def append(connection_or_config, mailbox, message, opts \\ [])

  def append(config, mailbox, message, opts) when is_map(config) do
    Session.append(config, mailbox, message, opts)
  end

  def append(connection, mailbox, message, opts) do
    call(connection, {:append, mailbox, message, opts})
  end

  @doc """
  Enters IDLE and returns `{:ok, ref}` after the continuation. Verify the server
  advertises IDLE first. The subscriber receives `{:imap_idle, ref, {:update,
  line}}`, then `:ended` or `{:error, error}` as the third tuple item.

  Entry and DONE completion have command deadlines. Active IDLE has no read
  deadline; the caller owns periodic re-IDLE/half-open detection policy. A dead
  subscriber immediately aborts the socket without LOGOUT.
  """
  def start_idle(connection, subscriber \\ self()) do
    call(connection, {:idle_start, subscriber})
  end

  @doc "Sends DONE, waits for the current IDLE completion, then allows another command."
  def end_idle(connection) do
    call(connection, :end_idle)
  end

  @doc """
  Signs in on a fresh connection for a long-lived session the caller drives, as the
  session helpers do: `{:ok, connection}` or `{:error, %IMAPClient.Error{}}`. The caller
  owns the connection and ends it with `close_signed_in/1`.

  Config is a session config. Options: `:retry` (default false) retries once after a
  greeting or authentication timeout; `:log_slow` (default false) reports slow (5 s or
  more), timed-out and retried attempts as `:signin_slow` diagnostics.
  """
  @spec open_signed_in(map(), keyword()) :: {:ok, pid()} | {:error, Error.t()}
  def open_signed_in(config, opts \\ []) do
    SignIn.open(config, opts)
  end

  @doc "Ends a connection from `open_signed_in/2`: LOGOUT while usable, then close and stop it."
  @spec close_signed_in(pid()) :: :ok
  def close_signed_in(connection) do
    SignIn.close(connection)
  end

  @doc "Tests one login; returns `%{ok: true}` or `%{ok: false, reason: :auth | :busy | :refused | :unreachable}`."
  defdelegate test_connection(config), to: Session

  @doc """
  Searches one session and returns `{:ok, %{results: results, unreturned: count}}`.
  Criteria: `:from`, `:subject`, `:keyword`, IMAP-date `:since`/`:until`,
  `:unread_only`, positive `:limit`, and `:folder` (INBOX by default).
  Results are highest UID first; omitted metadata is counted, never retried.

  Session config adds username and app password to the connect options.
  Optional `:connection_options` carries `start_link/1` options. Each session
  logs out any still-usable connection and always closes/stops it.
  """
  defdelegate search(config, criteria), to: Session

  @doc "Reads one UID; returns `{:ok, %{kind: :found, email: map}}` or a missing outcome with UID/reason."
  def read(config, uid, folder \\ "INBOX") do
    Session.read(config, uid, folder)
  end

  @doc "Reads UIDs in requested order over one session; missing reasons are `:gone`, `:withheld` or `:unchecked`."
  def read_many(config, uids, folder \\ "INBOX") do
    Session.read_many(config, uids, folder)
  end

  @doc "Moves existing UIDs and reports missing_uids/unpurged_uids; without MOVE/UIDPLUS copied originals remain Deleted."
  def move(config, uids, destination, source \\ "INBOX") do
    Session.move(config, uids, destination, source)
  end

  @doc "Marks existing UIDs Seen and returns `{:ok, %{missing_uids: uids}}`."
  def mark_read(config, uids, folder \\ "INBOX") do
    add_flags(config, uids, ["\\Seen"], folder)
  end

  @doc "Removes Seen from existing UIDs and reports missing UIDs."
  def mark_unread(config, uids, folder \\ "INBOX") do
    remove_flags(config, uids, ["\\Seen"], folder)
  end

  @doc """
  Adds flags (a list such as `["\\\\Answered"]`) to existing UIDs and returns
  `{:ok, %{missing_uids: uids}}`.
  """
  def add_flags(config, uids, flags, folder \\ "INBOX") do
    Session.mark(config, uids, folder, flags, "+")
  end

  @doc "Removes flags from existing UIDs and reports missing UIDs."
  def remove_flags(config, uids, flags, folder \\ "INBOX") do
    Session.mark(config, uids, folder, flags, "-")
  end

  @doc "Lists folders over a short-lived authenticated session."
  def list_folders(config) do
    Session.folders(config, false)
  end

  @doc "Lists folders with SPECIAL-USE flags over a short-lived authenticated session."
  def list_special_use_folders(config) do
    Session.folders(config, true)
  end

  @doc """
  Downloads and transfer-decodes a leaf MIME part, bounded by decoded max_bytes.
  Returns `{:ok, %{kind: :ok, content: binary, mime_type: type, filename: name}}`
  or kind `:not_found`, `:missing` (with reason), `:too_large` (with bytes).
  Malformed base64 returns `:malformed_content`. Login/SELECT and fatal protocol
  failures propagate. Filenames and MIME metadata remain untrusted sender data.
  """
  def download_attachment(config, uid, part_id, folder \\ "INBOX", max_bytes) do
    Session.download_attachment(config, uid, part_id, folder, max_bytes)
  end

  defp call(connection, operation) do
    Connection.request(connection, operation)
  catch
    # Crossing a process boundary: a connection process that is gone or exits during
    # the call is a closed connection. The exit term would also carry the call's
    # arguments, credentials included, into the caller's crash.
    :exit, _reason -> {:error, Error.new(:closed, call_stage(operation))}
  end

  defp call_stage({:login, _, _}) do
    :authentication
  end

  defp call_stage({:authenticate, _, _, _}) do
    :authentication
  end

  defp call_stage(operation) when is_tuple(operation) do
    case elem(operation, 0) do
      kind when kind in [:store, :copy, :move, :expunge, :append] -> kind
      _ -> nil
    end
  end

  defp call_stage(_) do
    nil
  end
end
