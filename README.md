# IMAPClient

An IMAP client for Elixir, built to stay correct when the server or the network
doesn't: verified TLS, byte-counted literals, bounded responses, whole-stage
deadlines, cancellation, and errors that never echo server text or credentials. It
comes with a wire-level fake IMAP server for your tests.

It has two layers:

- **Connections**: a process per connection that you own and drive command by
  command, including IDLE. Good for long-lived sessions such as a new-mail watcher.
- **Sessions**: one call that opens a connection, signs in, does one job (search,
  read, move, flag, list folders, append, download an attachment) and always logs out
  and closes.

No runtime dependencies beyond OTP's `:ssl`.

## Installation

IMAPClient isn't on Hex yet. Add it as a git dependency pinned to a tag:

```elixir
def deps do
  [
    {:imap_client, git: "https://github.com/pguillory/imap_client.git", tag: "v0.1.0"}
  ]
end
```

Requires Elixir 1.18 or later on OTP 27 or later.

## Sessions

A session config is the server plus credentials:

```elixir
config = %{host: "imap.example.com", username: "me@example.com", password: "app-password"}

{:ok, %{results: results, unreturned: 0}} =
  IMAPClient.search(config, %{from: "alice@example.com", since: "1-Oct-2026", limit: 20})

{:ok, %{kind: :found, email: email}} = IMAPClient.read(config, hd(results).uid)
email.envelope.subject
email.text_body

{:ok, %{missing_uids: []}} = IMAPClient.mark_read(config, [hd(results).uid])
{:ok, %{missing_uids: [], unpurged_uids: []}} = IMAPClient.move(config, [42], "Archive")
:ok = IMAPClient.append(config, "Drafts", raw_message, flags: ["\\Seen", "\\Draft"])
```

Credentials, one of:

- `username` and `password`: LOGIN.
- `auth: :plain` with `username` and `password`: AUTHENTICATE PLAIN.
- `auth: :xoauth2` with `username` and `access_token`: AUTHENTICATE XOAUTH2, for
  Gmail and Microsoft 365. Your application obtains and refreshes the OAuth 2.0 token;
  a refused token returns an error with code `:auth_rejected`.

Other session options: `port` (default 993, or 143 without TLS), `use_tls` (default
true; plain TCP needs an explicit `false` and sends credentials in cleartext, so use it
only for a local test server), `cacertfile` (a CA bundle to trust instead of the OS store;
verification can't be turned off), `retry_sign_in` (default true: a sign-in whose
greeting or authentication timed out is retried once, before any mailbox is touched),
`connection_options` (see `IMAPClient.start_link/1`), `charset_decoder` (see
[Character sets](#character-sets)) and `on_diagnostic`.

Helpers: `search/2`, `read/3`, `read_many/3`, `move/4`, `mark_read/3`,
`mark_unread/3`, `add_flags/4`, `remove_flags/4`, `list_folders/1`,
`list_special_use_folders/1`, `append/4`, `download_attachment/5` and
`test_connection/1`. A move uses MOVE when the server has it, otherwise COPY, `\Deleted`
and UID EXPUNGE of just those UIDs. Plain EXPUNGE is never sent, because it could
remove other clients' deleted messages.

## Connections

```elixir
{:ok, conn} = IMAPClient.start_link()
:ok = IMAPClient.connect(conn, %{host: "imap.example.com"})
:ok = IMAPClient.authenticate(conn, :xoauth2, "me@example.com", token)
{:ok, %{messages: 12, unseen: 3}} = IMAPClient.status(conn, "INBOX", [:messages, :unseen])
{:ok, %{uid_validity: _, uid_next: next}} = IMAPClient.examine(conn, "INBOX")
{:ok, uids} = IMAPClient.search_uids(conn, "SINCE #{IMAPClient.search_date(since_ms)}")
{:ok, %{envelopes: envelopes}} = IMAPClient.fetch_envelopes(conn, uids)

{:ok, ref} = IMAPClient.start_idle(conn)
receive do
  {:imap_idle, ^ref, {:update, line}} -> line   # e.g. "* 13 EXISTS"
end
:ok = IMAPClient.end_idle(conn)
{:ok, _lines} = IMAPClient.noop(conn)

:ok = IMAPClient.logout(conn)
IMAPClient.close(conn)
```

`close/1` closes the socket but leaves the connection process running, unusable, until
its owner exits; stop it with `GenServer.stop/1` or run it under a supervisor.
`IMAPClient.open_signed_in/2` and `close_signed_in/1` do the connect, sign-in and
cleanup for you with a session config.

Behavior worth knowing:

- A connection runs one command at a time. An overlapping command, or anything but
  `end_idle/1`, `close/1` and `live?/1` during IDLE, returns a `:busy` error.
- Each stage has a deadline (connect, greeting, authentication, command, body fetch,
  append, logout), configurable with `start_link(timeouts: ...)`. Calls never hit
  GenServer's five-second default.
- The connection monitors its owner and the current caller. If the owner dies the
  connection stops; if a caller or IDLE subscriber dies the connection is closed.
- A timeout, protocol error or closed socket poisons the connection: it closes and
  stays unusable. A tagged NO or BAD leaves it usable.
- A failed mutation (STORE, COPY, MOVE, EXPUNGE, APPEND) that timed out or lost its
  connection has `outcome_unknown?: true`. The server may have done it, so don't retry
  it automatically. The client never retries a command itself.
- During IDLE the client never sends anything on its own. Re-IDLE every 25 minutes or
  so, and use `noop/1` if you need to detect a dead connection.
- Mailbox names are Unicode in both directions; the client converts to and from
  modified UTF-7.
- `search_uids/2`, `search_strict/2` and the other connection commands that take
  criteria pass raw IMAP syntax through. Don't build it from untrusted input; use the
  session `search/2`, which quotes and validates every field.
- BODY literals are capped at 64 MiB by default (`max_body_literal_bytes`); other
  literals and response lines at 1 MiB.

Errors are `%IMAPClient.Error{}` with a `code` (such as `:auth_rejected`, `:timeout`,
`:closed`, `:no`, `:bad`, `:mailbox_no`, `:busy`, `:protocol`), the `stage`, and for
refusals an allowlisted `response_code` and a coarse `hint`. Server text is never
included, because servers echo usernames and sometimes passwords in it. Envelope text,
file names and the `other_lines` some results carry are untrusted data from senders or
the server: don't log them.

## Character sets

The client decodes UTF-8, US-ASCII and Latin-1 (as Windows-1252, as browsers do) by
itself. A text body in any other charset comes back raw, as
`%{charset: "Shift_JIS", bytes: <<...>>}`, an RFC 2047 encoded word in an unknown
charset is left as its encoded payload (`=?x-unknown?B?SGk=?=` becomes `SGk=`), and an RFC 2231 file name falls back to lossy UTF-8.

For full coverage, add a decoder. For example, with
[`encoding_rs`](https://hex.pm/packages/encoding_rs) (a Rust NIF covering the WHATWG
Encoding set):

```elixir
defmodule MyApp.CharsetDecoder do
  @behaviour IMAPClient.CharsetDecoder

  @impl true
  def decode(bytes, label) do
    with {:ok, encoding} <- EncodingRs.canonical_name(label),
         true <- encoding != "replacement",
         {:ok, text} <- EncodingRs.decode(bytes, encoding) do
      {:ok, text}
    else
      _ -> :error
    end
  end
end

config = Map.put(config, :charset_decoder, MyApp.CharsetDecoder)
```

(`EncodingRs.decode/2` lets a byte-order mark override the declared charset, as
browsers do.) Pass the same module as `charset_decoder:` to
`IMAPClient.fetch_envelopes/3`. A decoder that raises is treated as returning
`:error`, with a fixed warning logged.

## The fake server

`IMAPClient.FakeServer` is an IMAP server for tests and development. It listens on
127.0.0.1, holds mailboxes in memory, parses the server side of the protocol
independently of the client, and enforces authentication, mailbox selection and
capabilities. Your code talks to it over a real socket through the real client.

```elixir
server =
  start_supervised!(
    {IMAPClient.FakeServer,
     mailboxes: %{
       "INBOX" => %{
         messages: [
           %{
             uid: 1,
             envelope: ~s|NIL "Hello" (("Ann" NIL "ann" "example.test")) NIL NIL NIL NIL NIL NIL NIL|,
             bodystructure: ~s|"TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 5 1|,
             sections: %{"1" => "hello"}
           }
         ]
       }
     }}
  )

config = IMAPClient.FakeServer.endpoint(server)
{:ok, %{email: %{text_body: "hello"}}} = IMAPClient.read(config, 1)
```

It can also script failures for the next matching command (stall, close, refuse with
a response code, omit data, hold the response until released, add or remove a message
first), push IDLE updates, queue untagged responses, and report the commands it
received (without credentials or message content). See the `IMAPClient.FakeServer`
docs.

## Testing and status

This is version 0.1. It is tested against its own fake server and against scripted
loopback peers that pin the exact bytes on the wire, including TLS peers with test
certificates. It has not been tested against real mail providers yet.

Not supported: STARTTLS (port 143 upgrades), SASL-IR, OAUTHBEARER, CONDSTORE/QRESYNC,
ESEARCH, mailbox CREATE/DELETE/RENAME, and sequence-number (non-UID) commands.

## License

MIT. See [LICENSE](LICENSE).
