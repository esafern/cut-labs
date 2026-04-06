# Lab 2 Lessons Learned

## IPv6 vs IPv4 localhost resolution on macOS

macOS resolves `localhost` to `::1` (IPv6) before `127.0.0.1` (IPv4). When
mitmdump was configured as `reverse:https://localhost:8443/`, it connected
via IPv6. tcpdump on lo0 captured IPv4 only, so the captures were empty.

Fix: always use explicit `127.0.0.1` in network configs on macOS. Never
`localhost`.

## mitmproxy client_certs directory mode

mitmproxy `--set client_certs=dir/` looks up `<upstream_hostname>.pem` by
exact hostname match. When upstream was `localhost`, it looked for
`localhost.pem`. After changing to `127.0.0.1`, it needed `127.0.0.1.pem`.

Symptom: `tlsv13 alert certificate required` — the proxy connected to the
server but didn't present a client cert.

Fix: create a .pem file named for every hostname you might connect to,
or use a single cert file instead of directory mode.

## openssl s_server ignores bind address

`openssl s_server -accept 127.0.0.1:8443` still listens on IPv6 wildcard
on some macOS/LibreSSL versions. The -accept flag with a bind address is
unreliable. The server accepts both IPv4 and IPv6 connections regardless.

Not a problem in practice — control IPv4/IPv6 from the client side instead.

## Two-session split timing

Client SYN to proxy: 22:34:43.249187
Proxy SYN to server: 22:34:43.250623
Delta: 1.4 ms — proxy processing latency (TLS termination + cert lookup + new connection).
A DPI engine in this position adds more latency. The trust engine detects
this as inter-packet gap growth in the telemetry stream.

## confluent CLI delimiter for keyed produce

BSD `sed` does not interpret `\t` as tab. `sed 's/\t/|/1'` matches literal
backslash-t, not a tab character. Use `awk -F'\t'` instead.

Also, `:` as delimiter breaks keys containing colons (e.g., `127.0.0.1:8443`).
Use `|` as delimiter with `awk -F'\t' '{print $1 "|" $2}'`.
