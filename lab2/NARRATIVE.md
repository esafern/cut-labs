# Lab 2 — Notes

Built the two-session relay split from FIG.1: mitmproxy as the middlebox, openssl s_server as the daemon, curl and MTLSClient.java as the agent. mTLS on both legs — the proxy terminates the inbound TLS connection and opens a separate outbound one.

Four independent ISNs in the successful capture at 22:34:43: client SYN 2119267439, proxy SYN-ACK 352821909, proxy SYN to server 3124223121, server SYN-ACK 3627862714.  Complete ISN break at the proxy boundary. The agent sees one pair, the daemon sees another, neither can correlate without relay internal state.

Proxy latency: 1.4ms between client SYN (22:34:43.249187) and proxy SYN to server (22:34:43.250623). That's TLS termination + cert lookup + new connection. A DPI engine at this position adds more. The trust engine sees this as an inter-packet gap in the telemetry stream.

Two failed connections at 22:32:12 before the fix — mitmproxy connected to the server but didn't present a client cert. Server rejected with tlsv13 alert certificate required. Visible in telemetry as SYN pairs that never establish.

Main gotchas: macOS resolves localhost to ::1 before 127.0.0.1 — tcpdump on lo0 captures IPv4 only, so the proxy's upstream connections disappeared. Fixed by using explicit 127.0.0.1 everywhere. Second issue: mitmproxy's directory mode looks up client certs by upstream hostname. Changed upstream from localhost to 127.0.0.1 and forgot to rename the cert file to match.

MTLSClient.java demonstrates the same thing with Java's SSL stack — KeyManagerFactory for the client cert, TrustManagerFactory for the CA, SSLSocket with startHandshake().  Reports TLSv1.3, cipher suite, and server CN. The pattern any Java service would use to authenticate to a mTLS endpoint.
