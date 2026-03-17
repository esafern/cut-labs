#!/bin/bash
DIR="$(dirname "$0")"
CONF="$DIR/confluent.properties"
TOPIC="packet-telemetry"

if [ ! -f "$CONF" ] && [ ! -L "$CONF" ]; then
    echo "ERROR: $CONF not found. Copy confluent.properties.template and add credentials." >&2
    exit 1
fi

if [ -f "$1" ]; then
    echo "File mode: $1 → $TOPIC" >&2
    cat "$1" | kcat -P -F "$CONF" -t "$TOPIC" -K '\t' -z snappy
    echo "$(wc -l < "$1" | tr -d ' ') messages produced" >&2
else
    echo "Pipe mode: stdin → $TOPIC (Ctrl-C to stop)" >&2
    kcat -P -F "$CONF" -t "$TOPIC" -K '\t' -z snappy
fi
