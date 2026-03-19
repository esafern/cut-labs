# Lab 1: TCP Handshake, ISN Tracking & Loopback Telemetry

## What We're Building

The patent's agent (FIG.1 element 104) hooks into the client's loopback interface
to intercept all local application traffic. It extracts metadata —
`{src/dest/len/timestamp}` — and feeds it to the relay for the trust engine to
analyze. This lab implements exactly that: capture TCP traffic on macOS lo0,
extract structured telemetry, and stream it to Kafka.

## What is nc?

`nc` (netcat) is the thinnest possible wrapper around the BSD socket API —
`socket()`, `bind()`, `listen()`, `accept()`, `connect()`, `read()`, `write()`.
No protocol logic, no HTTP, no TLS. Just raw bytes over TCP.

`nc -l 127.0.0.1 9999` calls `socket() → bind(127.0.0.1:9999) → listen() → accept()`.
The process blocks waiting for an inbound connection.

`echo "HELLO_CUT" | nc 127.0.0.1 9999` calls `socket() → connect(127.0.0.1:9999)`,
pipes 10 bytes ("HELLO_CUT" + newline) via `write()`, then closes.

Everything else in the capture is the kernel's TCP stack — not the application.

## What tcpdump Flags Mean

`sudo tcpdump -S -tttt -nn -v -i lo0 'tcp port 9999' -w handshake.pcap`

- `sudo` — root required for BPF device (raw packet capture)
- `-S` — absolute sequence numbers, not relative. Without this, ISNs normalize to 0
- `-tttt` — full date + time timestamps (2026-03-11 19:51:18.341100)
- `-nn` — no DNS resolution, no port name resolution. Raw IPs and numbers
- `-v` — verbose: shows TTL, IP ID, total length, flags
- `-i lo0` — capture on loopback, where the CUT agent hooks in
- `'tcp port 9999'` — BPF filter compiled to kernel bytecode. Only matching packets captured
- `-w` — write raw packets to pcap file for later analysis

## The 10-Packet Capture Explained

A single `echo "HELLO_CUT" | nc` produces 10 packets. Three phases:

### Phase 1: Three-Way Handshake (Packets 1-3)

The handshake is pure kernel — it happens before the application sees a byte.
When nc calls `connect()`, the kernel sends a SYN with a randomly generated
Initial Sequence Number.

**Packet 1 — Client SYN:**
```
Flags [S], seq 2325005619, win 65535, options [mss 16344,nop,wscale 6,...]
```
- `[S]` = SYN flag. "I want to connect."
- `seq 2325005619` = the ISN. macOS generates this per RFC 6528 (hash of 4-tuple + secret + time)
- `win 65535` = receive window. "I can accept this many bytes."
- `mss 16344` = max segment size. Loopback uses 16344 (16384 - 40 byte headers). Ethernet uses 1460
- `wscale 6` = window scale factor. Actual window = 65535 × 2^6 = 4,194,240 bytes
- These SYN options are the OS fingerprint — option order, MSS, wscale differ by OS

**Packet 2 — Server SYN-ACK:**
```
Flags [S.], seq 3606167221, ack 2325005620, win 65535
```
- `[S.]` = SYN + ACK. "I accept, and here's my ISN."
- `seq 3606167221` = the server's ISN, independently generated
- `ack 2325005620` = client ISN + 1. "I received your SYN, ready for your first byte here."

**Packet 3 — Client ACK:**
```
Flags [.], ack 3606167222, win 6380
```
- `[.]` = ACK only. Handshake complete.
- `ack 3606167222` = server ISN + 1
- `win 6380` = scaled window value

### Phase 2: Data Transfer (Packets 4-5)

**Packet 4 — Server window update:**
Server's TCP stack sends a duplicate ACK / window update. macOS loopback
behavior — the stack is so fast it fires an extra ACK before data arrives.

**Packet 5 — Data:**
```
Flags [P.], seq 2325005620:2325005630, ack 3606167222, length 10
```
- `[P.]` = PUSH + ACK. "Deliver this to the app now, don't buffer."
- `seq 2325005620:2325005630` = bytes 0-9 of payload (ISN+1 through ISN+1+10)
- `length 10` = "HELLO_CUT" (9 chars) + newline from `echo`

ISN arithmetic: `2325005619 + 1 = 2325005620` (after handshake), 
`2325005620 + 10 = 2325005630` (after 10 bytes sent).

### Phase 3: Four-Way Teardown (Packets 6-10)

Client sends FIN ("I'm done sending"), server ACKs, server sends FIN
("I'm done too"), client ACKs. Both sides called `close()`.

## The Checksum Warnings

`bad cksum 0` on every packet is normal on lo0. macOS uses TCP checksum
offloading — the kernel writes a placeholder and relies on the NIC to compute
the real checksum. lo0 is a virtual interface with no NIC, so tcpdump sees the
placeholder. The checksum is fine — it's captured before the (nonexistent)
hardware would have fixed it.

## BSD vs Linux Field Offset

tcpdump on lo0 outputs:
```
2026-03-11 19:51:18.341100 IP 127.0.0.1.56896 > 127.0.0.1.9999: Flags [S]...
```

The `IP` token at field $3 is the BSD loopback link-type identifier (NULL).
Linux doesn't emit this. So:
- BSD lo0: src = `$4`, dst = `$6`
- Linux / utun / en0: src = `$3`, dst = `$5`

## The tshark Telemetry Extraction

tshark is the full Wireshark dissection engine running headless — hundreds of
protocol dissectors, stream reassembly, the tcp.analysis.* state machine. It
outputs structured data in multiple formats:

- `-T ek` = Elasticsearch bulk-ingest NDJSON (auto-partitioned by date)
- `-T fields` = CSV with selected fields
- `-T json` = full JSON per packet

The `_index` field in `-T ek` output is an ES index name. The patent says
"a time-series database 120" — tshark already speaks the database's native format.

### WIRE vs COMPUTED Fields

**WIRE fields** — actual bits in IP/TCP headers. The relay extracts these
at line rate with no per-connection state. 27 fields. Reimplementable in
~20 lines of C with fixed byte offsets:

```c
uint32_t src_ip = *(uint32_t *)(ip + 12);
uint16_t src_port = ntohs(*(uint16_t *)(tcp + 0));
uint32_t seq_raw = ntohl(*(uint32_t *)(tcp + 4));
uint16_t window = ntohs(*(uint16_t *)(tcp + 14));
```

**COMPUTED fields** — derived by tshark's stream reassembly or the capture
system. Require per-connection state tracking. 9 fields. These belong in
the engine (element 112), not the relay:

- `time_delta` — subtract previous timestamp (one value per stream)
- `initial_rtt` — SYN-to-SYN-ACK delta (match on flags)
- `is_retransmit` — duplicate seq_raw with payload > 0 (seq set per stream)
- `is_zero_window` — `win_value == 0` (stateless, trivial)
- `ack_rtt` — match ACK to original data (per-stream seq→timestamp map)
- `bytes_in_flight` — max(seq+payload) - max(ack) (two running values per stream)

If COMPUTED fields are absent from a Kafka message, the consumer derives them.
This means the same consumer works with tshark (lab) and a C parser (production).

## What Every Field in the SYN Packet Means

Full tshark JSON for the SYN:

**IP layer:**
- `ip_src/ip_dst` — connection tuple fields 1-2
- `ip_ttl: 64` — OS fingerprint (64=macOS/Linux, 128=Windows). Delta from default = hop count
- `ip_id: 0x0000` with DF — macOS sets to zero when DF is set. Linux increments as global counter. Windows per-destination. OS fingerprint signal
- `ip_len: 64` — 20 IP + 44 TCP (with options) + 0 payload
- `ip_dsfield_dscp: 0` — best effort. VoIP marks this 46 (EF). Change mid-session = anomaly
- `ip_dsfield_ecn: 0` — congestion notification. Routers set these when congested
- `ip_flags_df: True` — standard for TCP. False = fragmentation = possible evasion
- `ip_proto: 6` — TCP. Anomalous protocols (ICMP, GRE) are trust signals

**TCP layer:**
- `tcp_srcport: 56896` — ephemeral port (macOS 49152-65535)
- `tcp_dstport: 9999` — service identifier. Together with IPs = the 4-tuple session key
- `tcp_flags: 0x0002` — SYN only
- `tcp_seq_raw: 2325005619` — THE ISN
- `tcp_ack_raw: 0` — zero on initial SYN (nothing to acknowledge)
- `tcp_window_size_value: 65535` — raw window before scaling
- `tcp_len: 0` — no payload on SYN. This is the `len` in the patent's tuple
- `tcp_hdr_len: 44` — 20 base + 24 options. Drops to 32 after handshake
- `tcp_urgent_pointer: 0` — almost never used legitimately. Nonzero = suspicious

**TCP Options (SYN only — the OS fingerprint):**
- `mss: 16344` — max segment size. 16344 on loopback, 1460 on ethernet, lower on VPN
- `wscale: 6` — window scale. macOS=6, Linux=7, Windows varies
- `sack_perm` — selective ACK support
- `ts_val: 2343814628` — sender clock. Initial value + tick rate = OS fingerprint
- `ts_ecr: 0` — echo reply. Zero on SYN. Later enables RTT measurement

The ORDER of TCP options in the SYN is itself a fingerprint. macOS sends
`mss,nop,wscale,nop,nop,ts,sackOK`. Linux sends them differently. This is
what p0f uses for passive OS fingerprinting. Captured in `tcp_options_raw`.

## The Kafka Pipeline

Three composable scripts:

| Script | Job | Input | Output |
|--------|-----|-------|--------|
| `extract_telemetry.sh` | tshark + transform → file | pcap path | NDJSON file |
| `transform.py` | CSV → keyed JSON | stdin (tshark CSV) | stdout (key\|json) |
| `produce.sh` | file or stdin → Kafka | file arg or stdin | Kafka topic |

**File mode** (any pcap size): `extract → produce`. Reliable because kcat reads
from file via `cat file | kcat -P` (pipe keeps stdin open during SSL handshake).

**Pipe mode** (live capture): `tshark -l | python3 -u transform.py | produce.sh`.
Works because tshark stays alive, python stays alive, kcat's SSL handshake
completes while waiting for first byte. No race condition.

**Session key normalization:** `transform.py` sorts endpoints lexicographically.
Both directions of one TCP session produce the same key → same Kafka partition →
ordering preserved. A `direction` field (`outbound`/`inbound`) tells the engine
which way the packet went.

**Delimiter:** `|` (pipe) everywhere. Tab caused BSD sed failures, confluent CLI
parsing issues, and invisible debugging problems. Colon breaks keys with IP:port.

## How This Maps to the Patent

- **Agent (104):** Our tcpdump/tshark on lo0. In production: eBPF/DTrace
- **Relay (114):** Extracts WIRE fields statelessly. Our extract_telemetry.sh
- **Time-series DB (120):** Kafka topic `packet-telemetry`. tshark -T ek is ES-native
- **Engine (112):** Would consume from Kafka, derive COMPUTED fields, score trust
- **Controller (110+112):** Flink SQL + trust scoring logic (Lab 6 / dashboard)

The SYN packet from this capture — with its ISN, MSS, wscale, TTL, options order,
timestamp clock — is the baseline fingerprint for one session. Every subsequent
packet is scored against it. If the fingerprint changes mid-session (different OS
options, different TTL, clock skew), the engine has a trust signal.
