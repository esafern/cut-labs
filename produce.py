#!/usr/bin/env python3
"""Fast Kafka producer using confluent-kafka (librdkafka).

Usage:
    python3 produce.py <properties_file> <topic> < data.tsv
    cat data.tsv | python3 produce.py <properties_file> <topic>

Input format: key|value (pipe-delimited, one message per line)
"""

import sys
from confluent_kafka import Producer

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

def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <properties_file> <topic>", file=sys.stderr)
        sys.exit(1)

    conf = load_config(sys.argv[1])
    conf["linger.ms"] = "50"
    conf["batch.num.messages"] = "1000"
    conf["compression.type"] = "snappy"
    conf["retries"] = "5"
    conf["retry.backoff.ms"] = "500"

    topic = sys.argv[2]
    p = Producer(conf)

    count = 0
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        parts = line.split("|", 1)
        if len(parts) == 2:
            p.produce(topic, key=parts[0].encode(), value=parts[1].encode())
        else:
            p.produce(topic, value=line.encode())
        count += 1
        if count % 1000 == 0:
            p.flush()
            print(f"  {count} messages...", file=sys.stderr)

    p.flush()
    print(f"{count} messages produced to {topic}", file=sys.stderr)

if __name__ == "__main__":
    main()
