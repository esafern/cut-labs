# Lab 6: Full-Stack Correlation (Epilogue)

## What We're Building

Chain Labs 1-5 into a single running system that demonstrates the complete CUT
architecture. mTLS connection through WireGuard, with DTrace collecting kernel
telemetry simultaneously. Capture at every layer. Produce all telemetry to
Kafka. Show where ISN continuity holds and where it breaks.

## The Complete Trust Signal Chain

1. **Agent (DTrace/eBPF):** Collects ambient factors — process identity,
   connection targets, byte counts, system state
2. **Agent (WireGuard):** Encrypts traffic, sends through tunnel. pkey = identity
3. **Relay (physical interface):** Sees ONLY encrypted UDP with
   `{src/dest/len/timestamp}`. No ISNs, no payload, no TCP headers
4. **Relay → Engine:** Feeds metadata to time-series DB (Kafka topic)
5. **Engine (Flink SQL):** Reads telemetry, derives COMPUTED fields, scores trust
6. **Engine decision:** Step-up, step-down, or BLOCK based on combined signals
7. **Daemon (container):** Decrypts, forwards to service. Sends
   `{src/pkey/dest/timestamp/request_body_hash}` back to engine for integrity

## Where ISN Continuity Holds and Breaks

| Layer | ISN Visible? | Content Visible? | Patent Component |
|-------|-------------|-------------------|-----------------|
| Kernel (DTrace/eBPF) | No (syscall level) | Yes (app layer) | Agent — ambient |
| Tunnel interface (utun/wg0) | Yes — full TCP | Yes — cleartext | Agent ↔ Daemon |
| Physical interface (lo0/bridge) | No — encrypted | No — encrypted | Relay metadata |
| Proxy boundary (Lab 2) | Yes, but DIFFERENT | Decrypted at proxy | Relay split |

## The Enrichment Pipeline

Three layers, each adding data the previous couldn't produce:

**Layer 1 — Relay** (stateless, line-rate):
Reads packet headers. Produces 27 WIRE fields. No per-connection memory.
High-throughput forwarding path.

**Layer 2 — Engine** (stateful, analytical):
Reads stored WIRE data. Derives 9 COMPUTED fields (RTT, retransmissions,
zero window detection). Maintains per-session context.

**Layer 3 — Agent** (kernel-level, endpoint-only):
Produces ambient factors. Process identity, device state, behavioral signals.
Neither relay nor engine can see these — only the local agent.

## The Demo Flow

Five terminals running simultaneously:

| Terminal | What's running | Captures |
|----------|---------------|----------|
| 1 | WireGuard tunnel (Mac agent + Docker daemon) | — |
| 2 | DTrace tcp_telemetry.d | Kernel events |
| 3 | tcpdump on utun (cleartext) | Full TCP with ISNs |
| 4 | tcpdump on lo0/bridge (encrypted) | UDP blobs only |
| 5 | mTLS client through tunnel | Traffic generator |

After capturing: extract telemetry from all pcaps, produce to Kafka, show
the same traffic at every layer with different visibility.

## The Architecture Story

"I built the entire CUT telemetry pipeline: packet capture on the loopback
where the agent hooks in, WireGuard as the relay with encrypted transit,
kernel tracing for ambient factors, structured telemetry extraction with
27 WIRE fields at fixed byte offsets, streaming to Kafka with normalized
session keys, and schemas registered in Schema Registry for Flink SQL
to discover automatically. The relay tier is stateless — no per-connection
memory, line-rate extraction. The engine tier derives 9 stateful fields
downstream from stored WIRE data. In production you'd replace tshark with
a 20-line C parser on DPDK. Everything else — the Kafka schema, the
partitioning strategy, the consumer code — stays identical."
