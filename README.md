# CUT Labs — Continuous Universal Trust Architecture

Reference implementation of the [CUT patent](https://patents.google.com/patent/US12309132B1/en) (US 12,309,132 B1) telemetry pipeline.

Built on Intel macOS Sequoia 15.7.4 (BSD networking stack).

## What This Is

A working implementation of the CUT patent's relay telemetry pipeline:
packet metadata extraction → structured JSON → Kafka → trust engine.

The project explores how a Zero-Trust network architecture can extract,
stream, and analyze TCP/IP metadata to build continuous trust scoring
without inspecting payload content.

Each lab implements a specific patent component:

| Lab | Patent Component | What It Does |
|-----|-----------------|--------------|
| 1 | Relay telemetry (FIG.1 #114, #120) | TCP capture, ISN tracking, tshark → Kafka pipeline |
| 2 | Two-session relay split (FIG.1 #114) | mTLS proxy showing independent ISN spaces |
| 3 | Trust signal detection (FIG.1 #112) | TCP zero window as DPI choke indicator |
| 4 | WireGuard relay (FIG.1 #114) | Encrypted tunnel via Docker + NAT simulation |
| 5 | Agent ambient factors (FIG.1 #104) | DTrace kernel telemetry + device snapshot |
| 6 | Full-stack correlation | All layers captured simultaneously |

## Quick Start

### Prerequisites

```bash
brew install mitmproxy wireshark wireguard-tools wireguard-go iperf3 nmap kcat
pip3 install confluent-kafka --break-system-packages
```

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
python3 ../produce.py confluent.properties packet-telemetry < telemetry.tsv
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

**Python producer over kcat/CLI:** `produce.py` uses confluent-kafka (librdkafka)
with batching, compression, and SSL retry. kcat's SSL first-connect failure is
persistent with Confluent Cloud. The confluent CLI lacks batching.

**Docker for WireGuard daemon:** Both WireGuard peers on the same Mac fails — the
kernel short-circuits LOCAL destinations. The daemon runs inside a Docker container
with a separate network stack.

## Repo Structure

```
produce.py              Universal Kafka producer (confluent-kafka, batched, compressed)
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
  CUT-Session-Prompt.md           Claude session prompt for regenerating the guide
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

## Patent Reference

US 12,309,132 B1 — "Continuous Universal Trust Architecture and Method"
Filed 2024-07-12. Granted 2025-05-20.
