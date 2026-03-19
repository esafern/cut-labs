# Lab 5: DTrace / eBPF — Kernel-Level Telemetry (The Patent's Agent)

## What We're Building

The patent says the agent "has the capability to monitor 'ambient' factors that
operate in the background and that do not require active user interaction"
including "device characteristics, operating system, installed applications,
application versions, scripts, the set of icons on the user's home screen of
a mobile application, a set of bookmarks that has been established for a browser,
a list of then-running processes on a device, a set of mouse movements generally,
and other general or specific user behaviors."

This is kernel-level telemetry collection. On macOS, that's DTrace. On Linux,
that's eBPF. Both provide visibility into process behavior, network events, and
system state without packet capture overhead.

## Why Kernel Tracing, Not Packet Capture

The agent doesn't need `tcpdump` or `libpcap`. Kernel tracing gives you
`{src/dest/len/timestamp}` PLUS process identity without ever touching the
wire. This is:
- More efficient (no copying packets to userspace)
- Harder to evade (applications can't bypass kernel syscalls)
- Richer (includes process name, PID, file descriptors, byte counts)

Labs 1-4 used packet capture to observe the network. Lab 5 observes from
inside the kernel — the same vantage point the patent's agent uses.

## DTrace on macOS

DTrace ships with macOS. System Integrity Protection restricts some probes:
- `syscall` provider — WORKS under SIP. Traces system calls.
- `fbt` (function boundary tracing) — BLOCKED by SIP. Would trace kernel functions.

For this lab, `syscall` is sufficient. It captures:
- `socket()` — when an application creates a network socket
- `connect()` — when an application initiates a connection
- `write()` / `read()` — data transfer with byte counts

The `tcp_telemetry.d` script traces all of these and outputs:
```
TIMESTAMP            PID    PROCESS          EVENT  FD     DETAILS
2026-03-10 14:45:01  12345  nc               SOCK   5      domain=2 type=1
2026-03-10 14:45:01  12345  nc               CONN   5      status=OK
2026-03-10 14:45:01  12345  nc               SEND   5      bytes=12
```

Process name (`nc`), PID, file descriptor, byte count, timestamp. These are
the "ambient factors" the patent describes.

## eBPF on Linux

eBPF is the production-grade equivalent. It runs in-kernel, JIT-compiled, with
formal verification. Available in a Docker container for this lab.

eBPF attaches to kernel tracepoints:
- `tracepoint:tcp:tcp_connect` — new outbound TCP connection
- `tracepoint:tcp:tcp_set_state` — TCP state changes (SYN_SENT, ESTABLISHED, etc.)
- `tracepoint:tcp:tcp_retransmit_skb` — retransmissions
- `tracepoint:tcp:tcp_recv_length` — data receive with length

## What Ambient Factors Each Can Capture

| Factor | DTrace (macOS) | eBPF (Linux) |
|--------|---------------|-------------|
| Running processes | `proc:::exec-success` | `sched:sched_process_exec` |
| Network connections | `syscall::connect` | `tcp:tcp_connect` |
| File access | `syscall::open` | `syscalls:sys_enter_openat` |
| DNS lookups | `syscall::sendto` (port 53) | `udp_sendmsg` kprobe |
| Process tree | `proc:::create` | `sched:sched_process_fork` |
| Byte counts | `syscall::write/read` returns | `tcp_sendmsg`/`tcp_recvmsg` |

## The Trust Engine Scoring Model

Each eBPF/DTrace data stream becomes a separate scoring dimension:
- Connection patterns (which processes connect where, how often)
- Data transfer volumes (how much does this user typically transfer)
- Process inventory (what's running on this device)
- File access patterns (is the user accessing unusual resources)

The patent says the engine "computes a set of trust indexes, typically one trust
index per authentication factor." Each ambient signal is a factor. The aggregate
determines whether authentication requirements should step up or step down.

## Key Insight for Architecture Discussion

The agent collects what neither the relay nor the engine can see. The relay sees
encrypted metadata. The engine sees stored telemetry. Only the agent sees which
process opened a connection, what else is running on the device, and the local
system state. This three-layer separation is the architecture:

- **Agent:** Sees everything locally, sends ambient factors + encrypted traffic
- **Relay:** Sees encrypted traffic metadata only, forwards to engine
- **Engine:** Sees stored telemetry from both, computes trust scores
