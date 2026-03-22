# CUT Telemetry Field Reference (v4)

## Architecture Principle

The relay (patent element 114) extracts WIRE fields at line rate with no per-connection state.
The engine (patent element 112) derives COMPUTED fields from stored WIRE data.

COMPUTED fields from tshark are optional enrichment. If absent from the Kafka message,
the consumer (trust engine) derives them from WIRE fields using the formulas below.
This means the entire pipeline works with WIRE-only extraction (production C parser)
or with full tshark enrichment (lab demo).

## Extraction Scripts

| Script | Emits | Use case |
|--------|-------|----------|
| `extract_telemetry.sh` | WIRE + COMPUTED | Lab: full tshark enrichment |
| `extract_wire_only.sh` | WIRE only | Production simulation: relay-equivalent |
| `extract_ek.sh` | WIRE + COMPUTED (ES format) | Elasticsearch bulk ingest |

## WIRE Fields — Always Present

C reimplementation: fixed byte offsets, one struct cast per packet.

| Field | tshark -e | Offset | C extraction |
|-------|-----------|--------|-------------|
| src_ip | ip.src | IP+12 | `*(uint32_t*)(ip+12)` |
| dst_ip | ip.dst | IP+16 | `*(uint32_t*)(ip+16)` |
| ttl | ip.ttl | IP+8 | `ip[8]` |
| ip_id | ip.id | IP+4 | `ntohs(*(uint16_t*)(ip+4))` |
| ip_len | ip.len | IP+2 | `ntohs(*(uint16_t*)(ip+2))` |
| dscp | ip.dsfield.dscp | IP+1 | `(ip[1] >> 2) & 0x3f` |
| ecn | ip.dsfield.ecn | IP+1 | `ip[1] & 0x03` |
| df | ip.flags.df | IP+6 | `(ip[6] >> 6) & 0x01` |
| ip_proto | ip.proto | IP+9 | `ip[9]` |
| src_port | tcp.srcport | TCP+0 | `ntohs(*(uint16_t*)(tcp+0))` |
| dst_port | tcp.dstport | TCP+2 | `ntohs(*(uint16_t*)(tcp+2))` |
| tcp_flags_hex | tcp.flags | TCP+13 | `tcp[13]` |
| tcp_flags_cwr | tcp.flags.cwr | TCP+13 | `(tcp[13] >> 7) & 0x01` |
| tcp_flags_ece | tcp.flags.ece | TCP+13 | `(tcp[13] >> 6) & 0x01` |
| seq_raw | tcp.seq_raw | TCP+4 | `ntohl(*(uint32_t*)(tcp+4))` |
| ack_raw | tcp.ack_raw | TCP+8 | `ntohl(*(uint32_t*)(tcp+8))` |
| win_value | tcp.window_size_value | TCP+14 | `ntohs(*(uint16_t*)(tcp+14))` |
| tcp_payload_len | tcp.len | derived | `ip_len - ip_hdr_len - tcp_hdr_len` |
| tcp_hdr_len | tcp.hdr_len | TCP+12 | `(tcp[12] >> 4) * 4` |
| urgent_ptr | tcp.urgent_pointer | TCP+18 | `ntohs(*(uint16_t*)(tcp+18))` |
| mss | tcp.options.mss_val | TCP opts | parse option kind=2 |
| wscale | tcp.options.wscale.shift | TCP opts | parse option kind=3 |
| ts_val | tcp.options.timestamp.tsval | TCP opts | parse option kind=8, bytes 2-5 |
| ts_ecr | tcp.options.timestamp.tsecr | TCP opts | parse option kind=8, bytes 6-9 |
| tcp_options_raw | tcp.options | TCP+20 | `memcpy(tcp+20, tcp_hdr_len-20)` |
| timestamp_epoch | frame.time_epoch | capture clock | `gettimeofday()` at capture |
| direction | (derived) | (derived) | Lexicographic compare of endpoints: if src > dst, swap and set "inbound", else "outbound" |


## COMPUTED Fields — Optional, Engine Derives from WIRE

If a COMPUTED field is absent from the Kafka message, the consumer derives it.
All derivations use only WIRE fields. No tshark required.

| Field | tshark -e | Derivation from WIRE | Kafka engine implementation |
|-------|-----------|---------------------|----------------------------|
| time_delta | frame.time_delta | `current.timestamp_epoch - previous.timestamp_epoch` for same 4-tuple | Stateful processor, one timestamp per key |
| frame_len | frame.len | `ip_len + link_header` (4 for lo0, 14 for ethernet, constant per source) | Stateless map, add constant |
| protocols | frame.protocols | `ip_proto` lookup: 6→tcp, 17→udp. Port heuristics for app layer | Stateless map with lookup table |
| tcp_stream | tcp.stream | `hash(src_ip, src_port, dst_ip, dst_port)` or use Kafka message key directly | Already the partition key |
| is_retransmit | tcp.analysis.retransmission | `seq_raw` seen before with `tcp_payload_len > 0` for same stream | Stateful processor, seq set per key |
| is_zero_window | tcp.analysis.zero_window | `win_value == 0` | Stateless filter |
| initial_rtt | tcp.analysis.initial_rtt | `timestamp_epoch(SYN-ACK) - timestamp_epoch(SYN)` for same stream | Stateful, match on tcp_flags_hex 0x0002 → 0x0012 |
| ack_rtt | tcp.analysis.ack_rtt | Match `ack_raw` to previously seen `seq_raw + tcp_payload_len`, diff timestamps | Stateful, per-stream seq→timestamp map |
| bytes_in_flight | tcp.analysis.bytes_in_flight | `max(seq_raw + tcp_payload_len) - max(ack_raw)` per direction per stream | Stateful, two running max values per key |

### Kafka Streams pseudocode for COMPUTED derivation

```
KStream<String, Packet> packets = builder.stream("packet-telemetry");

packets
  .groupByKey()
  .aggregate(
    () -> new SessionState(),
    (key, packet, state) -> {
      // time_delta
      if (state.lastTimestamp != null)
        packet.timeDelta = packet.timestampEpoch - state.lastTimestamp;
      state.lastTimestamp = packet.timestampEpoch;

      // is_zero_window (stateless)
      packet.isZeroWindow = (packet.winValue == 0);

      // is_retransmit
      String seqKey = packet.seqRaw + ":" + packet.tcpPayloadLen;
      packet.isRetransmit = state.seenSeqs.contains(seqKey) && packet.tcpPayloadLen > 0;
      if (packet.tcpPayloadLen > 0) state.seenSeqs.add(seqKey);

      // initial_rtt (SYN→SYN-ACK)
      if (packet.tcpFlagsHex.equals("0x0002"))
        state.synTimestamp = packet.timestampEpoch;
      if (packet.tcpFlagsHex.equals("0x0012") && state.synTimestamp != null)
        packet.initialRtt = packet.timestampEpoch - state.synTimestamp;

      // bytes_in_flight
      long sndNxt = packet.seqRaw + packet.tcpPayloadLen;
      state.maxSeq = Math.max(state.maxSeq, sndNxt);
      state.maxAck = Math.max(state.maxAck, packet.ackRaw);
      packet.bytesInFlight = state.maxSeq - state.maxAck;

      return state;
    }
  );
```

## Patent-Specific Fields (Not from tshark)

| Field | Patent reference | Source |
|-------|-----------------|--------|
| pkey | FIG.2 steps 1,7 | WireGuard public key from `wg show` |
| request_body_hash | FIG.2 step 7 | SHA-256 of tcp.payload (or ip_len+tcp_len+seq_raw as proxy) |
| cut_identifier | FIG.2 step 2 | Application-layer user ID |
| session_id | FIG.2 step 2 | Core network session token |
| circle | Claims 1,2 | Security policy group membership |

## Kafka Message Format

Key: normalized session 4-tuple (endpoints sorted lexicographically)
  Example: `127.0.0.1:56896-127.0.0.1:9999` (lower sorts first)
  Both directions of one session produce the same key
Delimiter: `|` (pipe)
Value: JSON with WIRE fields always present, COMPUTED fields when available,
  `direction` field ("outbound" or "inbound") always present
Topic: `packet-telemetry`
Compression: snappy
Partitioning: by key (session affinity, both directions same partition)

Consumer behavior: check for COMPUTED field presence. If absent, derive from WIRE.
This means the same consumer code works with both tshark-enriched messages (lab)
and WIRE-only messages (production C parser).

