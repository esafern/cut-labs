# Lab 5 — Notes

DTrace for kernel-level telemetry — the patent's ambient factor collection.
Traces socket(), connect(), write(), read() syscalls and outputs process name,
PID, file descriptor, byte count, timestamp. Richer than packet capture and
harder to evade — applications can't bypass kernel syscalls.

SIP restricts the fbt (function boundary tracing) provider on macOS. The
syscall provider works fine without disabling SIP. That's sufficient for what
the patent describes — process identity and connection behavior, not kernel
internals.

tcp_telemetry.d runs and pipes output through transform_ambient.py > produce_sr.py
> ambient-telemetry topic. capture_ambient.sh snapshots device state separately:
running processes, installed apps, network interfaces, listening ports. That's the
device-snapshot topic — the "list of then-running processes" the patent describes.

Three ambient snapshots in the data (1773987777, 1773988116, 1774160468 — Unix
timestamps). Each is ~200KB of JSON, the full device state at that moment. The
delta between snapshots is what the trust engine baselines against. New process
making CONN events that wasn't in the prior snapshot is a trust signal.

eBPF is the Linux equivalent and the production path — JIT-compiled, formally
verified, runs in-kernel. Same probe points: tcp_connect, tcp_set_state,
tcp_retransmit. DTrace and eBPF output the same logical schema; transform_ambient.py
normalizes both to the same Kafka message format.

