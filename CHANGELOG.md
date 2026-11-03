# Changelog

## 0.1.0

First release: an IMAP client with implicit TLS (verified chain and hostname),
LOGIN, AUTHENTICATE PLAIN and XOAUTH2, SELECT/EXAMINE, STATUS, NOOP, UID SEARCH,
FETCH, STORE, COPY, MOVE and UID EXPUNGE, LIST with SPECIAL-USE, APPEND with flags
and an internal date, and IDLE; session helpers for search, read, move, flags,
folders and attachment download with BODYSTRUCTURE and MIME decoding; a pluggable
charset decoder; and a wire-level fake IMAP server for tests.
