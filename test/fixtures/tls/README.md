# Loopback TLS test fixtures

These are throwaway test identities, never production credentials. The private
keys are public fixtures and will match secret scanners' private-key patterns;
that is expected. The CA is trusted only by individual loopback tests,
never installed in the operating system or application configuration.

Created with OpenSSL 4.1.0 on 2026-11-02. Certificates expire 2036-10-31.
`localhost.pem` has DNS SAN `localhost` and IP SAN `127.0.0.1`;
`dns-only.pem` has only DNS SAN `localhost`; `wrong-host.pem` has DNS SAN
`wrong.example.test`. All use RSA 2048 / SHA-256.
The CA signing key and CSRs are not committed.

To regenerate, run in a new temporary directory; generate a self-signed CA with
`openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650`, subject
`/CN=IMAP client test CA - no production use`, and extensions
`basicConstraints=critical,CA:TRUE` and
`keyUsage=critical,keyCertSign,cRLSign`. Generate each leaf key/CSR with
`openssl req -new -newkey rsa:2048 -nodes -sha256 -subj /CN=localhost`
(use `/CN=wrong.example.test` for the wrong-host leaf).
Sign each CSR with `openssl x509 -req -CA ca.pem -CAkey ca-key.pem`, serials
1, 2 and 3, `-days 3650 -sha256`, and these extensions in `-extfile`:

```text
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost,IP:127.0.0.1
```

Use only `DNS:localhost` for the DNS-only certificate and
`DNS:wrong.example.test` for the wrong-host certificate. Review the generated
certificate subjects, validity and SANs before replacing the fixture PEM files.
