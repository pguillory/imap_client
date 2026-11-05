# Changelog

## 0.2.0

- Breaking: `append/4` returns `{:ok, %{uid: uid, uid_validity: validity}}` instead
  of `:ok`, from the tagged OK's APPENDUID response code (RFC 4315). Both are `nil`
  when the server sends none, or sends a UID set or an out-of-range number.

## 0.1.0

First release: an IMAP client with implicit TLS (verified chain and hostname),
LOGIN, AUTHENTICATE PLAIN and XOAUTH2, SELECT/EXAMINE, STATUS, NOOP, UID SEARCH,
FETCH, STORE, COPY, MOVE and UID EXPUNGE, LIST with SPECIAL-USE, APPEND with flags
and an internal date, and IDLE; session helpers for search, read, move, flags,
folders and attachment download with BODYSTRUCTURE and MIME decoding; a pluggable
charset decoder; and a wire-level fake IMAP server for tests.
