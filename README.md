# CUT Labs — Continuous Universal Trust Architecture

Reference implementation of the [CUT patent](https://patents.google.com/patent/US12309132B1/en) (US 12,309,132 B1) telemetry pipeline.

Built on Intel macOS Sequoia 15.7.4 (BSD networking stack).

## What This Is

A working implementation of the CUT patent's relay telemetry pipeline:
packet metadata extraction → structured JSON → Kafka → trust engine.

Each lab implements a specific patent component:

| Lab | Patent Component | What It Does |
|-----|-----------------|--------------|
| 1 | Relay telemetry (FIG.1 #114, #120) | TCP capture, ISN tracking, tshark → Kafka pipeline |
| 2 | Two-session relay split (FIG.1 #114) | mTLS proxy showing independent ISN spaces |
| 3 | Trust signal detection (FIG.1 #112) | TCP zero window as DPI choke indicator |
| 4 | WireGuard relay (FIG.1 #114) | Encrypted tunnel + NAT simulation via pfctl |
| 5 | Agent ambient factors (FIG.1 #104) | DTrace/eBPF kernel telemetry collection |
| 6 | Full-stack correlation | All layers captured simultaneously |

## Quick Start

```bash
brew install mitmproxy wireshark wireguard-tools wireguard-go iperf3 nmap kcat
cp lab1/confluent.properties.template lab1/confluent.properties
```

Edit `lab1/confluent.properties` with your Confluent Cloud API key.

Lab 1 — capture a TCP handshake and produce telemetry to Kafka:

```bash
cd lab1
nc -l 127.0.0.1 9999 &
sudo tcpdump -S -tttt -nn -v -i lo0 'tcp port 9999' -w handshake.pcap &
echo "HELLO_CUT" | nc 127.0.0.1 9999
./extract_telemetry.sh handshake.pcap telemetry.tsv
./produce.sh telemetry.tsv
```

## Architecture

```
tcpdump/tshark          Kafka              Trust Engine
  (relay tier)      (streaming tier)      (engine tier)
      │                    │                    │
  WIRE fields ────→ packet-telemetry ────→ COMPUTED fields
  27 fields            topic               9 derived fields
  stateless         keyed by 4-tuple       stateful analysis
  line-rate         partition affinity      trust scoring
```

Production path replaces tshark with DPDK/XDP + C parser → librdkafka.
Same Kafka schema, same consumer code.

## Key Design Decisions

**WIRE vs COMPUTED:** Relay extracts 27 stateless header fields. Engine derives 9 stateful
fields downstream. See `lab1/FIELD_REFERENCE.md`.

**pkey over 4-tuple:** NAT breaks the 4-tuple. WireGuard public key is the durable identity
anchor. Lab 4 proves this with a pfctl NAT simulation.

**Dual extraction paths:** `extract_telemetry.sh` (WIRE+COMPUTED for lab demo) and
`extract_wire_only.sh` (WIRE only, simulates production relay). Same `transform.py` handles both.

## Repo Structure

```
lab1/           TCP handshake + telemetry pipeline
  transform.py            CSV → keyed JSON
  extract_telemetry.sh    tshark (WIRE+COMPUTED) → file
  extract_wire_only.sh    tshark (WIRE only) → file
  produce.sh              file or stdin → Confluent Cloud
  extract_ek.sh           tshark → Elasticsearch NDJSON
  register_schema.sh      Register schemas with Schema Registry
  schemas/                JSON Schema data contract
  DATA_CONTRACT.md        Topic contract
  FIELD_REFERENCE.md      All 36 fields with C byte offsets
lab2/           mTLS proxy (two-session relay split)
  MTLSClient.java         Java SSLSocket client with keystore
  LESSONS_LEARNED.md      IPv6/IPv4, mitmproxy cert matching
lab3/           TCP zero window (DPI choke simulation)
  StallServer.java        Stalling receiver
  FloodSender.java        Fast sender
lab4/           WireGuard tunnel + NAT simulation
  nat_simulation.sh       pfctl NAT rewrite demo
lab5/           Kernel telemetry
  tcp_telemetry.d         DTrace ambient factor collector
lab6/           Full-stack correlation
docs/           Lab guide and session prompt
```

## Patent Reference

US 12,309,132 B1 — "Continuous Universal Trust Architecture and Method"
Filed 2024-07-12. Granted 2025-05-20.
Filed 2024-07-12. Granted 2025-05-20.
