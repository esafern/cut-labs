# Lab 3: TCP Zero Window (Performance Choke / Trust Signal)

## What We're Demonstrating

The patent's trust engine watches telemetry for anomalies. One anomaly is a flow
that stalls — data stops moving. In the real world, this happens when a DPI engine
(deep packet inspection) sits in the traffic path and can't keep up. It inspects
every packet, falls behind, its receive buffer fills, and TCP flow control kicks
in. The sender stops sending.

From the trust engine's view of the `{src/dest/len/timestamp}` stream: `len`
drops to zero, timestamp gaps appear. That's a trust signal. Detectable from
WIRE fields alone — no payload inspection needed.

## How TCP Flow Control Works

Every TCP packet includes a `window` field. This tells the other side "I have
this many bytes of buffer space available for you to send into."

When the receiver's application reads data from the socket, buffer space frees
up and the window grows. When the application stops reading (or reads too
slowly), the buffer fills and the window shrinks.

When the window hits zero, the receiver is saying "STOP — I have no room." The
sender must stop sending. This is called a **zero window condition**.

The sender doesn't just give up — it enters **persist mode**, sending tiny 1-byte
probes every few seconds asking "do you have room yet?" In our capture, these
appeared as 5-second gaps between `win 0` packets.

This is not an error. It's TCP working correctly. Flow control prevents the
sender from overwhelming the receiver. But it IS an observable condition that
the trust engine can detect purely from metadata.

## What the Java Programs Do

**StallServer.java** simulates a DPI engine that chokes:
1. Creates a `ServerSocket` with a small receive buffer (`setReceiveBufferSize(4096)`)
2. Accepts a connection
3. Does NOT read from the socket for `stallSeconds` — simulates the DPI engine
   being busy inspecting previous packets
4. Then starts reading slowly — small reads with sleep between them — simulates
   the DPI engine partially recovering but still struggling

**FloodSender.java** simulates normal traffic flow:
1. Connects to the server
2. Writes 8192-byte chunks as fast as possible
3. Reports progress every 256KB

## What Happens in the TCP Stack

1. Sender connects, handshake completes. Server's window is 65535 (initial).
2. Sender starts flooding data. Server's application isn't reading (stalled).
3. The server's kernel receive buffer fills. As it fills, the kernel reduces
   the advertised window in each ACK.
4. We observed the descent:
   `17285 → 15237 → 13189 → 11141 → 9093 → 7045 → 4997 → 2949 → 901 → 0`
   Each step is ~2048 — that's 8192 bytes (sender chunk size) divided by 4
   (window scale factor means each unit represents scaled bytes).
5. At `win 0`, the sender blocks. `out.write(data)` in Java blocks inside the
   kernel because the send buffer is also full — the kernel can't send because
   the receiver said stop.
6. The sender enters persist mode — sends 1-byte window probes every 5 seconds.
7. After the stall, the server starts reading. Each `recv()` frees buffer space.
   The kernel advertises a larger window. The sender resumes.

## The Three Phases in the Capture

### Phase 1 — Descent (sub-second)

```
65535 → 40830 → 39806 → 38782 → ... → 2949 → 901 → 895
```

Buffer filling in under 200ms. Window decreasing by ~1024 per ACK.

### Phase 2 — Zero Window (5 seconds)

```
win=0    (18:39:33.701)
```

One `win 0` packet. The 5-second gap from 18:39:28.700 to 18:39:33.701 is the
stall period — server sleeping, buffer full.

### Phase 3 — Recovery Sawtooth (several seconds)

```
33.765: 32696 → 30655 → ... → 1856    (reader drains, sender refills)
34.479: 34514 → 32473 → ... → 1755    (cycle repeats)
35.270: 34413 → 32372 → ... → 1654    (cycle repeats)
35.991: 34312 → ... → 1554            (cycle repeats)
36.710: 34212 → ... → 1453            (cycle repeats)
37.416: 34111 → ... → 1352            (cycle repeats)
38.131: 34010 → ... → 7395            (final cycle, sender running out)
38.847: 40053                          (sender done, buffer fully drained)
```

This is the sawtooth. Every ~700ms: window jumps up (reader drained buffer),
descends rapidly (sender refills), bottoms out around 1400-1800, brief pause,
repeats. The peak drops slightly each cycle (34514 → 34413 → 34312 → 34212 →
34111 → 34010) because the reader is slightly slower than the sender.

The sawtooth is the signature of a choking intermediary. A DPI engine that
processes packets in bursts creates exactly this pattern.

## Parameter Tuning

**15s stall, 64-byte reads, 100ms delay** (640 bytes/sec drain rate):
Connection RSTs before recovery. The reader is too slow to drain the buffer
before TCP's timeout expires. The last packet shows `Flags [R.]` — reset.
Useful to know about but not useful for the demo.

**5s stall, 4096-byte reads, 10ms delay** (409,600 bytes/sec drain rate):
Clean three-phase capture. Stalls long enough for zero window, recovers fast
enough to show the sawtooth before any timeout.

The RST (`Flags [R.]`) is not an error in our code. It's TCP saying "this
connection has been idle too long with no progress." The persist timer probes
weren't enough to keep the connection alive through a 15-second stall with
negligible progress.

## What the Trust Engine Sees

Looking at the `{src/dest/len/timestamp}` telemetry stream:

**Normal flow:** `len=8192, len=8192, len=8192...` at sub-millisecond intervals

**Buffer filling:** `win_value` decreasing in the server's ACKs

**Zero window:** `win_value=0`, `len=0` in all packets, 5-second timestamp gaps

**Recovery:** Oscillating `win_value`, erratic `len` values, ~700ms cycle period

All of this is visible in WIRE fields. No payload inspection needed. The trust
engine could score this as: "traffic flow to this service stalled for 5 seconds,
then exhibited unstable throughput with 700ms oscillation. Possible choking
intermediary. Flag for review. Potential authentication step-up."

The specific WIRE fields that matter:
- `win_value == 0` — the zero window itself (stateless check, trivial)
- `timestamp_epoch` deltas — the 5-second gap during stall
- `tcp_payload_len` — drops to 0 during stall, erratic during recovery
- `tcp_flags_hex` — RST (0x0004) if the connection dies

## Wireshark Visualization

Open the pcap in Wireshark. Critical: click a packet where SOURCE PORT is 7777
(server → client direction) before opening the graph. If you click a client→server
packet, you see the client's window, which stays high the whole time.

**TCP Stream Graphs → Window Scaling:** Shows the descent → zero → sawtooth
as a time series. The visual is immediate and compelling for a demo.

**IO Graphs alternative:** Statistics → IO Graphs, add graph with display filter
`tcp.srcport == 7777`, Y Axis = `tcp.window_size`, Style = Line.

**Expert Info** (Analyze → Expert Information): Lists every zero window event,
window update, and retransmission in a clickable summary. This is the COMPUTED
field set rendered visually.

## How This Maps to the Patent

The patent's continuous trust engine monitors "telemetry extracted from the
traffic flows" (element 120). The telemetry includes `{src/dest/len/timestamp}`.

A zero window event is detectable from one WIRE field: `win_value == 0`. This
is why we flagged `is_zero_window` as a COMPUTED field that's trivially derivable —
it's literally a comparison against zero.

The more nuanced signal is the sawtooth recovery pattern. This requires
tracking `win_value` over a time window — a windowed aggregation in Flink SQL:

```sql
SELECT
  src_ip, dst_ip, dst_port,
  TUMBLE_START(event_time, INTERVAL '10' SECOND) as window_start,
  MIN(win_value) as min_window,
  MAX(win_value) as max_window,
  COUNT(*) FILTER (WHERE win_value = 0) as zero_window_count
FROM packet_telemetry
GROUP BY src_ip, dst_ip, dst_port, TUMBLE(event_time, INTERVAL '10' SECOND)
HAVING COUNT(*) FILTER (WHERE win_value = 0) > 0
```

This is the trust engine query for Lab 3's signal. It runs continuously on
the Kafka topic, scoring every 10-second window for every session.
