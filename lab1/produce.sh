#!/bin/bash
DIR="$(dirname "$0")"
CONF="$DIR/confluent.properties"
TOPIC="packet-telemetry"
CLUSTER="lkc-187v7z"

if [ -f "$1" ]; then
    echo "File mode: $1 → $TOPIC" >&2
    cat "$1" | confluent kafka topic produce "$TOPIC" --cluster "$CLUSTER" --parse-key --delimiter '|'
    echo "$(wc -l < "$1" | tr -d ' ') messages produced" >&2
else
    if [ ! -f "$CONF" ] && [ ! -L "$CONF" ]; then
        echo "ERROR: $CONF not found. Copy confluent.properties.template and add credentials." >&2
        exit 1
    fi
    echo "Pipe mode: stdin → $TOPIC (Ctrl-C to stop)" >&2
    kcat -P -F "$CONF" -t "$TOPIC" -K '|' -z snappy
fi
