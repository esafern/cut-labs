#!/usr/bin/env python3
"""Load CUT telemetry from Kafka into PostgreSQL for Grafana dashboards.

Usage:
    python3 load_grafana.py <kafka_props>

Connects to local Postgres (cutlabs/postgres/cutlabs on port 5432).
Consumes all messages from packet-telemetry and ambient-telemetry.
Builds session_summary table with OS/network fingerprints.
"""

import sys
import json
import time
import psycopg2
from confluent_kafka import Consumer


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


def consume_topic(kafka_conf, topic, timeout_empty=20):
    conf = dict(kafka_conf)
    conf["group.id"] = f"grafana-load-{topic}-{int(time.time())}"
    conf["auto.offset.reset"] = "earliest"
    if "message.timeout.ms" in conf:
        del conf["message.timeout.ms"]
    c = Consumer(conf)
    c.subscribe([topic])
    messages = []
    empty = 0
    while empty < timeout_empty:
        msg = c.poll(1.0)
        if msg is None:
            empty += 1
            continue
        if msg.error():
            empty += 1
            continue
        empty = 0
        messages.append((msg.key(), msg.value()))
    c.close()
    return messages


def deser_value(raw):
    if raw and len(raw) > 5 and raw[0] == 0:
        return json.loads(raw[5:])
    return json.loads(raw)


def deser_key(raw):
    if raw and len(raw) > 5 and raw[0] == 0:
        return json.loads(raw[5:])
    return raw.decode("utf-8") if raw else None


def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <kafka_props>", file=sys.stderr)
        sys.exit(1)

    kafka_conf = load_config(sys.argv[1])
    conn = psycopg2.connect(
        host="localhost", port=5432,
        dbname="cutlabs", user="postgres", password="cutlabs"
    )
    cur = conn.cursor()

    print("Creating tables...", file=sys.stderr)
    cur.execute("DROP TABLE IF EXISTS packet_telemetry CASCADE")
    cur.execute("DROP TABLE IF EXISTS ambient_telemetry CASCADE")
    cur.execute("DROP TABLE IF EXISTS session_summary CASCADE")
    cur.execute("""CREATE TABLE packet_telemetry (
        session_key TEXT, src_ip TEXT, src_port INT, dst_ip TEXT, dst_port INT,
        timestamp_epoch DOUBLE PRECISION, direction TEXT, ttl INT, ip_len INT,
        tcp_flags_hex TEXT, tcp_flags_str TEXT, seq_raw TEXT, ack_raw TEXT,
        win_value INT, tcp_payload_len INT, tcp_hdr_len INT, mss INT, wscale INT,
        initial_rtt TEXT, ts_val TEXT, ts_ecr TEXT, time_delta TEXT, protocols TEXT,
        tcp_stream INT, frame_len INT)""")
    cur.execute("""CREATE TABLE ambient_telemetry (
        process_key TEXT, timestamp_str TEXT, pid INT, process TEXT,
        event TEXT, fd INT, bytes INT)""")
    conn.commit()

    print("Consuming packet-telemetry...", file=sys.stderr)
    msgs = consume_topic(kafka_conf, "packet-telemetry")
    print(f"  {len(msgs)} messages received", file=sys.stderr)
    pcount = 0
    for k, v in msgs:
        try:
            key = deser_key(k)
            d = deser_value(v)
            ts = float(d.get("timestamp_epoch", "0"))
            cur.execute(
                """INSERT INTO packet_telemetry VALUES (
                    %s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)""",
                (key, d.get("src_ip"), d.get("src_port"), d.get("dst_ip"), d.get("dst_port"),
                 ts, d.get("direction"), d.get("ttl"), d.get("ip_len"),
                 d.get("tcp_flags_hex"), d.get("tcp_flags_str"), d.get("seq_raw"), d.get("ack_raw"),
                 d.get("win_value"), d.get("tcp_payload_len"), d.get("tcp_hdr_len"),
                 d.get("mss"), d.get("wscale"), d.get("initial_rtt"), d.get("ts_val"), d.get("ts_ecr"),
                 d.get("time_delta"), d.get("protocols"), d.get("tcp_stream"), d.get("frame_len")))
            pcount += 1
        except Exception as e:
            print(f"  skip packet: {e}", file=sys.stderr)
    conn.commit()
    print(f"  {pcount} rows inserted", file=sys.stderr)

    print("Consuming ambient-telemetry...", file=sys.stderr)
    msgs = consume_topic(kafka_conf, "ambient-telemetry")
    print(f"  {len(msgs)} messages received", file=sys.stderr)
    acount = 0
    for k, v in msgs:
        try:
            key = deser_key(k)
            d = deser_value(v)
            cur.execute(
                "INSERT INTO ambient_telemetry VALUES (%s,%s,%s,%s,%s,%s,%s)",
                (key, d.get("timestamp"), d.get("pid"), d.get("process"),
                 d.get("event"), d.get("fd"), d.get("bytes")))
            acount += 1
        except Exception as e:
            print(f"  skip ambient: {e}", file=sys.stderr)
    conn.commit()
    print(f"  {acount} rows inserted", file=sys.stderr)

    print("Building session summary...", file=sys.stderr)
    cur.execute("""CREATE TABLE session_summary AS
        SELECT
            session_key,
            MIN(timestamp_epoch) AS first_packet,
            MAX(timestamp_epoch) AS last_packet,
            COUNT(*) AS packet_count,
            SUM(tcp_payload_len) AS total_bytes,
            MIN(win_value) AS min_window,
            MAX(win_value) AS max_window,
            MAX(mss) AS mss,
            MAX(CASE WHEN direction = 'outbound' AND wscale IS NOT NULL THEN wscale END) AS wscale_out,
            MAX(CASE WHEN direction = 'inbound' AND wscale IS NOT NULL THEN wscale END) AS wscale_in,
            CASE
                WHEN MAX(mss) > 10000 THEN 'loopback'
                WHEN MAX(mss) BETWEEN 1300 AND 1399 THEN 'wireguard-tunnel'
                WHEN MAX(mss) BETWEEN 1400 AND 1460 THEN 'ethernet'
                ELSE 'unknown'
            END AS network_path,
            CASE
                WHEN MAX(CASE WHEN direction = 'outbound' THEN wscale END) = 6 THEN 'macOS'
                WHEN MAX(CASE WHEN direction = 'outbound' THEN wscale END) = 7 THEN 'Linux'
                WHEN MAX(CASE WHEN direction = 'outbound' THEN wscale END) = 8 THEN 'Windows'
                ELSE 'unknown'
            END AS os_outbound,
            CASE
                WHEN MAX(CASE WHEN direction = 'inbound' THEN wscale END) = 6 THEN 'macOS'
                WHEN MAX(CASE WHEN direction = 'inbound' THEN wscale END) = 7 THEN 'Linux'
                WHEN MAX(CASE WHEN direction = 'inbound' THEN wscale END) = 8 THEN 'Windows'
                ELSE 'unknown'
            END AS os_inbound,
            BOOL_OR(win_value = 0) AS has_zero_window
        FROM packet_telemetry
        GROUP BY session_key""")
    conn.commit()

    cur.execute("SELECT COUNT(*) FROM packet_telemetry")
    print(f"  packet_telemetry: {cur.fetchone()[0]} rows", file=sys.stderr)
    cur.execute("SELECT COUNT(*) FROM ambient_telemetry")
    print(f"  ambient_telemetry: {cur.fetchone()[0]} rows", file=sys.stderr)
    cur.execute("SELECT COUNT(*) FROM session_summary")
    print(f"  session_summary: {cur.fetchone()[0]} rows", file=sys.stderr)

    print("Done.", file=sys.stderr)
    cur.close()
    conn.close()


if __name__ == "__main__":
    main()
