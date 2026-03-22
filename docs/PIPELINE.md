# CUT Telemetry Pipeline Reference

## Overview

```
pcap/dtrace → extract → tsv → produce.py → Kafka → Flink SQL → dashboard
```

Two independent pipelines feed two topics. Each topic has its own service account,
schema, and extraction toolchain.

## Packet Telemetry Pipeline

**Topic:** `packet-telemetry` (6 partitions, 24h retention)
**Service account:** `sa-9kjxo17` (API key `TFWGLQFZFPDWWJVC`)
**Properties file:** `lab1/confluent.properties`

### Extract

```bash
cd ~/cut-labs/lab1 && ./extract_telemetry.sh <pcap_file> <output.tsv>
```

Runs: `tshark -T fields` (36 fields) → `python3 transform.py` → tsv file.
Output format: `normalized_key|{json_value}` (pipe-delimited).
Key: endpoints sorted lexicographically. Both directions same key.
Value: JSON with 27 WIRE + 9 COMPUTED fields + `direction`.

### Produce

```bash
cd ~/cut-labs && python3 produce.py lab1/confluent.properties packet-telemetry < lab1/telemetry.tsv
```

### Full pipeline (one command)

```bash
cd ~/cut-labs/lab1 && ./extract_telemetry.sh capture.pcap telemetry.tsv && cd ~/cut-labs && python3 produce.py lab1/confluent.properties packet-telemetry < lab1/telemetry.tsv
```

### Per-lab captures

| Lab | Pcap source | Extract command |
|-----|------------|-----------------|
| 1 | `lab1/handshake.pcap` | `./extract_telemetry.sh handshake.pcap telemetry.tsv` |
| 2 | `lab2/client_to_proxy.pcap` | `./extract_telemetry.sh ~/cut-labs/lab2/client_to_proxy.pcap ~/cut-labs/lab2/client_to_proxy.tsv` |
| 2 | `lab2/proxy_to_server.pcap` | `./extract_telemetry.sh ~/cut-labs/lab2/proxy_to_server.pcap ~/cut-labs/lab2/proxy_to_server.tsv` |
| 3 | `lab3/zerowindow2.pcap` | `./extract_telemetry.sh ~/cut-labs/lab3/zerowindow2.pcap ~/cut-labs/lab3/zerowindow2.tsv` |
| 4 | `lab4/tunnel.pcap` | `./extract_telemetry.sh ~/cut-labs/lab4/tunnel.pcap ~/cut-labs/lab4/tunnel.tsv` |
| 4 | `lab4/physical.pcap` | UDP data — TCP extractor produces empty fields (expected) |

### Re-produce all labs

```bash
cd ~/cut-labs
for f in lab1/telemetry.tsv lab2/client_to_proxy.tsv lab2/proxy_to_server.tsv lab3/zerowindow2.tsv lab4/tunnel.tsv; do
    echo "Producing $f..."
    python3 produce.py lab1/confluent.properties packet-telemetry < "$f"
done
```

## Ambient Telemetry Pipeline

**Topic:** `ambient-telemetry` (6 partitions, 24h retention)
**Service account:** ambient-service (API key `637FZ55MZ652N64Z`)
**Properties file:** `lab5/confluent.properties`

### Capture (10 seconds, auto-stops)

Unfiltered (full device fingerprint):

```bash
sudo dtrace -n '
#pragma D option quiet
tick-10s { exit(0); }
syscall::connect:entry { printf("%Y PID=%-6d PROC=%-20s CONN fd=%d\n", walltimestamp, pid, execname, arg0); }
syscall::write:entry /arg0 > 2/ { printf("%Y PID=%-6d PROC=%-20s SEND fd=%d bytes=%d\n", walltimestamp, pid, execname, arg0, arg2); }
syscall::read:entry /arg0 > 2/ { printf("%Y PID=%-6d PROC=%-20s RECV fd=%d bytes=%d\n", walltimestamp, pid, execname, arg0, arg2); }
' > ~/cut-labs/lab5/dtrace.out
```

Filtered (nc/curl/wireguard only):

```bash
sudo dtrace -n '
#pragma D option quiet
tick-10s { exit(0); }
syscall::connect:entry /execname == "nc" || execname == "curl" || execname == "wireguard-go"/ { printf("%Y PID=%-6d PROC=%-20s CONN fd=%d\n", walltimestamp, pid, execname, arg0); }
syscall::write:entry /arg0 > 2 && (execname == "nc" || execname == "curl" || execname == "wireguard-go")/ { printf("%Y PID=%-6d PROC=%-20s SEND fd=%d bytes=%d\n", walltimestamp, pid, execname, arg0, arg2); }
syscall::read:entry /arg0 > 2 && (execname == "nc" || execname == "curl" || execname == "wireguard-go")/ { printf("%Y PID=%-6d PROC=%-20s RECV fd=%d bytes=%d\n", walltimestamp, pid, execname, arg0, arg2); }
' > ~/cut-labs/lab5/dtrace_filtered.out
```

Device snapshot:

```bash
cd ~/cut-labs/lab5 && ./capture_ambient.sh
```

### Extract

```bash
cd ~/cut-labs/lab5 && python3 transform_ambient.py < dtrace.out > dtrace.tsv
```

### Produce

```bash
cd ~/cut-labs && python3 produce.py lab5/confluent.properties ambient-telemetry < lab5/dtrace.tsv
```

### Full pipeline (one command)

```bash
cd ~/cut-labs/lab5 && python3 transform_ambient.py < dtrace.out > dtrace.tsv && cd ~/cut-labs && python3 produce.py lab5/confluent.properties ambient-telemetry < lab5/dtrace.tsv
```

## Producer Details

`produce.py` uses the `confluent-kafka` Python library (librdkafka bindings).
Batched (1000 msgs), compressed (snappy), with SSL retry (5 retries, 500ms backoff).
4000 messages in ~1 second.

Input: `key|value` (pipe-delimited) on stdin, one message per line.
Args: `python3 produce.py <properties_file> <topic>`

**Why not kcat:** kcat's SSL first-connect fails consistently with this Confluent Cloud
cluster. The handshake gets reset and kcat exits without retry.

**Why not confluent CLI:** No batching. One HTTP request per message. Unusable for >100 messages.

## Schema Registry

Registry: `psrc-lz3xz.us-central1.gcp.confluent.cloud`
API key: `TX636IEXLNMVOOMX`

Register packet schemas:
```bash
cd ~/cut-labs/lab1 && ./register_schema.sh https://psrc-lz3xz.us-central1.gcp.confluent.cloud TX636IEXLNMVOOMX SR_SECRET
```

Register ambient schemas:
```bash
cd ~/cut-labs/lab5 && ./register_ambient_schema.sh https://psrc-lz3xz.us-central1.gcp.confluent.cloud TX636IEXLNMVOOMX SR_SECRET
```

## Production Path

```
Lab:        tshark → python transform → python produce → Kafka
Production: DPDK/XDP → C parser (20 lines) → librdkafka C API → Kafka
```

Same schema, same topics, same consumer code. Only the extraction layer changes.
