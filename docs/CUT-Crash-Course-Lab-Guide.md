# Cortwo CUT Architecture — Crash Course Lab Guide

**Version:** 1.3
**Updated:** 2026-03-13
**Target:** Principal Performance Architect interview prep
**Platform:** Intel macOS Sequoia 15.7.4 (BSD networking stack, x86_64)
**Patent Reference:** US 12,309,132 B1 — "Continuous Universal Trust"
**Changelog:**
- v1.3: Refactored Confluent pipeline to three composable scripts (transform.py, extract_telemetry.sh, produce.sh) with dual-path assembly (file mode for pcap, pipe mode for live capture). Fixed kcat -b/-F conflict, SSL CA bundle issue, pipe race condition. Added lessons learned for kcat config, pipeline composition, zsh comment handling.
- v1.2: Added tshark → Confluent Cloud pipeline (Lab 1.5c), kcat producer with SASL_SSL, session 4-tuple as Kafka key for partition routing, live capture mode, production architecture comparison (tshark vs DPDK/XDP/libpcap)
- v1.1: Fixed BSD awk field offsets ($4/$6 on lo0), added tshark/ES extraction scripts with WIRE/COMPUTED field tagging, added NAT simulation (Lab 4.10), added Lessons Learned section, added wire vs computed field reference
- v1.0: Initial 6-lab guide

---

## Prerequisites & Setup

```bash
# Verify existing tools
java -version && mvn -version && python3 --version

# Install lab dependencies
brew install mitmproxy wireshark wireguard-tools wireguard-go iperf3 nmap

# Verify tcpdump (ships with macOS, requires sudo)
sudo tcpdump --version

# Verify dtrace (ships with macOS, requires SIP adjustment — see Lab 5 note)
sudo dtrace -l | head -5

# Create working directory
mkdir -p ~/cut-labs/{lab1,lab2,lab3,lab4,lab5,lab6}
cd ~/cut-labs
```

### macOS Interface Reference

| Interface | Purpose | Equivalent on Linux |
|-----------|---------|-------------------|
| `lo0` | Loopback (127.0.0.1) | `lo` |
| `en0` | Primary Ethernet/WiFi | `eth0` / `wlan0` |
| `utun*` | VPN/WireGuard tunnels | `wg0` / `tun0` |
| `bridge*` | VM bridging | `br0` |
| `pflog0` | Packet filter logging | N/A |

```bash
# List all active interfaces
ifconfig -l
# Detailed view
networksetup -listallhardwareports
```

### Baseline Your utun Interfaces

macOS pre-allocates `utun0` through `utun4` (or higher) for iCloud Private Relay, Xcode, and other system services. Before Lab 4 (WireGuard), record your baseline so you can identify new tunnel interfaces:

```bash
ifconfig -l | tr ' ' '\n' | grep utun
```

WireGuard will create interfaces at the next available `utun` slot (e.g., `utun5`, `utun6`).

### macOS Sequoia Note

On macOS 15.x (Sequoia), `wg-quick` may emit `Warning: /etc/resolv.conf is not a symlink` when bringing up WireGuard interfaces. Ignore it — we're not routing DNS through the tunnel.

---

## Lessons Learned (Updated During Lab Execution)

These are real issues hit during execution on macOS Sequoia 15.7.4 / Intel x86_64. They apply to all labs.

### BSD vs. GNU/Linux Tool Differences

**tcpdump field offsets on BSD loopback:** BSD `lo0` captures use link-type `NULL`, which inserts `IP` as a token in the output. This shifts all field positions by one compared to Linux. In awk scripts parsing `tcpdump` output on `lo0`:
- Use `$4` for source address (not `$3`)
- Use `$6` for destination address (not `$5`)
- `$1 " " $2` for timestamp is correct on both

**sed step addresses:** BSD `sed` (ships with macOS) does not support GNU extensions like `~` (step addresses), `-i` without a backup suffix argument, or extended regex by default. Use `awk` for line filtering or install `gsed` via Homebrew:
```bash
# GNU sed:  sed -n '1~2p'     ← does NOT work on macOS
# BSD awk:  awk 'NR%2==1'     ← works everywhere
```

**python3 -m json.tool vs. NDJSON:** `json.tool` expects a single JSON document. tshark `-T ek` outputs NDJSON (one JSON object per line). Use inline python instead:
```python
python3 -c '
import sys, json
for line in sys.stdin:
    line = line.strip()
    if line:
        print(json.dumps(json.loads(line), indent=2))
        print("---")
'
```

### zsh Shell Gotchas

**Hash comments in pasted blocks:** zsh interprets `#` differently when pasting multi-line commands. Do NOT put `#` comments inside shell code blocks intended for pasting. Put explanatory text outside the code block instead.

**Percent in awk:** zsh may try to interpret `%` in awk expressions. Single-quoting the entire awk program prevents this.

**Multi-line paste:** When providing shell commands for pasting, prefer combining with `&&` on one line over multi-line blocks. Multi-line paste behavior in zsh is unpredictable with special characters.

### SIP and DTrace

System Integrity Protection is confirmed active. The `syscall` provider works under SIP — use it for `connect`, `socket`, `read`, `write` tracing. The `fbt` (function boundary tracing) provider does NOT work under SIP. No reboot needed for these labs.

### Checksum Warnings on Loopback

`bad cksum 0` warnings on `lo0` captures are normal. macOS uses TCP checksum offloading — the kernel writes a placeholder and relies on the NIC to compute the real checksum. `lo0` has no NIC, so tcpdump sees the placeholder. Ignore these; they don't appear on `en0` captures.

### tshark Outputs ES-Native JSON

`tshark -T ek` outputs Elasticsearch bulk-ingest NDJSON with `_index` fields auto-partitioned by date. This maps directly to the patent's "time-series database 120." No custom serialization needed — the tool already speaks the database's native format.

### Wire vs. Computed Fields in Telemetry

Not all fields in the tshark output exist on the wire. The distinction maps to the patent's relay/engine separation:

**WIRE fields** (actual bits in IP/TCP headers) — stateless extraction, the relay (element 114) can produce these at line rate with no per-connection memory: `ip.src`, `ip.dst`, `ip.ttl`, `ip.id`, `ip.len`, `ip.dsfield.*`, `ip.flags.*`, `ip.proto`, `tcp.srcport`, `tcp.dstport`, `tcp.flags`, `tcp.seq_raw`, `tcp.ack_raw`, `tcp.window_size_value`, `tcp.len`, `tcp.hdr_len`, `tcp.urgent_pointer`, and all `tcp.options.*` fields.

**COMPUTED fields** (derived by capture tool or stream reassembly) — require per-connection state tracking, belongs in the engine (element 112): `frame.*` (capture metadata), `tcp.window_size` (scaled = value × 2^wscale), and all `tcp.analysis.*` fields (retransmission detection, zero window, duplicate ACK, RTT computation, out-of-order detection).

The `extract_ek.sh` script in Lab 1.5b tags every field with `WIRE` or `COMPUTED` comments.

### Session Identity and NAT

The 4-tuple `{src_ip, src_port, dst_ip, dst_port}` is NOT a stable session key. NAT rewrites source IP and port at every boundary. The WireGuard pkey is the durable identity anchor — it survives NAT rebinding, mobile roaming, and network transitions. The trust engine treats 4-tuple changes as signals (roam events) and correlates them with ambient factors to distinguish legitimate roaming from session hijacking. See Lab 4.11 for the NAT simulation.

### kcat / librdkafka vs Java Kafka Config

kcat uses librdkafka configuration format, not Java. Key differences:
- `sasl.mechanisms` (librdkafka) NOT `sasl.mechanism` (Java)
- `sasl.username` / `sasl.password` (librdkafka) NOT `sasl.jaas.config` (Java)
- Config file via `-F` flag, not `-Dclient.properties`

The `confluent.properties` file in Lab 1.5c uses librdkafka format. If you switch to a Java producer, the SASL config changes completely.

### kcat -b Flag Conflicts with -F

Never pass `-b` (bootstrap) alongside `-F` (config file). The `-b` flag opens a connection using only the bootstrap address with no SSL/SASL config. The `-F` flag provides bootstrap AND all security config from one file. Use `-F` alone for Confluent Cloud.

### macOS librdkafka SSL CA Bundle

librdkafka on macOS may not find the system CA bundle automatically. If kcat fails with "SSL handshake failed," add `ssl.ca.location` to your properties file pointing to the Homebrew OpenSSL cert bundle (typically `/usr/local/etc/openssl@3/cert.pem` or `/etc/ssl/cert.pem`).

### Pipe Race Condition: Small Files vs. Live Capture

Piping python directly into kcat fails for small pcap files. The issue: python processes all packets and exits in <1ms. Pipe closes. kcat hasn't finished SSL handshake to Confluent Cloud (~37ms). kcat sees closed stdin and aborts.

This is NOT a buffering problem (`python3 -u` doesn't fix it). It's a race between python's process lifetime and kcat's connection setup time.

**Solution:** Two assembly patterns from the same components:
- **File mode** (any pcap size): extract to file, then produce from file. kcat opens a file, not a pipe — no race.
- **Pipe mode** (live capture): tshark stays alive, python stays alive, kcat's SSL handshake completes while waiting for first packet. The race doesn't exist because the producer process never closes.

### Script Design: Unix Pipeline Composition

Split tools into single-responsibility scripts that compose via pipes or files:

| Script | Job | Input | Output |
|--------|-----|-------|--------|
| `extract_telemetry.sh` | tshark + transform → file | pcap path | NDJSON file |
| `transform.py` | CSV → keyed JSON | stdin (tshark CSV) | stdout (keyed NDJSON) |
| `produce.sh` | file or stdin → Kafka | file arg or stdin | Kafka topic |

File mode: `extract_telemetry.sh pcap out.tsv && produce.sh out.tsv`
Pipe mode: `tshark -l [...] | python3 -u transform.py | produce.sh`

Same components, two assembly patterns. This mirrors the production architecture: the extraction layer and the Kafka producer are separate concerns regardless of whether the transport between them is a file, a pipe, or a network call.

---

## Lab 1: TCP Handshake, ISN Tracking & Loopback Telemetry

**Time: ~75 minutes** (includes tshark/ES extraction + Confluent Cloud pipeline)
**Patent link:** The CUT agent intercepts traffic on the client's loopback interface and extracts `{src/dest/len/timestamp}` metadata tuples for the relay. This lab captures exactly that telemetry.

### 1.1 — Start a Listener

Terminal 1:
```bash
# nc listener on port 9999, loopback only
nc -l 127.0.0.1 9999
```

### 1.2 — Start the Capture

Terminal 2:
```bash
# CRITICAL FLAGS:
#   -S    = absolute sequence numbers (NOT relative) — this is the ISN flag
#   -tttt = wall-clock timestamp (year-month-day hour:min:sec.frac)
#   -nn   = no DNS/port resolution (raw IPs and port numbers)
#   -v    = verbose (shows TTL, window size, options)
#   -i lo0 = loopback interface (where the CUT agent hooks in)

sudo tcpdump -S -tttt -nn -v -i lo0 'tcp port 9999' -w ~/cut-labs/lab1/handshake.pcap
```

### 1.3 — Initiate the Connection

Terminal 3:
```bash
# Connect and send a known payload
echo "HELLO_CUT" | nc 127.0.0.1 9999
```

### 1.4 — Stop capture (Ctrl-C in Terminal 2), then analyze

```bash
# Read the pcap with absolute sequence numbers
tcpdump -S -tttt -nn -v -r ~/cut-labs/lab1/handshake.pcap
```

**What you're looking for — annotated output:**

```
# Packet 1: Client SYN
2026-03-10 14:22:31.123456 IP 127.0.0.1.52341 > 127.0.0.1.9999:
  Flags [S], seq 3819753421, win 65535, options [mss 16344,...]
  ^^^^^^^^                       ^^^^^^^^^^^^^^^^
  SYN flag                       CLIENT ISN = 3819753421

# Packet 2: Server SYN-ACK
2026-03-10 14:22:31.123512 IP 127.0.0.1.9999 > 127.0.0.1.52341:
  Flags [S.], seq 1047293856, ack 3819753422, win 65535, options [mss 16344,...]
  ^^^^^^^^^^     ^^^^^^^^^^^^^^^^     ^^^^^^^^^^^^^^^^
  SYN+ACK        SERVER ISN           ack = CLIENT ISN + 1

# Packet 3: Client ACK (handshake complete)
2026-03-10 14:22:31.123534 IP 127.0.0.1.52341 > 127.0.0.1.9999:
  Flags [.], seq 3819753422, ack 1047293857, win 65535
  ^^^^^^^^^     ^^^^^^^^^^^^^^^^     ^^^^^^^^^^^^^^^^
  ACK only      CLIENT ISN + 1       SERVER ISN + 1

# Packet 4: Data ("HELLO_CUT\n" = 10 bytes)
2026-03-10 14:22:31.123601 IP 127.0.0.1.52341 > 127.0.0.1.9999:
  Flags [P.], seq 3819753422:3819753432, ack 1047293857
                  ^^^^^^^^^^^^^^^^^^^^^^^^
                  ISN+1 : ISN+1+len(data)
```

**ISN arithmetic to verify:**
```
Client ISN:     3819753421
Client seq after handshake: 3819753421 + 1 = 3819753422
Client seq after 10-byte send: 3819753422 + 10 = 3819753432
```

### 1.5 — Extract CUT Relay Metadata Tuples (Quick)

This mirrors what the patent's relay sends to the engine: `{src/dest/len/timestamp}`

> **BSD gotcha:** On macOS `lo0`, tcpdump outputs `IP` as field $3 (link-type NULL token). Source is `$4`, destination is `$6`. Linux doesn't do this. See Lessons Learned.

```bash
# Extract the relay-style metadata from the pcap
# NOTE: $4/$6 for BSD loopback — Linux would be $3/$5
tcpdump -S -tttt -nn -r ~/cut-labs/lab1/handshake.pcap | \
  awk '{
    ts = $1 " " $2;
    src = $4;
    dst = $6;
    gsub(/:$/, "", dst);
    len_match = match($0, /length [0-9]+/);
    len = (len_match ? substr($0, RSTART+7, RLENGTH-7) : "0");
    printf "{src: %s, dest: %s, len: %s, timestamp: %s}\n", src, dst, len, ts
  }'
```

Expected output mirrors the patent's FIG. 2, step (5):
```
{src: 127.0.0.1.56896, dest: 127.0.0.1.9999, len: 0, timestamp: 2026-03-11 19:51:18.341100}
{src: 127.0.0.1.9999, dest: 127.0.0.1.56896, len: 0, timestamp: 2026-03-11 19:51:18.341142}
{src: 127.0.0.1.56896, dest: 127.0.0.1.9999, len: 0, timestamp: 2026-03-11 19:51:18.341151}
{src: 127.0.0.1.56896, dest: 127.0.0.1.9999, len: 10, timestamp: 2026-03-11 19:51:18.341166}
```

### 1.5b — Extract Full Telemetry via tshark (ES Bulk Format)

tshark's `-T ek` output is natively formatted for Elasticsearch bulk ingestion — alternating index action lines and document bodies in NDJSON. This maps directly to the patent's "time-series database 120 that stores telemetry extracted from the traffic flows."

Create `~/cut-labs/lab1/extract_ek.sh`:
```bash
cat > ~/cut-labs/lab1/extract_ek.sh << 'SCRIPT'
#!/bin/bash
# CUT Relay Telemetry → Elasticsearch NDJSON
# v1.1 — fields tagged as WIRE (on the packet) or COMPUTED (capture/analysis)
#
# Patent reference: FIG.1 element 120 (time-series database)
#
# WIRE fields: actual bits in the IP/TCP headers — stateless extraction at relay
# COMPUTED fields: derived by capture tool or stream reassembly — require
#   per-connection state tracking, belongs in the engine (element 112), not relay
#
# Architecture implication:
#   Relay (element 114) extracts WIRE fields → time-series DB (element 120)
#   Engine (element 112) reads time-series DB → computes COMPUTED fields → trust scoring
#
# Usage:
#   ./extract_ek.sh <pcap_file>                    # stdout
#   ./extract_ek.sh <pcap_file> > telemetry.ndjson # to file
#   ./extract_ek.sh <pcap_file> | \                # direct to ES
#     curl -s -XPOST localhost:9200/_bulk \
#       -H 'Content-Type: application/x-ndjson' \
#       --data-binary @-

PCAP="${1:?Usage: $0 <pcap_file>}"

tshark -r "$PCAP" -T ek \
  \
  -e frame.number           `# COMPUTED: capture ordinal` \
  -e frame.time_epoch       `# COMPUTED: capture system clock (not sender)` \
  -e frame.time             `# COMPUTED: human-readable capture time` \
  -e frame.len              `# COMPUTED: includes link-layer header` \
  \
  -e ip.src                 `# WIRE: source IP` \
  -e ip.dst                 `# WIRE: destination IP` \
  -e ip.ttl                 `# WIRE: time to live (hop count / OS fingerprint)` \
  -e ip.id                  `# WIRE: IP identification (OS fingerprint)` \
  -e ip.len                 `# WIRE: total IP datagram length` \
  -e ip.dsfield.dscp        `# WIRE: DiffServ code point (traffic class)` \
  -e ip.dsfield.ecn         `# WIRE: explicit congestion notification` \
  -e ip.flags.df            `# WIRE: don't fragment` \
  -e ip.flags.mf            `# WIRE: more fragments (evasion signal)` \
  -e ip.frag_offset         `# WIRE: fragment offset (evasion signal)` \
  -e ip.proto               `# WIRE: protocol number (6=TCP, 17=UDP)` \
  \
  -e tcp.srcport            `# WIRE: source port (ephemeral, session key)` \
  -e tcp.dstport            `# WIRE: dest port (service ID, session key)` \
  -e tcp.flags              `# WIRE: raw flags byte (hex)` \
  -e tcp.flags.str          `# WIRE: flags as string` \
  -e tcp.seq_raw            `# WIRE: absolute sequence number / ISN` \
  -e tcp.ack_raw            `# WIRE: absolute ack number` \
  -e tcp.window_size_value  `# WIRE: raw window value (before scaling)` \
  -e tcp.window_size        `# COMPUTED: scaled window = value * 2^wscale` \
  -e tcp.len                `# WIRE: TCP payload length (the "len" in patent tuple)` \
  -e tcp.hdr_len            `# WIRE: TCP header length (20 + options)` \
  -e tcp.urgent_pointer     `# WIRE: URG pointer (nonzero = suspicious)` \
  \
  -e tcp.options.mss_val        `# WIRE: max segment size (SYN only)` \
  -e tcp.options.wscale.shift   `# WIRE: window scale factor (SYN only)` \
  -e tcp.options.sack_perm      `# WIRE: SACK permitted (SYN only)` \
  -e tcp.options.timestamp.tsval `# WIRE: sender timestamp (clock fingerprint)` \
  -e tcp.options.timestamp.tsecr `# WIRE: echo reply timestamp (RTT signal)` \
  \
  -e tcp.analysis.retransmission          `# COMPUTED: requires stream state` \
  -e tcp.analysis.duplicate_ack           `# COMPUTED: requires stream state` \
  -e tcp.analysis.zero_window             `# COMPUTED: requires stream state` \
  -e tcp.analysis.window_update           `# COMPUTED: requires stream state` \
  -e tcp.analysis.fast_retransmission     `# COMPUTED: requires 3 dup ACK tracking` \
  -e tcp.analysis.spurious_retransmission `# COMPUTED: requires stream state` \
  -e tcp.analysis.out_of_order            `# COMPUTED: requires seq tracking` \
  -e tcp.analysis.initial_rtt             `# COMPUTED: SYN->SYN-ACK delta` \
  2>/dev/null
SCRIPT

chmod +x ~/cut-labs/lab1/extract_ek.sh
```

Run it and pretty-print the doc bodies:
```bash
cd ~/cut-labs/lab1
./extract_ek.sh handshake.pcap | awk 'NR%2==0' | python3 -c '
import sys, json
for line in sys.stdin:
    line = line.strip()
    if line:
        print(json.dumps(json.loads(line), indent=2))
        print("---")
' | head -120
```

The SYN packet (frame 1) is the richest — it contains the OS fingerprint (MSS, wscale, TCP options order, TTL, IP ID behavior). The trust engine would store this as a per-session baseline record keyed by the 4-tuple, linked to the pkey identity.

### 1.5c — Telemetry Pipeline: tshark → Confluent Cloud

This implements the patent's telemetry ingest path: relay extracts packet metadata → streaming platform → trust engine consumes. In production the relay would parse headers at the DPDK/libpcap layer, not tshark — but the pipeline architecture is identical.

```
tshark (WIRE+COMPUTED fields as CSV)
  → transform.py (CSV → keyed JSON)
    → produce.sh (file or stdin → Confluent Cloud)
      → Topic: packet-telemetry
        → Consumer: trust engine reads and scores
```

**Two assembly patterns from the same components:**
```
Slow path (file, any pcap size, demo-safe):
  extract_telemetry.sh pcap out.tsv → produce.sh out.tsv

Fast path (pipe, live capture, zero disk):
  tshark -l [...] | python3 -u transform.py | produce.sh
```

**Prerequisites:**
```bash
brew install kcat
kcat -V
```

**Create the topic on Confluent Cloud:**
```bash
confluent kafka topic create packet-telemetry --partitions 6 --config retention.ms=86400000 --config cleanup.policy=delete
```

**Confluent Cloud config:**

Create `~/cut-labs/lab1/confluent-packets-service.properties` with your credentials. Use `-F` only with kcat — never pass `-b` alongside `-F` (see Lessons Learned).
```
bootstrap.servers=pkc-921jm.us-east-2.aws.confluent.cloud:9092
security.protocol=SASL_SSL
sasl.mechanisms=PLAIN
sasl.username=YOUR_API_KEY
sasl.password=YOUR_API_SECRET
ssl.ca.location=/usr/local/etc/openssl@3/cert.pem
```

**Script 1 — transform.py** (CSV → keyed JSON, one job):
```bash
cat > ~/cut-labs/lab1/transform.py << 'SCRIPT'
import sys,json
F="src_ip src_port dst_ip dst_port timestamp_epoch ttl ip_id ip_len dscp ecn df ip_proto tcp_flags_hex tcp_flags_str seq_raw ack_raw win_value tcp_payload_len tcp_hdr_len urgent_ptr mss wscale ts_val ts_ecr is_retransmit is_zero_window initial_rtt".split()
I={"src_port","dst_port","ttl","ip_len","dscp","ecn","ip_proto","win_value","tcp_payload_len","tcp_hdr_len","urgent_ptr","mss","wscale"}
for l in sys.stdin:
    v=l.strip().split(",")
    if len(v)<4 or not v[0]:continue
    k=f"{v[0]}:{v[1]}-{v[2]}:{v[3]}"
    p={}
    for i,f in enumerate(F):
        if i<len(v) and v[i]:
            p[f]=int(v[i]) if f in I else v[i]
    print(f"{k}\t{json.dumps(p)}")
SCRIPT
```

**Script 2 — extract_telemetry.sh** (tshark + transform → file, one job):
```bash
cat > ~/cut-labs/lab1/extract_telemetry.sh << 'SCRIPT'
#!/bin/bash
PCAP="${1:?Usage: $0 <pcap_file> <output_file>}"
OUT="${2:?Usage: $0 <pcap_file> <output_file>}"

tshark -r "$PCAP" -T fields -E separator=, -E quote=n \
  -e ip.src -e tcp.srcport -e ip.dst -e tcp.dstport \
  -e frame.time_epoch -e ip.ttl -e ip.id -e ip.len \
  -e ip.dsfield.dscp -e ip.dsfield.ecn -e ip.flags.df \
  -e ip.proto -e tcp.flags -e tcp.flags.str \
  -e tcp.seq_raw -e tcp.ack_raw -e tcp.window_size_value \
  -e tcp.len -e tcp.hdr_len -e tcp.urgent_pointer \
  -e tcp.options.mss_val -e tcp.options.wscale.shift \
  -e tcp.options.timestamp.tsval -e tcp.options.timestamp.tsecr \
  -e tcp.analysis.retransmission -e tcp.analysis.zero_window \
  -e tcp.analysis.initial_rtt \
  2>/dev/null | python3 -c "$(cat "$(dirname "$0")/transform.py")" > "$OUT"

echo "$(wc -l < "$OUT" | tr -d ' ') messages → $OUT" >&2
SCRIPT
chmod +x ~/cut-labs/lab1/extract_telemetry.sh
```

**Script 3 — produce.sh** (file or stdin → Kafka, one job):
```bash
cat > ~/cut-labs/lab1/produce.sh << 'SCRIPT'
#!/bin/bash
CONF="$HOME/cut-labs/lab1/confluent-packets-service.properties"
TOPIC="packet-telemetry"

if [ -f "$1" ]; then
    echo "File mode: $1 → $TOPIC" >&2
    kcat -P -F "$CONF" -t "$TOPIC" -K '\t' -z snappy "$1"
    echo "$(wc -l < "$1" | tr -d ' ') messages produced" >&2
else
    echo "Pipe mode: stdin → $TOPIC (Ctrl-C to stop)" >&2
    kcat -P -F "$CONF" -t "$TOPIC" -K '\t' -z snappy
fi
SCRIPT
chmod +x ~/cut-labs/lab1/produce.sh
```

**Slow path — run against your Lab 1 capture:**
```bash
cd ~/cut-labs/lab1
./extract_telemetry.sh handshake.pcap telemetry.tsv && ./produce.sh telemetry.tsv
```

**Verify — consume from the topic:**
```bash
kcat -C -F ~/cut-labs/lab1/confluent-packets-service.properties -t packet-telemetry -o beginning -K '\t' -c 3
```

**Fast path — live capture (use in Lab 4 with WireGuard traffic):**
```bash
sudo tshark -i lo0 -f "tcp port 9999" -l -T fields -E separator=, -E quote=n -e ip.src -e tcp.srcport -e ip.dst -e tcp.dstport -e frame.time_epoch -e ip.ttl -e ip.id -e ip.len -e ip.dsfield.dscp -e ip.dsfield.ecn -e ip.flags.df -e ip.proto -e tcp.flags -e tcp.flags.str -e tcp.seq_raw -e tcp.ack_raw -e tcp.window_size_value -e tcp.len -e tcp.hdr_len -e tcp.urgent_pointer -e tcp.options.mss_val -e tcp.options.wscale.shift -e tcp.options.timestamp.tsval -e tcp.options.timestamp.tsecr -e tcp.analysis.retransmission -e tcp.analysis.zero_window -e tcp.analysis.initial_rtt 2>/dev/null | python3 -u ~/cut-labs/lab1/transform.py | ./produce.sh
```

**Production pipeline architecture note:**

In the lab: `tshark → python → kcat → Confluent Cloud`. This proves the data model.

In production the relay would NOT use tshark. The path would be:

```
NIC → DPDK/XDP (zero-copy packet read)
  → C header parser (20 lines, WIRE fields only)
    → librdkafka producer (direct to Kafka, batched, compressed)
      → Confluent Cloud / self-hosted Kafka
        → Flink or ksqlDB (streaming COMPUTED analysis + trust scoring)
          → ClickHouse (historical queries + forensics)
```

tshark is the full Wireshark dissector engine — hundreds of protocol parsers, stream reassembly, the entire `tcp.analysis.*` state machine. A production relay would never run it in the data path. You'd parse IP/TCP headers directly off raw packets at the libpcap or DPDK layer (~20 lines of C) and push WIRE tuples into Kafka via librdkafka. The Kafka topic schema, partitioning strategy (key by 4-tuple), and downstream consumers stay the same regardless of the extraction layer.

### 1.6 — DTrace: Kernel-Side Connection Events

> **SIP Note:** On modern macOS (Catalina+), System Integrity Protection restricts dtrace. To use kernel probes, you need to boot into Recovery Mode and run `csrutil enable --without dtrace`. For interview prep, the userspace probes below work without SIP changes.

```bash
# Trace TCP connections — userspace-safe (no SIP changes needed)
# This captures what the CUT agent would see at the loopback
sudo dtrace -n '
syscall::connect:entry
/pid != $pid && arg1 != 0/
{
    this->s = copyin(arg1, 16);
    this->port = ntohs(*(uint16_t *)(this->s + 2));
    this->addr = ntohl(*(uint32_t *)(this->s + 4));
    printf("CONNECT pid=%d proc=%s dst=%d.%d.%d.%d:%d",
        pid, execname,
        (this->addr >> 24) & 0xff,
        (this->addr >> 16) & 0xff,
        (this->addr >> 8) & 0xff,
        this->addr & 0xff,
        this->port);
}

syscall::connect:return
/errno == 0/
{
    printf("CONNECT_OK pid=%d proc=%s", pid, execname);
}
'
```

Run the `nc` connection again in another terminal. DTrace output shows the kernel-level event that the CUT agent would capture as an ambient authentication factor (process identity, connection target, timestamp).

### 1.7 — Interview Talking Points

- The ISN is generated by the kernel's TCP stack (macOS uses a randomized ISN per RFC 6528). The CUT patent doesn't claim ISN tracking explicitly, but the relay receives `{src/dest/len/timestamp}` on every packet — ISN correlation is a natural extension for ambient behavioral analysis.
- The agent hooks into the loopback (exactly what we captured on `lo0`), which means it sees all local application traffic before encryption.
- DTrace/eBPF on the endpoint is how you'd implement the "ambient factor" collection described in the patent — process name, connection metadata, timestamps — all without requiring the application to call any SDK.
- The telemetry pipeline maps to production infrastructure: tshark (lab) → DPDK/XDP + C parser (production) for extraction; Kafka for ingest with 4-tuple as message key (partition affinity guarantees per-session ordering); Flink/ksqlDB for streaming COMPUTED analysis and real-time trust scoring; ClickHouse for historical forensics. tshark's native ES output proves the data model but would never run in the relay's data path.
- The WIRE vs COMPUTED field distinction maps directly to the patent's relay/engine separation: the relay (element 114) is stateless and extracts WIRE fields at line rate; the engine (element 112) is stateful and computes derived fields for trust scoring.

---

## Lab 2: mTLS Interception Proxy (The Relay/Middlebox)

**Time: ~90 minutes**
**Patent link:** The CUT core network sits between agent and daemon. All traffic passes through the relay. This lab builds a local mTLS proxy that creates the "two TCP sessions" split — exactly the architecture in FIG. 1.

### 2.1 — Build the Local PKI

```bash
cd ~/cut-labs/lab2

# === ROOT CA ===
# Generate CA private key
openssl genpkey -algorithm RSA -out ca.key -pkeyopt rsa_keygen_bits:4096

# Generate self-signed CA certificate (valid 1 year)
openssl req -new -x509 -key ca.key -out ca.crt -days 365 \
  -subj "/CN=CUT Lab CA/O=Lab/C=US"

# === SERVER CERTIFICATE ===
# Generate server key
openssl genpkey -algorithm RSA -out server.key -pkeyopt rsa_keygen_bits:2048

# Generate server CSR
openssl req -new -key server.key -out server.csr \
  -subj "/CN=localhost/O=Lab Server/C=US"

# Sign server cert with CA (add SAN for localhost)
cat > server_ext.cnf << 'EOF'
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = localhost
IP.1 = 127.0.0.1
EOF

openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out server.crt -days 365 -extfile server_ext.cnf

# === CLIENT CERTIFICATE (the mTLS piece) ===
openssl genpkey -algorithm RSA -out client.key -pkeyopt rsa_keygen_bits:2048

openssl req -new -key client.key -out client.csr \
  -subj "/CN=CUT Agent/O=Lab Client/C=US"

cat > client_ext.cnf << 'EOF'
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature
extendedKeyUsage = clientAuth
EOF

openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out client.crt -days 365 -extfile client_ext.cnf

# === JAVA KEYSTORE (for the Java client in 2.4) ===
# Convert client cert + key to PKCS12
openssl pkcs12 -export -in client.crt -inkey client.key \
  -out client.p12 -name "cut-agent" -password pass:changeit

# Import CA cert into a truststore
keytool -importcert -alias cut-ca -file ca.crt \
  -keystore truststore.jks -storepass changeit -noprompt

# Verify the chain
echo "=== CA ===" && openssl x509 -in ca.crt -noout -subject -issuer
echo "=== Server ===" && openssl x509 -in server.crt -noout -subject -issuer
echo "=== Client ===" && openssl x509 -in client.crt -noout -subject -issuer
```

### 2.2 — Stand Up a Simple TLS Server (the "daemon")

Terminal 1:
```bash
# openssl s_server as the target service (the daemon in patent terms)
# -Verify 1 = require client certificate (mTLS)
# -CAfile  = trust our lab CA for validating the client cert
openssl s_server -accept 8443 \
  -cert server.crt -key server.key \
  -CAfile ca.crt \
  -Verify 1 \
  -msg
```

### 2.3 — Start mitmproxy as the Relay

Terminal 2:
```bash
# mitmdump in reverse proxy mode, forwarding to the server on 8443
# --set client_certs=client.crt  = present client cert upstream (mTLS)
# Listens on 8080 by default

# First, install mitmproxy CA cert into the system (or use --ssl-insecure for lab)
mitmdump --mode reverse:https://localhost:8443/ \
  --set ssl_insecure=true \
  --set client_certs=~/cut-labs/lab2/client.p12 \
  --listen-port 8080 \
  -v
```

> **Note:** mitmproxy's `client_certs` for upstream mTLS may need a directory-based setup for some versions. If the above errors, try:
> ```bash
> mkdir -p ~/cut-labs/lab2/client_certs
> # Create a file named by the upstream hostname
> cat client.key client.crt > ~/cut-labs/lab2/client_certs/localhost.pem
> mitmdump --mode reverse:https://localhost:8443/ \
>   --set ssl_insecure=true \
>   --set client_certs=~/cut-labs/lab2/client_certs/ \
>   --listen-port 8080 -v
> ```

### 2.4 — Capture Both Sides Simultaneously

Terminal 3 (client-side capture):
```bash
# Capture traffic between client and proxy (port 8080)
sudo tcpdump -S -tttt -nn -v -i lo0 'tcp port 8080' \
  -w ~/cut-labs/lab2/client_to_proxy.pcap
```

Terminal 4 (server-side capture):
```bash
# Capture traffic between proxy and server (port 8443)
sudo tcpdump -S -tttt -nn -v -i lo0 'tcp port 8443' \
  -w ~/cut-labs/lab2/proxy_to_server.pcap
```

### 2.5 — Send Traffic Through the Proxy

Terminal 5:
```bash
# Simple curl through the proxy
curl -v http://localhost:8080/ 2>&1 | head -30

# OR: Java client with mTLS (more interview-relevant)
```

Create `~/cut-labs/lab2/MTLSClient.java`:
```java
import javax.net.ssl.*;
import java.io.*;
import java.security.*;
import java.security.cert.*;

public class MTLSClient {
    public static void main(String[] args) throws Exception {
        // Load client keystore (PKCS12 with client cert + key)
        KeyStore ks = KeyStore.getInstance("PKCS12");
        ks.load(new FileInputStream("client.p12"), "changeit".toCharArray());
        KeyManagerFactory kmf = KeyManagerFactory.getInstance("SunX509");
        kmf.init(ks, "changeit".toCharArray());

        // Load truststore (CA cert)
        KeyStore ts = KeyStore.getInstance("JKS");
        ts.load(new FileInputStream("truststore.jks"), "changeit".toCharArray());
        TrustManagerFactory tmf = TrustManagerFactory.getInstance("SunX509");
        tmf.init(ts);

        // Build SSL context with both client auth and server trust
        SSLContext ctx = SSLContext.getInstance("TLSv1.3");
        ctx.init(kmf.getKeyManagers(), tmf.getTrustManagers(), null);

        // Connect directly to the server (bypassing proxy for cert verification)
        SSLSocketFactory sf = ctx.getSocketFactory();
        try (SSLSocket sock = (SSLSocket) sf.createSocket("localhost", 8443)) {
            sock.startHandshake();

            // Show the negotiated session
            SSLSession session = sock.getSession();
            System.out.println("Protocol: " + session.getProtocol());
            System.out.println("Cipher:   " + session.getCipherSuite());
            System.out.println("Server cert CN: " +
                ((java.security.cert.X509Certificate) session.getPeerCertificates()[0])
                    .getSubjectX500Principal().getName());

            // Send data
            OutputStream out = sock.getOutputStream();
            out.write("GET / HTTP/1.0\r\nHost: localhost\r\n\r\n".getBytes());
            out.flush();

            // Read response
            BufferedReader in = new BufferedReader(
                new InputStreamReader(sock.getInputStream()));
            String line;
            while ((line = in.readLine()) != null) System.out.println(line);
        }
    }
}
```

```bash
cd ~/cut-labs/lab2
javac MTLSClient.java
java MTLSClient
```

### 2.6 — Stop captures, compare ISNs across the proxy boundary

```bash
echo "=== CLIENT -> PROXY (port 8080) — SYN packets ==="
tcpdump -S -tttt -nn -r ~/cut-labs/lab2/client_to_proxy.pcap \
  'tcp[tcpflags] & (tcp-syn) != 0' 2>/dev/null

echo ""
echo "=== PROXY -> SERVER (port 8443) — SYN packets ==="
tcpdump -S -tttt -nn -r ~/cut-labs/lab2/proxy_to_server.pcap \
  'tcp[tcpflags] & (tcp-syn) != 0' 2>/dev/null
```

**What you'll see:** The ISNs on the client↔proxy session are completely independent from the proxy↔server session. This is the "two TCP sessions" problem — the relay breaks ISN continuity. In the patent's architecture, this is by design: the relay only sees `{src/dest/len/timestamp}`, never the plaintext content.

### 2.7 — Probe mTLS Negotiation with openssl s_client

```bash
# Direct connection to server — shows full mTLS handshake
openssl s_client -connect localhost:8443 \
  -cert client.crt -key client.key \
  -CAfile ca.crt \
  -state -debug 2>&1 | grep -E "(SSL_connect|Certificate|Verify)"
```

### 2.8 — Interview Talking Points

- The CUT relay is architecturally equivalent to this mTLS proxy — it terminates the agent's connection and opens a new one to the daemon. Two independent TCP sessions, two independent ISN spaces.
- mTLS is essential for zero-trust: both sides authenticate. The patent's `{user/pass/src/pkey}` message at session setup is the mTLS client cert exchange in practice.
- The relay extracts metadata (`len`, `timestamp`, `request_body_hash`) without decrypting content — exactly what we observed: tcpdump on each side shows different ISNs but the relay can see packet sizes and timing.

---

## Lab 3: TCP Zero Window (Performance Choke / Trust Signal)

**Time: ~60 minutes**
**Patent link:** The continuous trust engine monitors telemetry for anomalies. A zero-window condition (flow stall) would appear as `len` dropping to zero and timestamp gaps in the `{src/dest/len/timestamp}` stream — a signal that could trigger an authentication step-up or session block.

### 3.1 — Record Current Buffer Settings

```bash
# Save current values to restore later
sysctl net.inet.tcp.recvspace
sysctl net.inet.tcp.sendspace
# Typical defaults: recvspace=131072, sendspace=131072
```

### 3.2 — Build the Stalling Server (Java)

Create `~/cut-labs/lab3/StallServer.java`:
```java
import java.net.*;
import java.io.*;

public class StallServer {
    public static void main(String[] args) throws Exception {
        int port = 7777;
        int stallSeconds = Integer.parseInt(
            args.length > 0 ? args[0] : "15");
        int recvSize = Integer.parseInt(
            args.length > 1 ? args[1] : "64");
        int recvDelay = Integer.parseInt(
            args.length > 2 ? args[2] : "100"); // ms between reads

        ServerSocket ss = new ServerSocket();
        // Set a tiny receive buffer BEFORE bind
        ss.setReceiveBufferSize(4096);
        ss.bind(new InetSocketAddress("127.0.0.1", port));
        System.out.printf("Listening on %d (rcvbuf=%d)%n",
            port, ss.getReceiveBufferSize());

        try (Socket client = ss.accept()) {
            System.out.printf("Accepted. Stalling for %d seconds...%n",
                stallSeconds);

            // PHASE 1: Complete stall — don't read at all
            // Kernel buffer fills, window closes -> [TCP ZeroWindow]
            Thread.sleep(stallSeconds * 1000L);

            // PHASE 2: Slow reader — simulates choking DPI engine
            System.out.printf("Waking up. Slow read: %d bytes every %d ms%n",
                recvSize, recvDelay);
            InputStream in = client.getInputStream();
            byte[] buf = new byte[recvSize];
            int totalRead = 0;
            int n;
            while ((n = in.read(buf)) != -1) {
                totalRead += n;
                System.out.printf("Read %d bytes (total: %d)%n", n, totalRead);
                Thread.sleep(recvDelay);
            }
            System.out.printf("Connection closed. Total read: %d bytes%n",
                totalRead);
        }
        ss.close();
    }
}
```

### 3.3 — Build the Fast Sender (Java)

Create `~/cut-labs/lab3/FloodSender.java`:
```java
import java.net.*;
import java.io.*;

public class FloodSender {
    public static void main(String[] args) throws Exception {
        String host = "127.0.0.1";
        int port = 7777;
        int chunkSize = 8192;
        int totalMB = 2; // send 2MB total

        try (Socket sock = new Socket(host, port)) {
            // Set a large send buffer
            sock.setSendBufferSize(65536);
            System.out.printf("Connected. Sending %d MB in %d-byte chunks%n",
                totalMB, chunkSize);

            OutputStream out = sock.getOutputStream();
            byte[] data = new byte[chunkSize];
            java.util.Arrays.fill(data, (byte) 'X');

            long totalSent = 0;
            long target = totalMB * 1024L * 1024L;
            long start = System.currentTimeMillis();

            while (totalSent < target) {
                try {
                    out.write(data);
                    totalSent += chunkSize;
                    if (totalSent % (256 * 1024) == 0) {
                        long elapsed = System.currentTimeMillis() - start;
                        System.out.printf("Sent %d KB in %d ms%n",
                            totalSent / 1024, elapsed);
                    }
                } catch (IOException e) {
                    System.out.printf("Write blocked/failed at %d KB: %s%n",
                        totalSent / 1024, e.getMessage());
                    break;
                }
            }
            long elapsed = System.currentTimeMillis() - start;
            System.out.printf("Done. Sent %d KB in %d ms%n",
                totalSent / 1024, elapsed);
        }
    }
}
```

### 3.4 — Compile

```bash
cd ~/cut-labs/lab3
javac StallServer.java FloodSender.java
```

### 3.5 — Shrink Receive Buffer (optional, accelerates zero-window)

```bash
# Shrink to 4KB to trigger zero window faster
sudo sysctl -w net.inet.tcp.recvspace=4096
```

### 3.6 — Run the Experiment

Terminal 1 — Capture:
```bash
sudo tcpdump -S -tttt -nn -v -i lo0 'tcp port 7777' \
  -w ~/cut-labs/lab3/zerowindow.pcap
```

Terminal 2 — Start server (stall 15s, then slow-read 64 bytes every 100ms):
```bash
cd ~/cut-labs/lab3
java StallServer 15 64 100
```

Terminal 3 — Start sender:
```bash
cd ~/cut-labs/lab3
java FloodSender
```

**Observe:** The sender will block after a few KB. That's the TCP flow control kicking in.

### 3.7 — Stop capture after sender completes, analyze

```bash
# Find the Zero Window advertisement
tcpdump -S -tttt -nn -v -r ~/cut-labs/lab3/zerowindow.pcap | \
  grep -i "win 0"
```

**What you're looking for:**
```
# Server advertises zero window — buffer full, can't accept more data
... 127.0.0.1.7777 > 127.0.0.1.xxxxx: Flags [.], ack ..., win 0, ...
                                                                ^^^^^
                                                        ZERO WINDOW — buffer exhausted

# Client sends Window Probes (periodic keepalives to check if window opened)
... 127.0.0.1.xxxxx > 127.0.0.1.7777: Flags [.], ack ..., win 65535, ...

# After server wakes up: window recovery sawtooth
... 127.0.0.1.7777 > 127.0.0.1.xxxxx: Flags [.], ack ..., win 128, ...
... 127.0.0.1.7777 > 127.0.0.1.xxxxx: Flags [.], ack ..., win 256, ...
... 127.0.0.1.7777 > 127.0.0.1.xxxxx: Flags [.], ack ..., win 512, ...
```

### 3.8 — Extract Telemetry Anomaly Timeline

```bash
# Show timestamp gaps during zero-window period
tcpdump -S -tttt -nn -r ~/cut-labs/lab3/zerowindow.pcap | \
  awk '{
    ts = $1 " " $2;
    if (match($0, /win [0-9]+/)) {
      win = substr($0, RSTART+4, RLENGTH-4);
    } else { win = "?" }
    len_match = match($0, /length [0-9]+/);
    len = (len_match ? substr($0, RSTART+7, RLENGTH-7) : "0");
    printf "%s  win=%-6s  len=%s\n", ts, win, len
  }' | head -50
```

### 3.9 — Restore Buffer Settings

```bash
sudo sysctl -w net.inet.tcp.recvspace=131072
# Verify
sysctl net.inet.tcp.recvspace
```

### 3.10 — Interview Talking Points

- A DPI engine that can't keep up creates exactly this pattern: window closes, flow stalls, then recovers in a sawtooth. The patent's time-series DB would capture this as a `len=0` gap followed by erratic `timestamp` deltas.
- The continuous trust engine could interpret this as an anomaly signal: legitimate service responses don't stall like this. Could trigger authentication step-up ("is this still the same user?") or session review.
- In the CUT architecture, this would be visible at the relay level — you don't need to decrypt content to see that data flow has stopped.

---

## Lab 4: WireGuard Tunnel on macOS (The Patent's Relay)

**Time: ~75 minutes** (includes NAT simulation)
**Patent link:** The patent explicitly names WireGuard as the relay implementation: "a relay 114 (such as Wireguard™, a secure VPN protocol and tunneling software) through which traffic flows pass." The pkey is used for both encryption AND identity validation.

### 4.1 — Verify Installation

```bash
# wireguard-tools gives you wg and wg-quick
# wireguard-go provides the userspace implementation for macOS utun interfaces
which wg
which wireguard-go
```

### 4.2 — Generate Keys

```bash
cd ~/cut-labs/lab4

# Peer A (simulating the "agent" side)
wg genkey | tee agent_private.key | wg pubkey > agent_public.key

# Peer B (simulating the "daemon" side)
wg genkey | tee daemon_private.key | wg pubkey > daemon_public.key

# Display keys (you'll need these for config)
echo "Agent private:  $(cat agent_private.key)"
echo "Agent public:   $(cat agent_public.key)"
echo "Daemon private: $(cat daemon_private.key)"
echo "Daemon public:  $(cat daemon_public.key)"
```

### 4.3 — Create WireGuard Configs

Since we're on a single machine, we'll create two interfaces on different ports with a point-to-point subnet.

```bash
# Agent interface config (wg-agent)
cat > ~/cut-labs/lab4/wg-agent.conf << EOF
[Interface]
PrivateKey = $(cat agent_private.key)
ListenPort = 51820
Address = 10.0.0.1/24

[Peer]
PublicKey = $(cat daemon_public.key)
AllowedIPs = 10.0.0.2/32
Endpoint = 127.0.0.1:51821
EOF

# Daemon interface config (wg-daemon)
cat > ~/cut-labs/lab4/wg-daemon.conf << EOF
[Interface]
PrivateKey = $(cat daemon_private.key)
ListenPort = 51821
Address = 10.0.0.2/24

[Peer]
PublicKey = $(cat agent_public.key)
AllowedIPs = 10.0.0.1/32
Endpoint = 127.0.0.1:51820
EOF
```

### 4.4 — Bring Up the Tunnel

```bash
# Start both interfaces
# wg-quick on macOS creates utun interfaces automatically
sudo wg-quick up ~/cut-labs/lab4/wg-agent.conf
sudo wg-quick up ~/cut-labs/lab4/wg-daemon.conf

# Verify interfaces
ifconfig | grep -A 3 utun

# Verify WireGuard status
sudo wg show
```

**Expected output from `wg show`:**
```
interface: utun4
  public key: <agent_public_key>
  private key: (hidden)
  listening port: 51820

  peer: <daemon_public_key>
    endpoint: 127.0.0.1:51821
    allowed ips: 10.0.0.2/32

interface: utun5
  public key: <daemon_public_key>
  ...
```

### 4.5 — Test Connectivity

```bash
# Ping through the tunnel
ping -c 3 10.0.0.2
```

### 4.6 — The Money Shot: Dual tcpdump

This is the core demonstration — same traffic, two views.

Terminal 1 — Capture on the physical interface (what an eavesdropper/relay sees):
```bash
# en0 or lo0 depending on your tunnel routing
# Since both peers are local, WireGuard uses UDP on lo0
sudo tcpdump -S -tttt -nn -v -i lo0 'udp port 51820 or udp port 51821' \
  -w ~/cut-labs/lab4/physical.pcap
```

Terminal 2 — Capture on the WireGuard tunnel interface (cleartext):
```bash
# Find your utun interface numbers from ifconfig output
# Capture on the agent's utun
sudo tcpdump -S -tttt -nn -v -i utun4 \
  -w ~/cut-labs/lab4/tunnel.pcap
```

> **Note:** Replace `utun4` with your actual interface. Check with `ifconfig | grep utun`.

Terminal 3 — Generate traffic through the tunnel:
```bash
# TCP handshake through the tunnel
nc -l 10.0.0.2 9999 &
echo "CUT_THROUGH_WIREGUARD" | nc 10.0.0.2 9999
```

### 4.7 — Compare the Two Captures

```bash
echo "=== PHYSICAL INTERFACE (encrypted UDP) ==="
tcpdump -S -tttt -nn -v -r ~/cut-labs/lab4/physical.pcap | head -20

echo ""
echo "=== TUNNEL INTERFACE (cleartext TCP) ==="
tcpdump -S -tttt -nn -v -r ~/cut-labs/lab4/tunnel.pcap | head -20
```

**What you'll see:**

Physical (`lo0`): UDP packets between `127.0.0.1:51820` and `127.0.0.1:51821`. Payload is encrypted — no TCP headers, no ISNs, no content visible. Just `{src/dest/len/timestamp}`.

Tunnel (`utun4`): Full TCP handshake between `10.0.0.1` and `10.0.0.2` with ISNs, window sizes, and cleartext payload. This is what the endpoint sees after decryption.

### 4.8 — Re-run Lab 1 Through the Tunnel

```bash
# Listener on daemon side of tunnel
nc -l 10.0.0.2 9999 &

# Capture on tunnel interface (ISNs visible)
sudo tcpdump -S -tttt -nn -i utun4 'tcp port 9999' &

# Capture on physical interface (ISNs hidden)
sudo tcpdump -S -tttt -nn -i lo0 'udp port 51820 or udp port 51821' &

# Connect
echo "ISN_VISIBLE_HERE" | nc 10.0.0.2 9999

# Wait, then kill background captures
sleep 2 && kill %2 %3 2>/dev/null
```

### 4.9 — Extract and Compare Relay Metadata

```bash
# Physical interface: relay can only extract this
# NOTE: UDP on lo0 uses $4/$6 (BSD loopback offset)
tcpdump -tttt -nn -r ~/cut-labs/lab4/physical.pcap | \
  awk '{printf "{src: %s, dest: %s, len: UDP_ENCRYPTED, ts: %s %s}\n",
    $4, $6, $1, $2}' | head -10

echo "---"

# Tunnel interface: endpoint can extract everything
# NOTE: utun interfaces do NOT have the BSD IP token shift
tcpdump -S -tttt -nn -r ~/cut-labs/lab4/tunnel.pcap | \
  awk '{
    len_match = match($0, /length [0-9]+/);
    len = (len_match ? substr($0, RSTART+7, RLENGTH-7) : "0");
    printf "{src: %s, dest: %s, len: %s, ts: %s %s}\n",
      $3, $5, len, $1, $2}' | head -10
```

> **Interface-dependent field offsets:** `lo0` (NULL link-type) adds the `IP` token → use `$4/$6`. `utun*` and `en0` (no extra token) → use `$3/$5`. Always check with a raw `tcpdump -r | head -3` first.

### 4.10 — NAT Simulation via pfctl

The 4-tuple `{src_ip, src_port, dst_ip, dst_port}` is NOT a stable session key — NAT rewrites it at every boundary. This step uses macOS's `pf` firewall to simulate a NAT rebind (what happens when a user roams from WiFi to cellular) and proves the WireGuard tunnel survives purely on pkey identity.

Create `~/cut-labs/lab4/nat_simulation.sh`:
```bash
cat > ~/cut-labs/lab4/nat_simulation.sh << 'SCRIPT'
#!/bin/bash
# CUT Lab 4 Extension: NAT Simulation via pfctl
# Demonstrates 4-tuple breaking while WireGuard tunnel stays up
#
# What this does:
#   1. Captures baseline WireGuard traffic (original 4-tuple)
#   2. Inserts a pf NAT rule that rewrites the agent's source port
#   3. Captures post-NAT traffic (new 4-tuple)
#   4. Verifies tunnel survives (pkey identity is durable)
#
# Prerequisites: Lab 4 WireGuard tunnel already up (wg-agent, wg-daemon)

set -e

PF_CONF="/tmp/cut-lab-nat.conf"
PCAP_DIR="$HOME/cut-labs/lab4"

echo "=== Phase 1: Baseline capture (no NAT) ==="
echo "Pinging through tunnel to establish baseline..."
ping -c 2 10.0.0.2 > /dev/null 2>&1

echo "Capturing baseline traffic..."
sudo tcpdump -S -tttt -nn -i lo0 'udp port 51820 or udp port 51821' \
  -w "$PCAP_DIR/before_nat.pcap" -c 20 &
TCPDUMP_PID=$!
ping -c 3 10.0.0.2 > /dev/null 2>&1
sleep 2
sudo kill $TCPDUMP_PID 2>/dev/null
wait $TCPDUMP_PID 2>/dev/null

echo ""
echo "Baseline 4-tuple:"
tcpdump -tttt -nn -r "$PCAP_DIR/before_nat.pcap" 2>/dev/null | \
  awk '{printf "  %s → %s\n", $4, $6}' | sort -u

echo ""
echo "=== Phase 2: Enable NAT (simulate roam) ==="

# pf NAT rule: rewrite agent's WireGuard source port
# Simulates what happens when a home router's NAT table changes
cat > "$PF_CONF" << 'PF'
nat on lo0 proto udp from 127.0.0.1 port 51820 to 127.0.0.1 port 51821 -> 127.0.0.1 port 61820
PF

echo "Loading pf NAT rule..."
sudo pfctl -f "$PF_CONF" -e 2>/dev/null || sudo pfctl -f "$PF_CONF" 2>/dev/null

echo "Capturing post-NAT traffic..."
sudo tcpdump -S -tttt -nn -i lo0 \
  'udp port 51820 or udp port 51821 or udp port 61820' \
  -w "$PCAP_DIR/after_nat.pcap" -c 20 &
TCPDUMP_PID=$!

echo "Pinging through tunnel (should still work — pkey survives NAT)..."
ping -c 3 10.0.0.2
PING_EXIT=$?

sleep 2
sudo kill $TCPDUMP_PID 2>/dev/null
wait $TCPDUMP_PID 2>/dev/null

echo ""
echo "Post-NAT 4-tuple:"
tcpdump -tttt -nn -r "$PCAP_DIR/after_nat.pcap" 2>/dev/null | \
  awk '{printf "  %s → %s\n", $4, $6}' | sort -u

echo ""
echo "=== Phase 3: Compare ==="
echo ""
echo "--- BEFORE NAT (original 4-tuple) ---"
tcpdump -tttt -nn -r "$PCAP_DIR/before_nat.pcap" 2>/dev/null | \
  awk '{printf "{src: %s, dst: %s}\n", $4, $6}' | sort -u

echo ""
echo "--- AFTER NAT (rewritten 4-tuple) ---"
tcpdump -tttt -nn -r "$PCAP_DIR/after_nat.pcap" 2>/dev/null | \
  awk '{printf "{src: %s, dst: %s}\n", $4, $6}' | sort -u

echo ""
echo "=== Phase 4: Verify tunnel identity ==="
echo ""
echo "WireGuard status (pkey unchanged despite NAT):"
sudo wg show | grep -E "(public key|endpoint|latest handshake)"

echo ""
if [ $PING_EXIT -eq 0 ]; then
    echo "RESULT: Tunnel SURVIVED NAT rewrite"
    echo "  → 4-tuple changed (physical layer)"
    echo "  → pkey unchanged (identity layer)"
    echo "  → Trust engine sees: roam event, evaluate ambient factors"
else
    echo "RESULT: Tunnel broken by NAT — WireGuard will re-handshake using pkey"
    echo "  → New 4-tuple, same identity"
    echo "  → Trust engine sees: reconnect event, higher scrutiny"
fi

echo ""
echo "=== Phase 5: Cleanup ==="
sudo pfctl -d 2>/dev/null
sudo rm -f "$PF_CONF"
echo "NAT rule removed, pf disabled"
SCRIPT

chmod +x ~/cut-labs/lab4/nat_simulation.sh
```

Run it (tunnel must be up from step 4.4):
```bash
cd ~/cut-labs/lab4
./nat_simulation.sh
```

**What the trust engine sees during a NAT/roam event:**

| Signal | Before Roam | After Roam | Trust Impact |
|--------|-------------|------------|-------------|
| pkey | `WG_PUBLIC_KEY` | `WG_PUBLIC_KEY` (same) | None — identity stable |
| src_ip:port | `73.214.x.x:32847` | `174.198.x.x:51003` | Roam event flagged |
| Ambient factors (device, process list) | Baseline | If unchanged → legitimate roam | Confirms identity |
| Ambient factors (device, process list) | Baseline | If changed → possible hijack | Step-up or BLOCK |
| tsval clock progression | Continuous | If gap + reset → new device | Step-up to biometric |
| Geo inference from IP | Home city | Same city → commute roam | Minimal impact |
| Geo inference from IP | Home city | Different country | BLOCK |

### 4.11 — Tear Down

```bash
sudo wg-quick down ~/cut-labs/lab4/wg-agent.conf
sudo wg-quick down ~/cut-labs/lab4/wg-daemon.conf

# Verify interfaces are gone
ifconfig | grep utun
```

### 4.12 — Interview Talking Points

- This IS the patent's relay — WireGuard is named explicitly. The pkey serves double duty: encryption and identity validation. The patent says the agent sends `{user/pass/src/pkey}` at session setup.
- The physical interface capture shows exactly what the relay sees: encrypted UDP blobs with metadata only. ISNs, payload, and application-layer data are invisible. This is the "content encrypted end-to-end, relay sees only metadata" architecture.
- The WireGuard public key provides a durable identity anchor — even if the user's IP changes (mobile roaming), the pkey stays constant. The patent's trust engine can correlate sessions across network transitions using this.
- NAT breaks the 4-tuple but NOT the pkey identity. The trust engine treats tuple changes as roam events — signals to evaluate, not failures to reject. Correlation with ambient factors (device fingerprint, tsval clock continuity, process list) distinguishes legitimate roaming from session hijacking.
- The index hierarchy for telemetry is: Entity (pkey) → Circle (security policy) → Network identity (observed src_ip, changes with NAT) → Session (4-tuple, ephemeral) → Packets (time-series). The pkey is the join key across all layers.

---

## Lab 5: eBPF / DTrace — Kernel-Level Telemetry (The Patent's Agent)

**Time: ~90 minutes**
**Patent link:** The agent "has the capability to monitor 'ambient' factors that operate in the background" including "device characteristics, operating system, installed applications, a list of then-running processes on a device." This is kernel-level telemetry collection — exactly what eBPF/dtrace enables.

### 5.1 — macOS: DTrace TCP Connection Tracer

> **SIP Status:** The following script uses `syscall` provider which works on most macOS versions even with SIP enabled. For `fbt` (kernel function boundary) probes, SIP must be partially disabled.

Create `~/cut-labs/lab5/tcp_telemetry.d`:
```d
#!/usr/sbin/dtrace -s

/*
 * CUT Agent Telemetry Collector — DTrace
 * Captures ambient factors: process identity, connection metadata, timestamps
 * Mirrors the patent's agent functionality on macOS
 */

#pragma D option quiet

dtrace:::BEGIN
{
    printf("%-20s %-6s %-16s %-6s %-6s %s\n",
        "TIMESTAMP", "PID", "PROCESS", "EVENT", "FD", "DETAILS");
    printf("%-20s %-6s %-16s %-6s %-6s %s\n",
        "--------------------", "------", "----------------",
        "------", "------", "-------");
}

/* Trace socket creation */
syscall::socket:return
/arg1 >= 0/
{
    printf("%-20Y %-6d %-16s %-6s %-6d domain=%d type=%d\n",
        walltimestamp, pid, execname, "SOCK", (int)arg1,
        (int)self->domain, (int)self->type);
}

syscall::socket:entry
{
    self->domain = arg0;
    self->type = arg1;
}

/* Trace connect() calls */
syscall::connect:entry
{
    self->connfd = arg0;
}

syscall::connect:return
/arg1 == 0/
{
    printf("%-20Y %-6d %-16s %-6s %-6d status=OK\n",
        walltimestamp, pid, execname, "CONN", (int)self->connfd);
}

syscall::connect:return
/arg1 != 0/
{
    printf("%-20Y %-6d %-16s %-6s %-6d status=ERR(%d)\n",
        walltimestamp, pid, execname, "CONN", (int)self->connfd, errno);
}

/* Trace data transfer */
syscall::write:entry
/fds[arg0].fi_fs == "sockfs" || arg0 > 2/
{
    self->writefd = arg0;
    self->writelen = arg2;
}

syscall::write:return
/self->writelen > 0 && arg1 > 0/
{
    printf("%-20Y %-6d %-16s %-6s %-6d bytes=%d\n",
        walltimestamp, pid, execname, "SEND", (int)self->writefd,
        (int)arg1);
    self->writelen = 0;
}

syscall::read:return
/arg1 > 0 && arg0 > 2/
{
    printf("%-20Y %-6d %-16s %-6s %-6d bytes=%d\n",
        walltimestamp, pid, execname, "RECV", (int)arg0, (int)arg1);
}
```

```bash
# Run the tracer
cd ~/cut-labs/lab5
sudo dtrace -s tcp_telemetry.d
```

In another terminal, generate traffic:
```bash
echo "DTRACE_TEST" | nc 127.0.0.1 9999
# (start a listener first: nc -l 127.0.0.1 9999)
```

**Expected output — this is what the CUT agent collects:**
```
TIMESTAMP            PID    PROCESS          EVENT  FD     DETAILS
2026-03-10 14:45:01  12345  nc               SOCK   5      domain=2 type=1
2026-03-10 14:45:01  12345  nc               CONN   5      status=OK
2026-03-10 14:45:01  12345  nc               SEND   5      bytes=12
```

Process name (`nc`), PID, file descriptor, byte count, timestamp — these are exactly the "ambient factors" the patent describes.

### 5.2 — Linux: eBPF TCP Telemetry (Docker)

```bash
# Pull a Linux image with BCC/bpftrace tools
docker pull ubuntu:22.04

# Run with required privileges for eBPF
docker run -it --privileged \
  --pid=host \
  -v ~/cut-labs/lab5:/lab \
  --name ebpf-lab \
  ubuntu:22.04 /bin/bash
```

Inside the container:
```bash
# Install eBPF toolchain
apt-get update && apt-get install -y \
  bpfcc-tools bpftrace linux-headers-$(uname -r) \
  python3-bpfcc netcat-openbsd iproute2 2>/dev/null

# If linux-headers aren't available (Docker), bpftrace still works for
# many tracepoints. Try:
apt-get install -y bpftrace
```

Create `/lab/tcp_agent.bt` (bpftrace script):
```c
#!/usr/bin/env bpftrace
/*
 * CUT Agent Telemetry Collector — eBPF
 * Attaches to kernel TCP tracepoints to collect ambient telemetry
 * No packet capture needed — this is kernel-internal observation
 */

BEGIN
{
    printf("CUT Agent eBPF Telemetry Starting...\n");
    printf("%-20s %-6s %-16s %-6s %-15s %-6s\n",
        "TIMESTAMP", "PID", "COMM", "EVENT", "ADDR", "PORT");
}

/* New outbound TCP connection */
tracepoint:tcp:tcp_connect
{
    $sk = (struct sock *)args->skaddr;
    $dport = args->dport;
    $daddr = ntop(args->daddr_v6);

    printf("%-20llu %-6d %-16s %-6s %-15s %-6d\n",
        nsecs, pid, comm, "CONN",
        $daddr, $dport);
}

/* TCP state changes — tracks full lifecycle */
tracepoint:tcp:tcp_set_state
{
    $newstate = args->newstate;
    $dport = args->dport;

    /* State names: 1=ESTABLISHED, 2=SYN_SENT, 7=CLOSE_WAIT, 8=LAST_ACK */
    printf("%-20llu %-6d %-16s %-6s state=%d      %-6d\n",
        nsecs, pid, comm, "STATE",
        $newstate, $dport);
}

/* TCP retransmissions — reliability signal */
tracepoint:tcp:tcp_retransmit_skb
{
    $dport = args->dport;
    printf("%-20llu %-6d %-16s %-6s %-15s %-6d\n",
        nsecs, pid, comm, "REXMT",
        ntop(args->daddr_v6), $dport);
}

/* Data receive — tracks throughput */
tracepoint:tcp:tcp_recv_length
{
    printf("%-20llu %-6d %-16s %-6s len=%-10d %-6d\n",
        nsecs, pid, comm, "RECV",
        args->length, args->dport);
}
```

```bash
# Run the eBPF tracer
chmod +x /lab/tcp_agent.bt
bpftrace /lab/tcp_agent.bt
```

In another terminal in the same container:
```bash
docker exec -it ebpf-lab bash
# Generate traffic
nc -l -p 9999 &
echo "EBPF_TEST" | nc 127.0.0.1 9999
```

> **Fallback if tracepoints aren't available in Docker:**
> ```bash
> # Use BCC's tcpconnect tool (pre-built, works in most containers)
> /usr/sbin/tcpconnect-bpfcc -t
> # Or tcplife for connection lifecycle:
> /usr/sbin/tcplife-bpfcc
> ```

### 5.3 — Side-by-Side Comparison

| Capability | DTrace (macOS) | eBPF (Linux) |
|-----------|---------------|-------------|
| Kernel tracing | `fbt` provider (needs SIP disable) | kprobes, tracepoints (native) |
| Userspace tracing | `syscall` provider (works with SIP) | uprobes, USDT |
| TCP events | Manual via `syscall::connect` etc. | `tracepoint:tcp:*` built-in |
| Process identity | `pid`, `execname` | `pid`, `comm` |
| Performance overhead | Low (no bytecode verification) | Very low (JIT-compiled in kernel) |
| Deployment | Ships with macOS | Requires kernel 4.15+, BCC/bpftrace |
| Patent relevance | macOS agent implementation | Linux agent/daemon implementation |

### 5.4 — What Ambient Factors Can Each Capture?

From the patent: "device characteristics, operating system, installed applications, application versions, scripts, the set of icons on the user's home screen, a set of bookmarks, a list of then-running processes, mouse movements, and other general or specific user behaviors"

| Factor | DTrace | eBPF |
|--------|--------|------|
| Running processes | `proc:::exec-success` | `tracepoint:sched:sched_process_exec` |
| Network connections | `syscall::connect` | `tracepoint:tcp:tcp_connect` |
| File access patterns | `syscall::open` | `tracepoint:syscalls:sys_enter_openat` |
| DNS lookups | `syscall::sendto` (port 53) | kprobe on `udp_sendmsg` |
| Process tree (parent/child) | `proc:::create` | `tracepoint:sched:sched_process_fork` |
| Byte counts per connection | `syscall::write/read` return values | `tcp_sendmsg` / `tcp_recvmsg` kprobes |

### 5.5 — Cleanup

```bash
# Exit and remove Docker container
docker stop ebpf-lab && docker rm ebpf-lab
```

### 5.6 — Interview Talking Points

- The patent's agent concept maps directly to eBPF on Linux and DTrace on macOS. Both provide kernel-level visibility into process behavior, network events, and system state — the "ambient authentication factors."
- eBPF is the production-grade choice for the Linux agent/daemon: zero packet capture overhead, runs in-kernel, can aggregate telemetry before sending to the core network's time-series DB.
- Key insight: the agent doesn't need packet capture (`tcpdump`/`libpcap`) at all. Kernel tracing gives you `{src/dest/len/timestamp}` plus process identity without ever touching the wire. This is more efficient and harder to evade than pcap-based monitoring.
- The trust engine in the patent computes per-factor trust indexes. Each eBPF/DTrace data stream (connections, file access, process launches) becomes a separate scoring dimension.

---

## Lab 6: Full-Stack Correlation (Epilogue)

**Time: ~60 minutes**
**Patent link:** This chains everything together — the complete CUT architecture running locally: agent (DTrace) → loopback → WireGuard relay → mTLS to daemon, with telemetry at every layer.

### 6.1 — Architecture Diagram

```
┌─────────────┐     lo0 (cleartext)      ┌──────────────┐
│  Java mTLS  │ ──────────────────────── │  WireGuard   │
│   Client    │                           │   Agent      │
│  (agent)    │                           │  utun4       │
└─────────────┘                           │  10.0.0.1    │
       │                                  └──────┬───────┘
       │                                         │
  DTrace tracing                          en0/lo0 (encrypted UDP)
  tcp_telemetry.d                                │
                                          ┌──────┴───────┐
                                          │  WireGuard   │
                                          │   Daemon     │
                                          │  utun5       │
                                          │  10.0.0.2    │
                                          └──────┬───────┘
                                                 │
                                          ┌──────┴───────┐
                                          │  openssl     │
                                          │  s_server    │
                                          │  (mTLS)      │
                                          │  :8443       │
                                          └──────────────┘
```

### 6.2 — Bring Up All Components

```bash
# === Terminal 1: WireGuard tunnel ===
sudo wg-quick up ~/cut-labs/lab4/wg-agent.conf
sudo wg-quick up ~/cut-labs/lab4/wg-daemon.conf
ping -c 1 10.0.0.2  # verify

# === Terminal 2: TLS server on daemon side ===
cd ~/cut-labs/lab2
# Bind the server to the WireGuard daemon IP
openssl s_server -accept 10.0.0.2:8443 \
  -cert server.crt -key server.key \
  -CAfile ca.crt -Verify 1

# === Terminal 3: DTrace agent telemetry ===
cd ~/cut-labs/lab5
sudo dtrace -s tcp_telemetry.d

# === Terminal 4: Capture on tunnel interface (cleartext) ===
sudo tcpdump -S -tttt -nn -v -i utun4 'tcp port 8443' \
  -w ~/cut-labs/lab6/tunnel_clear.pcap

# === Terminal 5: Capture on physical interface (encrypted) ===
sudo tcpdump -S -tttt -nn -v -i lo0 'udp port 51820 or udp port 51821' \
  -w ~/cut-labs/lab6/physical_enc.pcap
```

### 6.3 — Send mTLS Traffic Through the Tunnel

```bash
# === Terminal 6: mTLS client targeting daemon IP through WireGuard ===
cd ~/cut-labs/lab2

# Direct openssl s_client connection through WireGuard
openssl s_client -connect 10.0.0.2:8443 \
  -cert client.crt -key client.key \
  -CAfile ca.crt <<< "GET / HTTP/1.0"
```

> **Note:** If the Java MTLSClient from Lab 2 resolves `localhost`, modify it to connect to `10.0.0.2` instead to route through WireGuard.

### 6.4 — Stop All Captures and Analyze

```bash
# Kill tcpdump processes
sudo killall tcpdump 2>/dev/null

echo "========================================="
echo "LAYER 1: Kernel Telemetry (DTrace/Agent)"
echo "========================================="
echo "(Check Terminal 3 output — shows PID, process, connect events)"

echo ""
echo "========================================="
echo "LAYER 2: Tunnel Interface (Cleartext TCP)"
echo "========================================="
tcpdump -S -tttt -nn -r ~/cut-labs/lab6/tunnel_clear.pcap 2>/dev/null | head -15

echo ""
echo "========================================="
echo "LAYER 3: Physical Interface (Encrypted)"
echo "========================================="
tcpdump -S -tttt -nn -r ~/cut-labs/lab6/physical_enc.pcap 2>/dev/null | head -15
```

### 6.5 — Build the Correlation Narrative

```bash
echo "=== CUT Telemetry Pipeline ==="
echo ""
echo "--- Agent (Kernel) Layer ---"
echo "What the agent knows: process name, PID, connection target, timestamps"
echo "Ambient factors: which app initiated the connection, system state"
echo ""
echo "--- Relay (Physical) Layer ---"
echo "What the relay sees:"
tcpdump -tttt -nn -r ~/cut-labs/lab6/physical_enc.pcap 2>/dev/null | \
  awk '{printf "  {src: %s, dest: %s, len: ENCRYPTED, ts: %s %s}\n",
    $4, $6, $1, $2}' | head -5
echo ""
echo "--- Endpoint (Tunnel) Layer ---"
echo "What the endpoint sees after decryption:"
# NOTE: utun interfaces do NOT have the BSD IP token shift — use $3/$5
tcpdump -S -tttt -nn -r ~/cut-labs/lab6/tunnel_clear.pcap 2>/dev/null | \
  awk '{
    len_match = match($0, /length [0-9]+/);
    len = (len_match ? substr($0, RSTART+7, RLENGTH-7) : "0");
    if (match($0, /seq [0-9]+/)) {
      seq = substr($0, RSTART+4, RLENGTH-4);
    } else { seq = "N/A" }
    printf "  {src: %s, dest: %s, seq: %s, len: %s, ts: %s %s}\n",
      $3, $5, seq, len, $1, $2}' | head -5
```

### 6.6 — Where ISN Continuity Holds and Breaks

| Layer | ISN Visible? | Content Visible? | Patent Component |
|-------|-------------|-------------------|-----------------|
| Kernel (DTrace/eBPF) | No (syscall level, pre-TCP) | Yes (app layer) | Agent — ambient factors |
| Tunnel interface (utun) | Yes — full TCP headers | Yes — cleartext | Agent ↔ Daemon (after decrypt) |
| Physical interface (en0/lo0) | No — encrypted in UDP | No — encrypted | Relay — `{src/dest/len/ts}` only |
| Proxy boundary (Lab 2) | Yes, but DIFFERENT per side | Decrypted at proxy | Relay termination point |

**The complete trust signal chain:**
1. Agent collects ambient factors (process identity, behavior) via DTrace/eBPF
2. Agent encrypts traffic and sends through WireGuard (pkey = identity anchor)
3. Relay sees ONLY `{src/dest/len/timestamp}` — encrypted metadata
4. Relay feeds telemetry to time-series DB → engine scores trust
5. Engine may step-up auth if anomalies detected (zero window, unusual process, timing gaps)
6. Daemon decrypts and forwards to service; sends `{src/pkey/dest/timestamp/request_body_hash}` back to engine

### 6.7 — Cleanup

```bash
sudo wg-quick down ~/cut-labs/lab4/wg-agent.conf
sudo wg-quick down ~/cut-labs/lab4/wg-daemon.conf
sudo killall tcpdump dtrace 2>/dev/null
```

---

## Quick Reference: macOS BSD vs. Linux Networking Commands

| Task | macOS (BSD) | Linux |
|------|------------|-------|
| List interfaces | `ifconfig -l` | `ip link show` |
| Interface details | `ifconfig en0` | `ip addr show eth0` |
| Routing table | `netstat -rn` | `ip route` |
| Add route | `sudo route add -net 10.0.0.0/24 10.0.0.1` | `sudo ip route add 10.0.0.0/24 via 10.0.0.1` |
| Firewall | `pfctl` (pf) | `iptables` / `nftables` |
| Socket stats | `netstat -an` | `ss -tupan` |
| Kernel tuning | `sysctl -w net.inet.tcp.*` | `sysctl -w net.ipv4.tcp_*` |
| Packet capture | `tcpdump` (BSD flavor) | `tcpdump` (Linux flavor) |
| Kernel tracing | `dtrace` | `bpftrace` / BCC |
| VPN interfaces | `utun*` | `wg0` / `tun0` |

---

## Appendix: tcpdump Filter Cheat Sheet (BSD/macOS)

```bash
# TCP flags (BPF filter syntax — works on macOS)
'tcp[tcpflags] & (tcp-syn) != 0'          # SYN packets (handshakes)
'tcp[tcpflags] & (tcp-syn|tcp-ack) = (tcp-syn|tcp-ack)'  # SYN-ACK only
'tcp[tcpflags] & (tcp-rst) != 0'          # RST packets (resets)
'tcp[tcpflags] & (tcp-fin) != 0'          # FIN packets (teardowns)

# Window size = 0 (zero window)
'tcp[14:2] = 0'                            # Window field at offset 14, 2 bytes

# By port
'tcp port 8443'
'tcp dst port 9999'
'udp port 51820'                           # WireGuard

# By host
'host 10.0.0.1'
'src host 127.0.0.1 and dst port 9999'

# Combine
'tcp port 8443 and tcp[tcpflags] & (tcp-syn) != 0'  # SYN on port 8443

# Useful flags
# -S     absolute sequence numbers (CRITICAL for ISN work)
# -tttt  wall-clock timestamps
# -nn    no name resolution
# -v/-vv verbose / very verbose
# -w     write to pcap file
# -r     read from pcap file
# -i     interface (lo0, en0, utun4, etc.)
# -c N   capture N packets then stop
# -X     hex + ASCII dump of payload
```
