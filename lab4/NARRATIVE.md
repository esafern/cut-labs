# Lab 4: WireGuard Tunnel on macOS (The Patent's Relay)

## What We're Building

The patent names WireGuard explicitly as the relay implementation: "a relay 114
(such as Wireguard, a secure VPN protocol and tunneling software) through which
traffic flows pass." This lab stands up a WireGuard tunnel and demonstrates the
core security property: the relay sees only encrypted metadata, while the
endpoints see everything.

## What WireGuard Is

WireGuard is a kernel-level VPN protocol that does exactly one thing: encrypts
IP packets inside UDP and sends them to a peer. No certificate authorities, no
negotiation handshake, no cipher suite selection.

Each peer has a Curve25519 keypair. You put the peer's public key in your config,
they put yours in theirs. The tunnel is up. The entire codebase is ~4,000 lines
of C. Compare OpenVPN (~100K lines) or IPSec.

On macOS, WireGuard runs in userspace via `wireguard-go` (a Go implementation)
and creates `utun` interfaces. On Linux it's a kernel module.

## Why the Patent Uses WireGuard

The public key (pkey) is the identity anchor. The patent says the agent sends
`{user/pass/src/pkey}` at session setup, and the daemon uses the pkey to "both
decrypt the traffic and to validate that the traffic indeed originated from the
identity."

In WireGuard, every tunnel interface has exactly one keypair, and every peer is
identified by their public key — not by IP address, not by hostname, not by
certificate chain. If a user roams from WiFi to cellular, their IP changes but
the pkey stays constant. The tunnel re-establishes transparently.

This is why the 4-tuple is not a stable session key. NAT rewrites it. Mobile
roaming changes it. VPN reconnection changes it. The pkey survives all of these.

## The macOS LOCAL Routing Problem

Both WireGuard peers on the same Mac fails. Here's why:

When you assign `10.0.0.1` to utun4 and `10.0.0.2` to utun5, the kernel adds
routes for both. A packet destined for `10.0.0.2` hits the routing table and
finds `10.0.0.2` is LOCAL — it's an address on this machine. The kernel delivers
it directly via the local loopback path without ever entering the WireGuard
tunnel. The encryption never happens.

Linux solves this with network namespaces — you put each peer in a separate
namespace with its own routing table. macOS has no network namespaces.

The fix: put one peer inside a Docker container. Docker provides a separate
network stack. Traffic from the Mac to `10.0.0.2` inside the container must
actually traverse the Docker bridge network, get encrypted by WireGuard on
the Mac side, arrive as UDP at the container's mapped port, get decrypted by
WireGuard inside the container, and reach the application.

## The Architecture

```
Mac (agent)                    Docker container (daemon)
┌──────────────┐               ┌──────────────────┐
│ Application  │               │ nc listener      │
│     ↓        │               │     ↑             │
│ utun (10.0.0.1)              │ wg0 (10.0.0.2)   │
│     ↓        │               │     ↑             │
│ WireGuard    │               │ WireGuard         │
│ encrypt      │               │ decrypt           │
│     ↓        │               │     ↑             │
│ UDP :51820   │──────────────→│ UDP :51821        │
│ (physical)   │  Docker bridge│ (physical)        │
└──────────────┘               └──────────────────┘
```

## The Dual Capture

This is the money shot. Same traffic, two views:

**Physical interface** (lo0 / Docker bridge): Encrypted UDP packets between
the Mac's port 51820 and the container's port 51821. No TCP headers visible.
No ISNs. No payload. Just `{src_udp, dst_udp, udp_len, timestamp}`. This is
what the relay sees.

**Tunnel interface** (utun on Mac, wg0 in container): Full TCP handshake
between 10.0.0.1 and 10.0.0.2 with ISNs, window sizes, cleartext payload.
This is what the endpoints see after decryption.

The delta between these two views IS the patent's security architecture.
The relay extracts `{src/dest/len/timestamp}` from the encrypted side. The
trust engine scores based on metadata patterns. Content stays encrypted
end-to-end.

## Config File Naming

`wg-quick` requires the config filename to be a valid network interface name
followed by `.conf`. Hyphens are not valid in interface names on Linux.
`wg-daemon.conf` produces: "The config file must be a valid interface name."
`wg0.conf` works.

## The Endpoint Field

The agent config points to `127.0.0.1:51821` (Docker maps this to the container).
The daemon config points to `host.docker.internal:51820` (Docker's magic DNS name
for the host Mac). WireGuard uses these as initial hints only — after the first
handshake, it tracks wherever packets actually come from and updates the endpoint
dynamically. This is called "roaming."

## PersistentKeepalive

`PersistentKeepalive = 25` sends a keepalive packet every 25 seconds. This keeps
NAT table entries alive and ensures the tunnel stays active. Without it, the
tunnel goes idle and the first packet after a gap has to re-handshake.

## NAT Simulation

The NAT simulation uses macOS `pfctl` (packet filter) to rewrite the WireGuard
source port mid-session:

1. Capture baseline traffic (original 4-tuple)
2. Insert a pf NAT rule that rewrites port 51820 → 61820
3. Capture post-NAT traffic (new 4-tuple)
4. Verify tunnel survived (pkey identity is durable)

What the trust engine sees during a NAT/roam event:

| Signal | Before Roam | After Roam | Trust Impact |
|--------|-------------|------------|-------------|
| pkey | WG_PUBLIC_KEY | WG_PUBLIC_KEY (same) | None |
| src_ip:port | original | different | Roam event flagged |
| Ambient factors | Baseline | If unchanged → legitimate | Confirms identity |
| Ambient factors | Baseline | If changed → possible hijack | Step-up or BLOCK |
| tsval clock | Continuous | If gap + reset → new device | Step-up to biometric |
| Geo from IP | Home city | Same city → commute | Minimal impact |
| Geo from IP | Home city | Different country | BLOCK |

## The Metadata Comparison

Physical interface extraction (what the relay can see):
```
{src: 127.0.0.1:51820, dst: 127.0.0.1:51821, len: UDP_ENCRYPTED, ts: ...}
```

Tunnel interface extraction (what the endpoint can see):
```
{src: 10.0.0.1:43210, dst: 10.0.0.2:9999, seq: 2874919283, len: 22, ts: ...}
```

The physical side has: source UDP, destination UDP, total encrypted blob length,
timestamp. That's it. No TCP layer. No ISN. No window. No payload.

The tunnel side has: all 27 WIRE fields. Full TCP headers. ISNs. Window sizes.
Payload length. Options. Everything.

## The Index Hierarchy

This maps to how the trust engine organizes telemetry:

```
Entity (pkey — durable, survives NAT/roaming)
  └── Circle (security policy, patent "trust circle")
       └── Network identity (observed src_ip — changes with NAT)
            └── Session (4-tuple — ephemeral, breaks across NAT)
                 └── Packets (time-series, WIRE fields)
```

The pkey is the join key across all layers. When the 4-tuple changes but the
pkey doesn't, the engine queries: did the ambient factors change? Did the clock
progress continuously? Is the geo plausible? The answers determine whether to
treat this as a legitimate roam (minor trust impact) or a session hijack (BLOCK).

## How This Maps to the Patent

- **Relay (114):** The encrypted UDP hop. Sees metadata only.
- **Agent (104):** The utun endpoint on the Mac. Encrypts, sends through tunnel.
- **Daemon (106):** The wg0 endpoint in the container. Decrypts, forwards to service.
- **pkey:** WireGuard public key. Used for encryption AND identity validation.
  Patent: "Wireguard provides a virtual network interface that has a unique
  public key (pkey) that is used to encrypt or decrypt the traffic at the tunnel
  endpoints. The pkey can also be used to facilitate validation of user identity."
- **Engine telemetry:** `{src/dest/len/timestamp}` from the physical interface.
  The engine never sees content — just metadata patterns.
