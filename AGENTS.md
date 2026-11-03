# imap_client

An open source Elixir library: an IMAP client with a wire-level fake IMAP server for
tests. MIT licensed. `CLAUDE.md` is a symlink to this file.

## This repository is public

Everything here is published: code, docs, tests, test data, commit messages and branch
names. Never put in any of them:

- secrets of any kind (keys, tokens, passwords, real session cookies), even expired;
- internal or proprietary information about any company, product, customer, agent or
  person, including private repository names, internal names, account IDs, internal
  paths and hostnames;
- real email addresses, personal data or real mail. Use `example.com` / `example.test`
  addresses and synthetic messages.

Test data is synthetic. The TLS keys in `test/fixtures/tls` are throwaway test
fixtures (see the README there). Write docs and commit messages for an outside reader;
explain behavior, not an internal project's needs. Before every push, scan the diff
and the new commits for the above.

## API

The public API is `IMAPClient`, `IMAPClient.Error`, `IMAPClient.CharsetDecoder` and
`IMAPClient.FakeServer`, as `README.md` and their `@doc`s describe. Every other module
is internal (`@moduledoc false`). A new capability is a design decision: keep it small,
document it in the README, test it, and bump the version (CHANGELOG, `mix.exs`, a
`vX.Y.Z` tag).

## Invariants

- Keep literal handling byte-oriented. Never parse payload bytes as protocol lines.
- Only the current command's tag owns a completion. A tagged NO or BAD keeps the
  connection usable (except a failed IDLE DONE); malformed protocol, transport failure
  or a deadline poisons it.
- A mutation that timed out or lost its connection has an unknown outcome and is never
  retried. The only retry is a session sign-in whose greeting or authentication timed
  out, once, before any mailbox is touched.
- Never issue plain EXPUNGE; it could remove other clients' deleted messages.
- Never log server text, credentials, envelope fields or message data, and keep them
  out of errors and process state dumps (`format_status`).
- The fake server parses and enforces the server side independently of the client's
  codec. It binds to 127.0.0.1 only. Tests never contact real mail servers.

## Code style

- `do...end` for every `def` and `defp`, never the `, do:` keyword form. One module
  per file. One alias per line, no `alias A.{B, C}`.
- Expected failures are returned as values (`{:error, ...}`), not raised. Raise only for
  programming errors, such as invalid `start_link/1` options.
- `try`/`rescue`/`catch` is rare, and each one has a comment naming its reason, such as
  crossing a process boundary or cleanup that must run before a failure propagates.
- Few dependencies, each justified in `mix.exs`. Today there are none, at runtime or in
  tests. Simplicity first: no retries, timers or fallbacks for rare failures beyond the
  ones documented above; tell the caller instead.
- Stock `mix format`; `mix compile --warnings-as-errors` and `mix test` pass before every
  commit. No hosted CI; tests run locally.

## Tests

- One layer per test, through the module's public interface, with the module under test
  `import`ed and called unqualified. Public behavior is tested through `IMAPClient`;
  an internal module's own tests (the framer, parsers) assert only its own results.
- Async by default. A sync module names its one reason in a comment above
  `use ExUnit.Case`.
- No `capture_log` in async tests.
- No peeking at internals (`:sys.get_state`, internal fields) and no planting state the
  API can't produce. `:sys.get_status` is fine for checking that `format_status` hides
  credentials, since that is the public view of a process.
- Small tests, one behavior each; tables for cases on one code path.

Two exceptions this library allows, with their reasons:

- Catching failures of application-supplied callbacks (`:on_diagnostic`, the charset
  decoder) and logging a fixed warning without their contents is fine: that code is
  outside the library's control, and its failure must not change an IMAP result.
- Tests may feed malformed or hostile server responses through the scripted peers and
  the fake, since the server is external and the client must survive its bad data.

## Commits

Normal commits only: no amend, rebase or force-push on `main`.
