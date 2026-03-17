#!/bin/bash
PCAP="${1:?Usage: $0 <pcap_file> <output_file>}"
OUT="${2:?Usage: $0 <pcap_file> <output_file>}"
DIR="$(dirname "$0")"

tshark -r "$PCAP" -T fields -E separator=, -E quote=n \
  -e ip.src \
  -e tcp.srcport \
  -e ip.dst \
  -e tcp.dstport \
  -e frame.time_epoch \
  -e ip.ttl \
  -e ip.id \
  -e ip.len \
  -e ip.dsfield.dscp \
  -e ip.dsfield.ecn \
  -e ip.flags.df \
  -e ip.proto \
  -e tcp.flags \
  -e tcp.flags.str \
  -e tcp.flags.cwr \
  -e tcp.flags.ece \
  -e tcp.seq_raw \
  -e tcp.ack_raw \
  -e tcp.window_size_value \
  -e tcp.len \
  -e tcp.hdr_len \
  -e tcp.urgent_pointer \
  -e tcp.options.mss_val \
  -e tcp.options.wscale.shift \
  -e tcp.options.timestamp.tsval \
  -e tcp.options.timestamp.tsecr \
  -e tcp.options \
  2>/dev/null | python3 -c "$(cat "$DIR/transform.py")" > "$OUT"

echo "$(wc -l < "$OUT" | tr -d ' ') messages (WIRE only) → $OUT" >&2
