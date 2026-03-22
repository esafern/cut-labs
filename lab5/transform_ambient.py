"""Transform DTrace output to keyed JSON for Kafka ambient-telemetry topic.

Usage:
    python3 transform_ambient.py < dtrace.out > dtrace.tsv

Output format: key|json (pipe-delimited)
Key: {pid}-{process_name} (spaces replaced with underscores)
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
    if "bytes=" in details:
        rec["bytes"] = int(details.split("bytes=")[1].split()[0])
    if "domain=" in details:
        rec["domain"] = int(details.split("domain=")[1].split()[0])
    if "type=" in details:
        rec["sock_type"] = int(details.split("type=")[1].split()[0])
    key = pid + "-" + proc.strip().replace(" ", "_")
    print(key + "|" + json.dumps(rec))
