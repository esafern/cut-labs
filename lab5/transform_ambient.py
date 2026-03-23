"""Transform DTrace output to keyed JSON for Kafka ambient-telemetry topic.

Usage:
    python3 transform_ambient.py < dtrace.out > dtrace.tsv

Output format: key|json (pipe-delimited)
Key: {pid}-{process_name} (spaces replaced with underscores)

Handles events: CONN, SEND, RECV, SOCK, CLOS
Skips DTrace header lines and SIP warnings.
"""

import sys, json, re

PATTERN = re.compile(
    r"(\d{4} \w+ \d+ [\d:]+)\s+"
    r"PID=(\d+)\s+"
    r"PROC=(.+?)\s+"
    r"(CONN|SEND|RECV|SOCK|CLOS)\s+"
    r"fd=(\d+)\s*(.*)"
)

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    m = PATTERN.match(line)
    if not m:
        continue
    ts, pid, proc, event, fd, details = m.groups()
    rec = {
        "timestamp": ts,
        "pid": int(pid),
        "process": proc.strip(),
        "event": event,
        "fd": int(fd),
    }
    for kv in re.findall(r"(\w+)=(\d+)", details):
        field, val = kv
        if field == "bytes":
            rec["bytes"] = int(val)
        elif field == "domain":
            rec["domain"] = int(val)
        elif field == "type":
            rec["sock_type"] = int(val)
    key = pid + "-" + proc.strip().replace(" ", "_")
    print(key + "|" + json.dumps(rec))
