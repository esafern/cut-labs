# CUT Labs: zero-trust network telemetry, built from a patent

Six hands-on labs that rebuild, in miniature, the telemetry pipeline described in
US patent 12,309,132 B1, "Continuous Universal Trust Architecture and Method":
packet and kernel metadata captured on a device, streamed through Kafka with
registered schemas, and analyzed for trust signals without inspecting payload.

## Author and purpose

I wrote these labs myself in March 2026 as a learning exercise: to understand the
patent's architecture by building each component and capturing real traffic through
it, rather than by reading alone. Each lab folder has a `NARRATIVE.md` with what I
built, what broke, and what the captures showed.

The patent's inventor is Nir Gaist; it is assigned to Noetic Global Corp. This is an
independent study based on the published patent. It is not affiliated with or
endorsed by Noetic, and it contains no Noetic code.

Built and run on Intel macOS Sequoia 15.7.4 (BSD networking stack), with Confluent
Cloud for Kafka, Schema Registry and Flink SQL.

## What the labs showed

- **The relay can be stateless.** Of 36 TCP/IP fields, 27 are WIRE fields readable
  from fixed header offsets at line rate; 9 COMPUTED fields (RTT, retransmits,
  bytes in flight) need per-connection state and belong in the engine, downstream.
- **A proxy breaks sequence-number continuity.** Through an mTLS middlebox, one
  request produced four independent ISNs, and the proxy added 1.4 ms between the
  client's SYN and its own SYN to the server: a gap visible in telemetry alone.
- **A stalled intermediary is visible without payload.** A receiver that stops
  reading drives the TCP window to zero in under 200 ms, then recovers in a
  sawtooth; one comparison on a header field detects it.
- **Identity can survive NAT.** With WireGuard, rewriting the port mid-session
  changes the 4-tuple, but the tunnel re-establishes on the same public key.
- **Kernel telemetry needs no SIP changes on macOS.** DTrace's syscall provider
  records which process connected, sent and received, by PID; only function
  boundary tracing is blocked.

## What this is

The labs follow the patent's pipeline:

packet metadata extraction → structured JSON → Kafka → trust engine.

Each lab implements a specific patent component:

| Lab | Patent Component | What It Does |
|-----|------------------|--------------|
| 1   | Relay telemetry (FIG.1 #114, #120) | TCP capture, ISN tracking, tshark → Kafka pipeline |
| 2   | Two-session relay split (FIG.1 #114) | mTLS proxy showing independent ISN spaces |
| 3   | Trust signal detection (FIG.1 #112) | TCP zero window as DPI choke indicator |
| 4   | WireGuard relay (FIG.1 #114) | Encrypted tunnel via Docker + NAT simulation |
| 5   | Agent ambient factors (FIG.1 #104) | DTrace kernel telemetry + device snapshot |
| 6   | Full-stack correlation | All layers captured simultaneously |

## Quick Start

### Prerequisites

```bash
brew install mitmproxy wireshark wireguard-tools wireguard-go iperf3 nmap
pip3 install confluent-kafka --break-system-packages
```

Also used: a Confluent Cloud cluster with Schema Registry and Flink SQL; Java 17
(labs 2 and 3); Docker (lab 4); PostgreSQL and Grafana for the dashboard
(`load_grafana.py`, `cut-dashboard.json`).

### Confluent Cloud Setup

Copy the template and add your API credentials:

```bash
cp lab1/confluent.properties.template lab1/confluent.properties
```

### Lab 1 — Capture a TCP Handshake

Terminal 1 — listener:

```bash
nc -l 127.0.0.1 9999
```

Terminal 2 — capture:

```bash
cd lab1 && sudo tcpdump -S -tttt -nn -v -i lo0 'tcp port 9999' -w handshake.pcap
```

Terminal 3 — connect:

```bash
echo "HELLO_CUT" | nc 127.0.0.1 9999
```

Ctrl-C the tcpdump. Extract and produce to Kafka:

```bash
cd lab1 && ./extract_telemetry.sh handshake.pcap telemetry.tsv
python3 ../produce_sr.py confluent.properties packet-telemetry <sr_url> <sr_key> <sr_secret> < telemetry.tsv
```

## Architecture

```
tcpdump/tshark          Kafka                   Trust Engine
  (relay tier)      (streaming tier)            (engine tier)
      │                    │                         │
  WIRE fields ──→ packet-telemetry ──────────→ COMPUTED fields
  28 fields            topic                    9 derived fields
  stateless        keyed by session             stateful analysis
  line-rate        partition affinity            trust scoring
                           │
  DTrace/eBPF ──→ ambient-telemetry ──────────→ Device fingerprint
  syscall events       topic                    Process inventory
  kernel-level     keyed by pid-process         Behavioral baseline
```

Two Kafka topics, two service accounts (least-privilege):

| Topic | Key Format | Service Account | Content |
|-------|-----------|-----------------|---------|
| `packet-telemetry` | Normalized 4-tuple | packet-service | TCP/IP header metadata |
| `ambient-telemetry` | `{pid}-{process}` | ambient-service | DTrace syscall events + device state |

Production path replaces tshark with DPDK/XDP + C parser → librdkafka.
Same Kafka schema, same consumer code.

## Key Design Decisions

**WIRE vs COMPUTED:** Relay extracts 28 stateless header fields (27 from packet
headers + direction from key normalization). Engine derives 9 stateful fields
downstream. See `lab1/FIELD_REFERENCE.md`.

**Normalized session key:** Endpoints sorted lexicographically so both directions
of one TCP session produce the same Kafka key → same partition → ordering preserved.
A `direction` field (`outbound`/`inbound`) in the value distinguishes packet direction.

**pkey over 4-tuple:** NAT breaks the 4-tuple. WireGuard public key is the durable
identity anchor. Lab 4 demonstrates this by changing the agent's ListenPort
mid-session — tunnel re-establishes on the same pkey.

**Pipe delimiter:** `|` everywhere. Tab caused BSD sed failures and confluent CLI
parsing issues. Colon breaks keys containing IP:port.

**Python Schema Registry producer:** `produce_sr.py` uses confluent-kafka (librdkafka)
with batching, compression, and SSL retry with Schema Registry serialization for both key and value.

**Docker for WireGuard daemon:** Both WireGuard peers on the same Mac fails — the
kernel short-circuits LOCAL destinations. The daemon runs inside a Docker container
with a separate network stack.

## Repo Structure

```
produce_sr.py           Kafka producer with Schema Registry serialization for both key and value.
load_grafana.py         Consume packet-telemetry and ambient-telemetry from Kafka, build session_summary in PostgreSQL for Grafana
cut-dashboard.json      First pass at a Grafana Dashboard analyzing the traffic data
lab1/                   TCP handshake + telemetry pipeline
  NARRATIVE.md            Detailed walkthrough and explanation
  transform.py            CSV → normalized keyed JSON (pipe-delimited)
  extract_telemetry.sh    tshark (WIRE+COMPUTED) → file
  extract_wire_only.sh    tshark (WIRE only) → file
  extract_ek.sh           tshark → Elasticsearch NDJSON
  register_schema.sh      Register schemas with Schema Registry
  schemas/                JSON Schema data contracts
  confluent.properties.template
  DATA_CONTRACT.md        Topic contract (both topics)
  FIELD_REFERENCE.md      All 28+9 fields with C byte offsets
lab2/                   mTLS proxy (two-session relay split)
  NARRATIVE.md            PKI, ISN independence, proxy timing analysis
  MTLSClient.java         Java SSLSocket client with keystore
  client_ext.cnf          Client cert extensions
  server_ext.cnf          Server cert extensions
  LESSONS_LEARNED.md      IPv6/IPv4, mitmproxy cert matching
lab3/                   TCP zero window (DPI choke simulation)
  NARRATIVE.md            Flow control, sawtooth recovery, Flink SQL query
  StallServer.java        Stalling receiver
  FloodSender.java        Fast sender
lab4/                   WireGuard tunnel + NAT simulation
  NARRATIVE.md            Dual capture, pkey identity, Docker workaround
  Dockerfile              Ubuntu 22.04 + wireguard-tools for daemon peer
  nat_simulation.sh       pfctl NAT rewrite demo (original approach)
lab5/                   Kernel telemetry (the patent's agent)
  NARRATIVE.md            Ambient factors, device fingerprint, trust scoring
  tcp_telemetry.d         DTrace ambient factor collector (SIP-safe)
  transform_ambient.py    DTrace output → keyed JSON
  capture_ambient.sh      Device snapshot (processes, apps, network state)
  register_ambient_schema.sh
  schemas/                Ambient telemetry JSON Schema
lab6/                   Full-stack correlation
  NARRATIVE.md            Chain all labs, capture at every layer
docs/
  CUT-Crash-Course-Lab-Guide.md   Step-by-step CLI guide (all labs)
  PIPELINE.md                     Pipeline reference architecture
```

## Schema Registry

Both topics have JSON Schemas registered in Confluent Schema Registry.
Flink SQL auto-discovers column types from registered schemas.

| Subject | Type | Location |
|---------|------|----------|
| `packet-telemetry-key` | Normalized 4-tuple (string) | `lab1/schemas/` |
| `packet-telemetry-value` | 28 WIRE + 9 COMPUTED fields | `lab1/schemas/` |
| `ambient-telemetry-key` | `{pid}-{process}` (string) | `lab5/schemas/` |
| `ambient-telemetry-value` | Syscall event with process identity | `lab5/schemas/` |

## Scope and limits

This is a learning environment, not a product. Capture uses tcpdump and tshark with
Python transforms; the production path the notes describe is a C parser at fixed
byte offsets feeding librdkafka, with the same schemas. Cross-layer correlation in
lab 6 is done by hand; the Flink SQL in `docs/flink_queries.sql` shows the detection
queries (session summary, zero-window stalls, process inventory), not an automated
trust score.

## Patent reference

US 12,309,132 B1, "Continuous universal trust architecture and method".
Inventor: Nir Gaist. Assignee: Noetic Global Corp (originally Cortwo Corp).
Filed 2024-07-12. Granted 2025-05-20.
https://patents.google.com/patent/US12309132B1/en
