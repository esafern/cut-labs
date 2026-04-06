#!/bin/bash
OUT="ambient_snapshot_$(date +%s).json"
python3 -c '
import subprocess, json, os, time

snap = {
    "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "hostname": os.uname().nodename,
    "os_version": subprocess.getoutput("sw_vers -productVersion"),
    "os_build": subprocess.getoutput("sw_vers -buildVersion"),
    "kernel": os.uname().release,
    "arch": os.uname().machine,
    "uptime": subprocess.getoutput("uptime"),
    "running_processes": [],
    "network_interfaces": [],
    "open_connections": [],
    "listening_ports": [],
    "installed_apps": []
}

# Running processes (patent: "list of then-running processes")
for line in subprocess.getoutput("ps -eo pid,ppid,user,comm").strip().split("\n")[1:]:
    parts = line.split(None, 3)
    if len(parts) == 4:
        snap["running_processes"].append({"pid": parts[0], "ppid": parts[1], "user": parts[2], "command": parts[3]})

# Network interfaces (patent: "device characteristics")
for line in subprocess.getoutput("ifconfig -l").split():
    addrs = subprocess.getoutput(f"ifconfig {line} | grep inet").strip()
    if addrs:
        snap["network_interfaces"].append({"interface": line, "addresses": addrs})

# Open TCP connections (patent: "network identity")
for line in subprocess.getoutput("netstat -anp tcp").strip().split("\n")[2:]:
    parts = line.split()
    if len(parts) >= 6:
        snap["open_connections"].append({"local": parts[3], "remote": parts[4], "state": parts[5]})

# Listening ports
for line in subprocess.getoutput("lsof -iTCP -sTCP:LISTEN -P -n").strip().split("\n")[1:]:
    parts = line.split()
    if len(parts) >= 9:
        snap["listening_ports"].append({"command": parts[0], "pid": parts[1], "name": parts[8]})

# Installed apps (patent: "installed applications")
for app in sorted(os.listdir("/Applications")):
    if app.endswith(".app"):
        snap["installed_apps"].append(app[:-4])

print(json.dumps(snap, indent=2))
' > "$OUT"
echo "Snapshot: $OUT ($(wc -l < "$OUT") lines)" >&2
