# CUT Lab Guide — Session Prompt

**Version:** 1.3
**Updated:** 2026-03-13

Copy and paste the text below into a fresh Claude session to generate or iterate on the lab guide.

---

**Role:** Principal Performance Architect and Systems Engineer.

**Context:** Experienced architect (coding since 1987, Unix, Kafka, Oracle background) prepping for a Principal Architect interview at Cortwo, a Zero-Trust network security startup. Cortwo's patent (US 12,309,132 B1 — "Continuous Universal Trust") describes a relay-based core network (WireGuard) through which all entity traffic flows, with a continuous trust engine that dynamically adjusts authentication requirements during live sessions based on traffic metadata telemetry (`{src/dest/len/timestamp}`, request body hashes) combined with ambient and active authentication factors (device characteristics, behavioral signals, biometrics). The agent hooks into the client's loopback interface to intercept traffic; content stays encrypted end-to-end through the relay. ISN tracking is not in the patent but is a plausible extension — correlating TCP sequence number patterns as an ambient telemetry signal.

**Environment:** Intel macOS, Homebrew, Java, Maven, VS Code, vim. Comfortable installing additional tools. Linux VM/container available for eBPF labs.

**Goal:** Hands-on, terminal-driven Crash Course Lab Guide. Raw CLI commands, config files, and `tcpdump` syntax adapted for macOS/BSD (`lo0`, `en0`, `utun` — not Linux `eth0`).

---

**Lab 1: TCP Handshake, ISN Tracking & Loopback Telemetry**
- Initiate a connection using `nc` (ships with macOS) for minimal overhead.
- Capture the 3-way handshake using `tcpdump -S -tttt` (absolute sequence numbers, wall-clock timestamps).
- Isolate Client SYN ISN, Server SYN-ACK ISN, track the sequence increment through first data ACK.
- Use `dtrace` (ships with macOS) to capture kernel-side connection events and correlate with the pcap — demonstrates the agent-on-loopback telemetry concept from the patent.
- Extract the relay-style metadata tuple `{src/dest/len/timestamp}` from the capture to mirror the patent's telemetry model.
- Implement the full telemetry ingest pipeline: tshark → kcat → Confluent Cloud topic (`cut-packet-telemetry`). Key by session 4-tuple for partition routing. Support both pcap file and live capture modes. Include SASL_SSL auth config for Confluent Cloud (bootstrap: `pkc-921jm.us-east-2.aws.confluent.cloud:9092`). Tag each field as WIRE (relay-extractable) or COMPUTED (engine-derived).

**Lab 2: mTLS Interception Proxy (The Relay/Middlebox)**
- Stand up `mitmproxy`/`mitmdump` locally as an mTLS-terminating proxy — client and server cert validation active.
- Generate a local CA, issue client and server certs via `openssl` (full PKI chain).
- Route traffic through the proxy and capture on both sides simultaneously (two `tcpdump` processes, filtered by port).
- Observe the "Two TCP Sessions" problem with independent ISN spaces — mirrors the patent's agent↔relay↔daemon architecture.
- Diff ISNs and request body hashes across the proxy boundary. Probe both sides with `openssl s_client` to show mTLS negotiation and certificate chain differences.
- Connection initiator: Java `SSLSocket` with client cert loaded from keystore.

**Lab 3: TCP Zero Window (Performance Choke / Trust Signal)**
- Java `ServerSocket` that accepts, then stalls (`Thread.sleep`) before calling `read()` — deterministic buffer exhaustion. Alternative: C with raw BSD sockets and `setsockopt(SO_RCVBUF)`.
- Tune `net.inet.tcp.recvspace` via `sysctl` to shrink the receive buffer, trigger zero window faster (restore after).
- Capture on loopback, identify `[TCP ZeroWindow]` flag.
- Phase 2: receiver reads slowly (small buffer + sleep) to simulate a choking intermediary. Capture window recovery sawtooth.
- Frame this as a trust signal: abnormal flow metadata (`len` dropping to zero, timestamp gaps) that the patent's continuous trust engine would detect and potentially trigger an authentication step-up.

**Lab 4: WireGuard Tunnel on macOS (The Patent's Relay)**
- Install `wireguard-tools` and `wireguard-go` via Homebrew (userspace Go implementation for `utun`).
- Generate keys, configure point-to-point tunnel, handle macOS-specific routing (`route` not `ip route`).
- Dual `tcpdump`: `en0` shows encrypted UDP encapsulation, `utun` shows cleartext — directly mirrors the patent's "content encrypted end-to-end, relay sees only metadata" architecture.
- Re-run Lab 1's handshake through the tunnel: ISN visible on `utun`, opaque on `en0`.
- Extract and compare the `{src/dest/len/timestamp}` tuples from both interfaces — what the relay can see vs. what it can't.
- **NAT simulation via pfctl:** Rewrite WireGuard source port mid-session to simulate NAT rebind / mobile roaming. Prove the tunnel survives on pkey identity even when the 4-tuple breaks. Capture before/after 4-tuples and correlate with `wg show` to demonstrate pkey stability. Frame tuple changes as trust signals (roam events) that the engine evaluates against ambient factors.

**Lab 5: eBPF / DTrace — Kernel-Level Telemetry (The Patent's Agent)**
- **macOS (dtrace):** Write a dtrace script to trace TCP connection events, socket operations, and ambient metadata (process name, uid, timestamp) on `lo0` — mirrors the patent's agent hooking into the loopback interface.
- **Linux (eBPF, in Docker/VM):** Attach a BPF program to `tcp_connect` / `tcp_accept` tracepoints. Extract `{src/dest/len/timestamp}` tuples at the kernel level without packet capture. Demonstrate how an agent collects telemetry that the relay's time-series DB would ingest.
- Compare the two approaches: dtrace (macOS, dynamic tracing) vs. eBPF (Linux, in-kernel programs). Discuss which ambient factors from the patent (running processes, connection metadata, behavioral patterns) each can capture.

**Lab 6 (Epilogue): Full-Stack Correlation**
- Chain Labs 1→5: mTLS connection through WireGuard, with dtrace/eBPF collecting kernel telemetry simultaneously.
- Capture at every layer: kernel events (dtrace/eBPF), `utun` cleartext, `en0` encrypted, proxy boundary.
- Build the patent's telemetry pipeline: correlate `{src/dest/len/timestamp}` from the relay with ambient factor data from the agent. Show where continuous trust scoring would trigger step-up or step-down.

---

**Instructions:**
1. Generate the full step-by-step CLI guide for all 6 labs.
2. macOS-native only for Labs 1-4 — `pf` not `iptables`, `route` not `ip route`, BSD `tcpdump` flags. Linux VM/container for eBPF portion of Lab 5.
3. Dense, technical, peer-to-peer tone.
4. Include a "Lessons Learned" section at the top documenting BSD vs. GNU differences encountered: tcpdump field offsets on `lo0` (`$4/$6` not `$3/$5` due to NULL link-type `IP` token), BSD `sed` lacking GNU extensions (use `awk` instead), `python3 -m json.tool` failing on NDJSON (use inline python), zsh pasting issues with `#` and `%`.
5. Use `tshark -T ek` for telemetry extraction — outputs Elasticsearch bulk-ingest NDJSON natively, mapping directly to the patent's time-series database (element 120). Include a reusable shell script.
6. In Lab 4, include a NAT simulation step using `pfctl` to demonstrate that the 4-tuple is NOT a stable session key, and that the WireGuard pkey is the durable identity anchor that survives NAT rebind and roaming.
7. Frame the telemetry index hierarchy as: Entity (pkey) → Circle (security policy) → Network identity (observed src_ip) → Session (4-tuple, ephemeral) → Packets (time-series).
8. Tag all tshark extraction fields as WIRE (actual bits on the packet, stateless extraction at relay) or COMPUTED (derived by capture tool or stream reassembly, requires per-connection state, belongs in the engine). This maps to the patent's relay (element 114) vs engine (element 112) separation.
9. Include a tshark → Confluent Cloud (Kafka) telemetry pipeline as three composable scripts: `transform.py` (CSV→keyed JSON), `extract_telemetry.sh` (tshark+transform→file), `produce.sh` (file or stdin→Kafka). Two assembly patterns: file mode for pcap (avoids pipe race condition with kcat SSL handshake), pipe mode for live capture (tshark stays alive, no race). Use kcat with `-F` only (never `-b` alongside `-F`). Add `ssl.ca.location` for macOS. Production note: tshark is for lab; production uses DPDK/XDP → C parser → librdkafka → Kafka → Flink/ksqlDB → ClickHouse.
10. Do not use `#` comments in shell code blocks — zsh interprets them incorrectly when pasted. Put explanatory text outside code blocks.
11. When providing shell commands for the user to paste, combine them with `&&` on one line rather than separate lines or multi-line blocks with comments.
