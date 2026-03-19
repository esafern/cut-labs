# Lab 2: mTLS Interception Proxy (The Relay/Middlebox)

## What We're Building

FIG.1 shows three components in a line: agent (104) → relay (114) → daemon (106).
All traffic passes through the relay. The relay terminates one connection and
opens another. This lab builds exactly that with openssl s_server as the daemon,
mitmdump as the relay, and curl/Java as the agent.

## What mTLS Means

Regular TLS: the client verifies the server's certificate. One-way trust. The
server doesn't know who the client is cryptographically.

mTLS (mutual TLS): both sides verify each other. The server demands a client
certificate during the TLS handshake. No cert, no connection.

In the patent, the agent authenticates to the core network at session setup with
`{user/pass/src/pkey}`. The client certificate is the cryptographic equivalent.
The daemon also authenticates independently. Neither authenticates directly to
the other — the relay mediates. This is the "continuous universal trust" model:
trust is between each entity and the core network, not between entities directly.

## The PKI Chain

We built a three-level Public Key Infrastructure:

**CA (ca.crt / ca.key)** — the trust root. Self-signed. Both server and client
certs are issued by this CA. In the patent, this is the core network's identity
infrastructure. Anyone with a cert signed by this CA is "registered" with the
core network.

**Server cert (server.crt)** — proves the daemon's identity. Key fields:
- `extendedKeyUsage = serverAuth` — can only be used as a server
- `subjectAltName = DNS:localhost, IP:127.0.0.1` — the SAN is critical. TLS
  clients reject connections where the hostname doesn't match the cert's SAN.
  Without it, `openssl s_client -connect localhost:8443` fails even if the
  cert is otherwise valid

**Client cert (client.crt)** — proves the agent's identity. Key fields:
- `extendedKeyUsage = clientAuth` — can only be used as a client
- When the server sets `-Verify 1`, it demands this cert during the TLS
  handshake. The 22:32:12 failures in our capture showed what happens without
  it: `tlsv13 alert certificate required`

**Java keystore** — the PKCS12 and JKS files are Java-specific wrappers around
the same cert/key material. `client.p12` holds the client cert + private key.
`truststore.jks` holds the CA cert. The `MTLSClient.java` loads both to establish
a Java SSLSocket with full mTLS.

## What the Proxy Does

mitmdump in reverse proxy mode sits at port 8080. When curl connects:

1. Accepts the inbound TLS connection from curl (client ↔ proxy session)
2. Opens a NEW outbound TLS connection to the server at 8443 (proxy ↔ server session)
3. Presents the client cert to the server on the outbound connection
4. Forwards traffic between the two sessions

These are two completely separate TCP connections. Two separate TLS handshakes.
Two separate sets of ISNs. The proxy decrypts from one side and re-encrypts to
the other.

## The IPv6 Problem

macOS resolves `localhost` to `::1` (IPv6) before `127.0.0.1` (IPv4). When
mitmdump was configured as `reverse:https://localhost:8443/`, it connected to
the server via IPv6. Our tcpdump filter was `tcp port 8443` on lo0, which on
macOS captures IPv4 loopback traffic. The IPv6 traffic went through a different
path. We captured zero packets on port 8443.

Fix: `reverse:https://127.0.0.1:8443/` forces IPv4. Lesson: on macOS, always
use explicit IP addresses in network configs. Never `localhost`.

## The Cert Filename Problem

mitmproxy's `--set client_certs=client_certs/` directory mode works by filename
lookup. When connecting to upstream host `X`, it looks for `client_certs/X.pem`.
We originally had `localhost.pem` but changed the upstream to `127.0.0.1`, so it
needed `127.0.0.1.pem`. Without the matching file, mitmdump connected but didn't
present a client cert. The server demanded one (`-Verify 1`), got nothing, and
sent `tlsv13 alert certificate required`.

## The ISN Output Explained

The successful connection at 22:34:43 shows four independent ISNs:

**Client ↔ Proxy (port 8080):**
```
Client SYN:     seq 2119267439   → curl's kernel generated this ISN
Proxy SYN-ACK:  seq 352821909    → mitmdump's kernel for the client-facing socket
```

**Proxy ↔ Server (port 8443):**
```
Proxy SYN:      seq 3124223121   → mitmdump's kernel for the server-facing socket
Server SYN-ACK: seq 3627862714   → openssl s_server's kernel
```

Four ISNs, all different, generated independently by four TCP stack instances.
The proxy creates a complete break in ISN continuity. The client thinks it's
talking to the server. The server thinks it's talking to the proxy. Neither
sees the other's ISN.

An attacker between agent and relay sees one set of ISNs. An attacker between
relay and daemon sees a completely different set. Neither can correlate the two
sides without access to the relay's internal state. That's the security property.

## The Timing Story

Client SYN at 22:34:43.249187. Proxy SYN to server at 22:34:43.250623.
Delta: 1.4 milliseconds.

That 1.4ms is the proxy's processing latency — TLS termination, cert lookup,
new connection establishment. A DPI engine in this position would add more latency
(inspecting the payload before forwarding). The trust engine sees this as an
inter-packet gap in the `{src/dest/len/timestamp}` stream. If that gap grows
over time, the intermediary is choking — which is exactly what Lab 3 simulates.

## The Port Numbers

Client used ephemeral port 53639 to connect to proxy port 8080. Proxy used
ephemeral port 53640 to connect to server port 8443. The ports are one apart
(53639, 53640) — the kernel assigned them sequentially because the connections
were created back-to-back. On a busy system these would not be sequential. The
port assignment pattern is itself an ambient factor.

## The Failed Connections

The capture also shows two failed connections at 22:32:12 — before we fixed the
cert filename. Two SYN pairs on port 8443 (mitmdump tried twice), both rejected
with `certificate required`. These are visible in the telemetry as connection
attempts that never establish — another trust signal (repeated authentication
failures from the same source).

## How This Maps to the Patent

The `{src/pkey/dest/timestamp/request_body_hash}` at FIG.2 step 7 is the daemon
telling the engine: "I received this request, here's my hash of it." The engine
compares with the relay's metadata to verify the relay didn't tamper. The ISN
break means the daemon can't verify anything about the client's original TCP
session — it has to trust the relay. The hash is the integrity check that
substitutes for end-to-end ISN continuity.

## openssl s_server Bind Address

`openssl s_server -accept 127.0.0.1:8443` still listens on IPv6 wildcard on
some macOS/LibreSSL versions. The bind address is unreliable. Control IPv4/IPv6
from the client side instead.

## The Java mTLS Client

`MTLSClient.java` demonstrates enterprise-grade mTLS with Java's SSL stack:
- Loads client cert + key from PKCS12 keystore via `KeyManagerFactory`
- Loads CA cert from JKS truststore via `TrustManagerFactory`
- Builds `SSLContext` with both, creates `SSLSocket`, does `startHandshake()`
- Reports protocol (TLSv1.3), cipher suite, and server certificate CN

This is how a real Java service (Kafka producer, Spring Boot app) would
authenticate to the CUT core network.
