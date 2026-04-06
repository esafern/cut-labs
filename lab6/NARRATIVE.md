# Lab 6 — Notes

Five terminals: WireGuard tunnel running, DTrace collecting, tcpdump on utun
(cleartext), tcpdump on lo0/bridge (encrypted), mTLS client generating traffic.

Point is to show all three telemetry streams simultaneously. Same traffic, 
different visibility at each layer:

| Layer                  | ISNs | Content                 |
|------------------------|------|-------------------------|
| Kernel (DTrace)        | no   | yes — syscall level     |
| Tunnel (utun/wg0)      | yes  | yes — cleartext         |
| Physical (lo0/bridge)  | no   | no — encrypted UDP only |
| Proxy boundary (lab 2) | yes, 
but different set               | decrypted at middlebox  |

Relay is stateless — 27 WIRE fields, no per-connection memory. Engine derives
9 COMPUTED fields from stored WIRE data. Agent collects process identity and
device state that neither relay nor engine can see.

Correlation is manual at this stage. The Flink SQL queries in
docs/flink_queries.sql show what automated scoring would look like.
