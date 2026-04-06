# Lab 3 — Notes

TCP zero window as a trust signal. StallServer holds a small receive buffer (4096)
and doesn't read from the socket for 5 seconds — simulates a DPI engine that's busy.
FloodSender writes 8192-byte chunks as fast as possible.

Window descent in the capture: 17285 → 15237 → 13189 → 11141 → 9093 → 7045 → 4997
→ 2949 → 901 → 0. Steps of ~2048 — that's the 8192-byte sender chunk divided by
the window scale factor of 4. Buffer filling in under 200ms.

Zero window at 18:39:33.701, 5-second gap back to 18:39:28.700 — that's the stall.
After that, sawtooth recovery: window jumps up when the reader drains, descends fast
when the sender refills, bottoms around 1400-1800, repeats every ~700ms. Peak drops
slightly each cycle (34514 → 34413 → 34312...) because reader is marginally slower
than sender.

Tried 15s stall with 64-byte reads first. Connection RST'd before recovery — too slow
to drain before TCP's persist timer gave up. The [R.] in the capture is TCP saying
the connection has been idle too long, not a code bug. Switched to 5s stall with
4096-byte reads at 10ms delay for the clean three-phase result.

All of this is visible in WIRE fields alone. win_value == 0 is a single comparison.
The 5-second timestamp gap and the sawtooth period are in frame.time_epoch. No
payload inspection. The Flink SQL query in docs/flink_queries.sql detects it with
a windowed aggregation — zero_window_count > 0 in a 10-second tumble.

