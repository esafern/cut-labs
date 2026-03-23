#!/usr/bin/env python3
"""Kafka producer with Schema Registry serialization for both key and value.

Usage:
    python3 produce_sr.py <properties_file> <topic> <sr_url> <sr_key> <sr_secret> < data.tsv

Input format: key|value (pipe-delimited JSON, one message per line)
Key is serialized through Schema Registry (JSON Schema type "string").
Value is serialized through Schema Registry (JSON Schema type "object").
"""

import sys
import json
import struct
from confluent_kafka import Producer
from confluent_kafka.schema_registry import SchemaRegistryClient
from confluent_kafka.schema_registry.json_schema import JSONSerializer
from confluent_kafka.serialization import SerializationContext, MessageField

def load_config(path):
    conf = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            k, v = line.split("=", 1)
            conf[k.strip()] = v.strip()
    return conf

def make_sr_key_bytes(schema_id, key_str):
    """Serialize a plain string key with SR wire format:
    magic byte (0x00) + 4-byte schema ID + JSON-encoded string."""
    json_bytes = json.dumps(key_str).encode("utf-8")
    return struct.pack(">bI", 0, schema_id) + json_bytes

def main():
    if len(sys.argv) != 6:
        print(f"Usage: {sys.argv[0]} <properties_file> <topic> <sr_url> <sr_key> <sr_secret>", file=sys.stderr)
        sys.exit(1)

    props_file, topic, sr_url, sr_key, sr_secret = sys.argv[1:6]

    conf = load_config(props_file)
    conf["linger.ms"] = "50"
    conf["batch.num.messages"] = "1000"
    conf["compression.type"] = "snappy"
    conf["retries"] = "5"
    conf["retry.backoff.ms"] = "500"

    sr_conf = {
        "url": sr_url,
        "basic.auth.user.info": f"{sr_key}:{sr_secret}",
    }
    sr_client = SchemaRegistryClient(sr_conf)

    # Value serializer via JSONSerializer
    value_subject = f"{topic}-value"
    value_schema = sr_client.get_latest_version(value_subject)
    value_serializer = JSONSerializer(
        value_schema.schema.schema_str,
        sr_client,
    )

    # Key: get schema ID once, build SR wire format manually
    key_subject = f"{topic}-key"
    key_schema_version = sr_client.get_latest_version(key_subject)
    key_schema_id = key_schema_version.schema_id

    producer = Producer(conf)
    count = 0
    errors = 0

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        parts = line.split("|", 1)
        if len(parts) != 2:
            continue

        key_str = parts[0]
        try:
            value_dict = json.loads(parts[1])
        except json.JSONDecodeError:
            errors += 1
            continue

        try:
            serialized_key = make_sr_key_bytes(key_schema_id, key_str)
            ctx = SerializationContext(topic, MessageField.VALUE)
            serialized_value = value_serializer(value_dict, ctx)

            producer.produce(
                topic,
                key=serialized_key,
                value=serialized_value,
            )
            count += 1
            if count % 1000 == 0:
                producer.flush()
                print(f"  {count} messages...", file=sys.stderr)
        except Exception as e:
            errors += 1
            if errors <= 3:
                print(f"  Error on message {count + errors}: {e}", file=sys.stderr)

    producer.flush()
    print(f"{count} messages produced to {topic} (SR key+value)", file=sys.stderr)
    if errors:
        print(f"{errors} messages skipped due to errors", file=sys.stderr)

if __name__ == "__main__":
    main()
