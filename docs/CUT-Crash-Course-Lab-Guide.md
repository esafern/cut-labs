# CUT Architecture — Crash Course Lab Guide

**Version:** 2.0
**Updated:** 2026-03-18
**Target:** CUT patent exploration
**Platform:** Intel macOS Sequoia 15.7.4 (BSD networking stack, x86_64)
**Patent Reference:** US 12,309,132 B1 — "Continuous Universal Trust"
**Repo:** https://github.com/esafern/cut-labs

---

## Prerequisites & Setup

```bash
brew install mitmproxy wireshark wireguard-tools wireguard-go iperf3 nmap
brew install gh && gh auth login
```

Verify tools:
```bash
java -version && mvn -version && python3 --version && sudo tcpdump --version && tshark -v | head -1
```

Create working directory:
```bash
mkdir -p ~/cut-labs/{lab1/schemas,lab2/client_certs,lab3,lab4,lab5,lab6,docs}
cd ~/cut-labs && git init
```

### macOS Interface Reference

| Interface | Purpose | Linux Equivalent |
|-----------|---------|-----------------|
| `lo0` | Loopback (127.0.0.1) | `lo` |
| `en0` | Primary Ethernet/WiFi | `eth0` / `wlan0` |
| `utun*` | VPN/WireGuard tunnels | `wg0` / `tun0` |

Record baseline utun interfaces before Lab 4:
```bash
ifconfig -l | tr ' ' '\n' | grep utun
```

---

## Lessons Learned (Updated During Execution)

### BSD vs GNU Tool Differences

**tcpdump field offsets on BSD loopback:** BSD lo0 uses link-type NULL which inserts `IP` as a token, shifting awk fields by one vs Linux. Use `$4/$6` on lo0, `$3/$5` on utun and en0. Always verify with `tcpdump -r | head -3`.

**BSD sed does not interpret `\t` as tab.** Use `awk -F'\t'` for tab-delimited data.

**BSD sed lacks GNU extensions.** No `~` step addresses. Use awk for line filtering.

**python3 -m json.tool fails on NDJSON.** Use inline python with a for loop.

### zsh Shell Gotchas

No `#` comments in pasteable code blocks. No multi-line paste with special characters. Prefer `&&` one-liners.

### SIP and DTrace

syscall provider works under SIP. fbt provider does not. No reboot needed.

### Checksum Warnings on Loopback

`bad cksum 0` on lo0 is normal — TCP checksum offloading with no NIC.

### tshark ES-Native Output

`tshark -T ek` outputs Elasticsearch bulk-ingest NDJSON. Maps to patent element 120 (time-series DB).

### WIRE vs COMPUTED Fields

27 WIRE fields (on the wire, stateless extraction at relay). 9 COMPUTED fields (derived by tshark stream reassembly, belongs in engine). If COMPUTED absent from Kafka message, consumer derives from WIRE. See FIELD_REFERENCE.md.

### Session Identity and NAT

4-tuple is not stable across NAT. WireGuard pkey is the durable identity anchor. Session key normalized (endpoints sorted lexicographically). Direction field distinguishes outbound/inbound.

### Confluent Cloud 

Use `|` as delimiter everywhere (not tab, not colon). Service accounts need consumer group READ ACL for consume.

### IPv6 vs IPv4 on macOS

`localhost` resolves to `::1` first. Always use explicit `127.0.0.1`.

### mitmproxy Client Certs

Directory mode looks up `<upstream_hostname>.pem`. Create files for all hostnames used.

### macOS WireGuard Peers

Both peers on same Mac fails — kernel short-circuits LOCAL destinations. Put daemon in Docker container. `wg-quick` requires config filenames without hyphens (use `wg0.conf`).

---

## Lab 1: TCP Handshake, ISN Tracking & Loopback Telemetry

**Time: ~75 minutes**
**Patent link:** Agent intercepts traffic on loopback, extracts `{src/dest/len/timestamp}`.

### 1.1 — Capture a TCP Handshake

Terminal 1: `nc -l 127.0.0.1 9999`

Terminal 2: `cd ~/cut-labs/lab1 && sudo tcpdump -S -tttt -nn -v -i lo0 'tcp port 9999' -w handshake.pcap`

Wait for `listening on lo0`. Terminal 3: `echo "HELLO_CUT" | nc 127.0.0.1 9999`

Ctrl-C tcpdump. Read: `tcpdump -S -tttt -nn -v -r ~/cut-labs/lab1/handshake.pcap`

Key: `-S` for absolute ISNs. SYN has client ISN, SYN-ACK has server ISN + ack of client ISN+1.

### 1.2 — Extract Relay Metadata

```bash
tcpdump -S -tttt -nn -r ~/cut-labs/lab1/handshake.pcap | awk '{ts=$1" "$2; src=$4; dst=$6; gsub(/:$/,"",dst); len_match=match($0,/length [0-9]+/); len=(len_match?substr($0,RSTART+7,RLENGTH-7):"0"); printf "{src: %s, dest: %s, len: %s, timestamp: %s}\n",src,dst,len,ts}'
```

### 1.3 — Full Telemetry Extraction

```bash
cd ~/cut-labs/lab1 && ./extract_telemetry.sh handshake.pcap telemetry.tsv && head -2 telemetry.tsv
```

Normalized key (both directions same), `direction` field in JSON.

### 1.4 — Produce to Confluent Cloud

File mode: `cat telemetry.tsv | confluent kafka topic produce packet-telemetry --cluster lkc-187v7z --parse-key --delimiter '|'`

Verify: `confluent kafka topic consume packet-telemetry --from-beginning --cluster lkc-187v7z | head -3`

### 1.5 — Schema Registry

```bash
cd ~/cut-labs/lab1 && ./register_schema.sh <sr_url> <sr_key> <sr_secret>
```

### 1.6 — Architecture Notes

ISN is kernel-generated (RFC 6528). Agent hooks into lo0. DTrace/eBPF for ambient factors. Pipeline: tshark (lab) → DPDK/XDP (production). WIRE vs COMPUTED maps to relay vs engine.

---

## Lab 2: mTLS Interception Proxy (The Relay)

**Time: ~90 minutes**
**Patent link:** Relay sits between agent and daemon. Two TCP sessions, independent ISN spaces.

### 2.1 — Build PKI

CA, server cert with SAN, client cert with clientAuth, Java keystore. See repo `lab2/` for .cnf files.

### 2.2 — Start Server (Daemon)

`openssl s_server -accept 127.0.0.1:8443 -cert server.crt -key server.key -CAfile ca.crt -Verify 1`

### 2.3 — Start Proxy (Relay)

Use `127.0.0.1` not `localhost`. Create `client_certs/127.0.0.1.pem`:

`mitmdump --mode reverse:https://127.0.0.1:8443/ --set ssl_insecure=true --set client_certs=client_certs/ --listen-port 8080 -v`

### 2.4 — Dual Capture

tcpdump on port 8443 and port 8080 simultaneously. Wait for both `listening on lo0` before sending traffic.

`curl -4 -k https://localhost:8080/`

### 2.5 — Compare ISNs

Four independent ISNs across the proxy boundary. Proxy breaks ISN continuity. 1.4ms processing latency between client SYN and proxy-to-server SYN.

### 2.6 — Architecture Notes

mTLS = both sides authenticate. Client cert ≈ `{user/pass/src/pkey}`. Relay sees metadata on both sides but content is decrypted/re-encrypted at the boundary.

---

## Lab 3: TCP Zero Window (DPI Choke)

**Time: ~45 minutes**
**Patent link:** Trust engine detects anomalies in telemetry. Zero window = flow stall.

### 3.1 — Compile

`cd ~/cut-labs/lab3 && javac StallServer.java FloodSender.java`

### 3.2 — Run

Parameters: `java StallServer 5 4096 10` (5s stall, 4096 byte reads, 10ms delay).

Three phases captured: descent (65535→0), zero window (5s gap), recovery sawtooth (oscillating ~700ms cycles).

Use `StallServer 15 64 100` to see RST (connection killed before recovery). Not useful for demo.

### 3.3 — Wireshark

Click source port 7777 packet → Statistics → TCP Stream Graphs → Window Scaling. Visual sawtooth.

---

## Lab 4: WireGuard Tunnel (The Patent's Relay)

**Time: ~75 minutes**
**Patent link:** "a relay 114 (such as Wireguard)"

### 4.1 — Docker Daemon

Both peers on same Mac fails (kernel LOCAL shortcut). Daemon runs in Docker:

```
Mac (agent, utun, 10.0.0.1) ↔ Docker (daemon, wg0, 10.0.0.2)
```

### 4.2 — Setup

Generate keys. Create `wg-agent.conf` (Mac) and `wg0.conf` (Docker — no hyphens in filename). Build Docker image with wireguard-tools. Start container with `--cap-add=NET_ADMIN -p 51821:51821/udp`. Bring up `wg0` inside container, `wg-agent` on Mac.

### 4.3 — Dual Capture

lo0/bridge: encrypted UDP blobs. Container wg0: cleartext TCP. Same traffic, two views. The relay sees encrypted side only.

### 4.4 — NAT Simulation

`pfctl` rewrites WireGuard source port. 4-tuple breaks. Tunnel survives on pkey. Trust engine sees roam event.

---

## Lab 5: DTrace / eBPF (The Patent's Agent)

**Time: ~60 minutes**

DTrace `syscall` provider on macOS. eBPF `tracepoint:tcp:*` in Docker. Both capture ambient factors without packet capture.

---

## Lab 6: Full-Stack Correlation

**Time: ~60 minutes**

Chain all labs: mTLS through WireGuard, DTrace tracing, capture at every layer, produce all telemetry to Kafka.

---

## Production Architecture

```
NIC → DPDK/XDP → C parser (27 WIRE fields) → librdkafka → Kafka → Flink SQL → ClickHouse/Grafana
```

tshark proves the data model. Production replaces the extraction layer only.
