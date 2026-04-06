# Lab 4 — Notes

WireGuard tunnel with Docker for the daemon peer. The patent names WireGuard
explicitly — the pkey is the durable identity anchor, survives NAT and roaming
where the 4-tuple doesn't.

Running both peers on the same Mac fails. Kernel sees 10.0.0.2 as LOCAL, routes
the packet directly without entering the tunnel — encryption never happens. Linux
solves this with network namespaces. macOS has none. Fix: daemon runs in a Docker
container with a separate network stack. Traffic has to physically traverse the
Docker bridge, get encrypted by WireGuard on the Mac side, arrive as UDP at the
mapped port, get decrypted inside the container.

Dual capture is the point. Physical interface (lo0/Docker bridge): encrypted UDP
blobs, {src_udp, dst_udp, udp_len, timestamp}, no TCP headers, no ISNs, no payload.
Tunnel interface (utun/wg0): full TCP handshake, ISNs, window sizes, cleartext
payload. Same traffic, two completely different views. The relay only ever sees
the first one.

NAT simulation with pfctl: insert a rewrite rule mid-session changing port 51820
to 61820. 4-tuple changes. Tunnel re-establishes on the same pkey — identity is
continuous across the roam event. The trust engine queries: did ambient factors
change? Did the clock progress? Is the geo plausible? Those answers determine
whether it's a legitimate roam or a hijack.

Config filename gotcha: wg-quick requires the config filename to be a valid
interface name. Hyphens aren't valid. wg-daemon.conf fails with "must be a valid
interface name." Use wg0.conf. Endpoint addressing: agent points to
127.0.0.1:51821 (Docker-mapped), daemon uses host.docker.internal:51820.

