# CUT Packet Telemetry — Data Contract v1

## Topic

| Property | Value |
|----------|-------|
| Name | `packet-telemetry` |
| Partitions | 6 |
| Replication | 3 (Confluent Cloud managed) |
| Retention | 86400000ms (24 hours) |
| Cleanup policy | delete |
| Compression | snappy (producer-side) |
| Key format | String (session 4-tuple) |
| Value format | JSON |

## Ownership

| Role | Owner |
|------|-------|
| Producer | CUT Relay (element 114) |
| Schema | CUT Architecture Team |
| Consumers | CUT Trust Engine (element 112), Forensics/ClickHouse sink |

## Schemas

Key: `packet-telemetry-key-v1.json`
Value: `packet-telemetry-value-v1.json`
Registry: Confluent Schema Registry (JSON Schema format)

## Partitioning

Key = `{src_ip}:{src_port}-{dst_ip}:{dst_port}`

All packets for one direction of one TCP session land on the same partition.
Ordering is guaranteed per-partition. Consumer gets packets in wire order per session direction.

The key is NOT normalized: client→server and server→client produce different keys.
Both directions may land on different partitions. Consumers that need bidirectional
session reconstruction should normalize by sorting endpoints:
  min(endpoint_a, endpoint_b) + "-" + max(endpoint_a, endpoint_b)

## Message Contract

### Required fields (WIRE — always present)

Every message MUST contain these fields. They are extracted from IP/TCP headers
at the relay with no per-connection state. A production relay (DPDK/XDP + C parser)
produces these at line rate.

| Field | Type | Description |
|-------|------|-------------|
| src_ip | string | Source IP |
| src_port | integer | Source TCP port |
| dst_ip | string | Destination IP |
| dst_port | integer | Destination TCP port |
| timestamp_epoch | string | Nanosecond Unix epoch at capture |
| ip_proto | integer | IP protocol (6=TCP) |
| tcp_flags_hex | string | Raw TCP flags byte |
| seq_raw | string | Absolute sequence number |
| ack_raw | string | Absolute acknowledgment number |
| win_value | integer | Raw window size (before scaling) |
| tcp_payload_len | integer | TCP payload bytes |

### Optional WIRE fields (present when available)

These are on the wire but may not be extracted by all producer implementations.
Thin C parsers may skip some for throughput. tshark extracts all of them.

| Field | Type | Description |
|-------|------|-------------|
| ttl | integer | IP Time to Live |
| ip_id | string | IP identification |
| ip_len | integer | Total IP datagram length |
| dscp | integer | DiffServ Code Point |
| ecn | integer | ECN bits |
| df | string | Don't Fragment flag |
| tcp_flags_str | string | Flags as visual string |
| tcp_flags_cwr | string | CWR flag |
| tcp_flags_ece | string | ECE flag |
| tcp_hdr_len | integer | TCP header length |
| urgent_ptr | integer | Urgent pointer |
| mss | integer | Max Segment Size (SYN only) |
| wscale | integer | Window scale (SYN only) |
| ts_val | string | TCP timestamp value |
| ts_ecr | string | TCP timestamp echo reply |
| tcp_options_raw | string | Raw TCP options bytes |

### Optional COMPUTED fields (engine derives if absent)

These fields MAY be present if the producer performs stream reassembly (e.g., tshark).
If absent, the consumer MUST derive them from WIRE fields.
See FIELD_REFERENCE.md for derivation formulas.

| Field | Type | Derive from |
|-------|------|-------------|
| time_delta | string | consecutive timestamp_epoch per stream |
| frame_len | integer | ip_len + link header constant |
| protocols | string | ip_proto lookup |
| tcp_stream | integer | hash(4-tuple) or Kafka key |
| is_retransmit | string | duplicate seq_raw with payload > 0 |
| is_zero_window | string | win_value == 0 |
| initial_rtt | string | SYN-ACK timestamp - SYN timestamp |
| ack_rtt | string | ACK timestamp - matching data timestamp |
| bytes_in_flight | integer | max(seq+payload) - max(ack) |

## Compatibility

Schema evolution: BACKWARD compatible.
New optional fields may be added. Required fields cannot be removed.
Consumers must ignore unknown fields (additionalProperties handling).

## SLA

| Metric | Target |
|--------|--------|
| End-to-end latency (capture → topic) | < 100ms (tshark lab), < 1ms (DPDK production) |
| Throughput | 10 msg/s (lab), 1M+ msg/s (production) |
| Availability | Confluent Cloud SLA (99.95%) |
| Message ordering | Guaranteed per-partition (per session direction) |
