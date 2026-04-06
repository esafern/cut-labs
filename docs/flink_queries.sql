-- CUT Trust Engine — Flink SQL Queries
-- Run in Confluent Cloud Flink SQL workspace
-- Prerequisites: USE CATALOG `default`; USE `packetsCluster`;

-- ============================================================
-- Query 1: Session Summary
-- Every TCP session with packet counts, byte volumes, window
-- behavior, and MSS (network path fingerprint).
-- ============================================================

SELECT 
  `key`,
  MIN(timestamp_epoch) AS first_packet,
  MAX(timestamp_epoch) AS last_packet,
  COUNT(*) AS packet_count,
  SUM(tcp_payload_len) AS total_bytes,
  MIN(win_value) AS min_window,
  MAX(mss) AS mss
FROM `packet-telemetry`
GROUP BY `key`;

-- ============================================================
-- Query 2: Zero Window Detection
-- Finds flow stalls — possible choking intermediary.
-- win_value=0 is a WIRE field: no state, no payload inspection.
-- ============================================================

SELECT
  `key`,
  timestamp_epoch,
  win_value,
  tcp_payload_len,
  direction
FROM `packet-telemetry`
WHERE win_value = 0;

-- ============================================================
-- Query 3: Sessions with Anomalous Window Behavior
-- A session where min_window=0 had a complete stall.
-- ============================================================

SELECT
  `key`,
  COUNT(*) AS packet_count,
  MIN(win_value) AS min_window,
  MAX(win_value) AS max_window,
  SUM(tcp_payload_len) AS total_bytes,
  MAX(mss) AS mss
FROM `packet-telemetry`
GROUP BY `key`
HAVING MIN(win_value) = 0;

-- ============================================================
-- Query 4: Device Process Inventory
-- Patent: "a list of then-running processes on a device."
-- Every process that made network syscalls.
-- The trust engine baselines this set. New processes = signal.
-- ============================================================

SELECT
  process,
  event,
  COUNT(*) AS event_count,
  SUM(CASE WHEN `bytes` IS NOT NULL THEN `bytes` ELSE 0 END) AS total_bytes
FROM `ambient-telemetry`
GROUP BY process, event;

-- ============================================================
-- Query 5: Connection-Making Processes
-- Which processes initiated outbound connections?
-- A new process making CONN events that wasn't in the baseline
-- is a trust signal.
-- ============================================================

SELECT
  process,
  COUNT(*) AS connection_count
FROM `ambient-telemetry`
WHERE event = 'CONN'
GROUP BY process;

-- ============================================================
-- Query 6: High-Volume Processes
-- Processes by bytes transferred.
-- Sudden volume change = behavioral anomaly.
-- New process with high volume = possible exfiltration.
-- ============================================================

SELECT
  process,
  SUM(CASE WHEN `bytes` IS NOT NULL THEN `bytes` ELSE 0 END) AS total_bytes,
  COUNT(*) AS event_count
FROM `ambient-telemetry`
WHERE event IN ('SEND', 'RECV')
GROUP BY process;

-- ============================================================
-- Query 7: Data Payload Sessions
-- Sessions that transferred application data.
-- Filters out handshake-only and keepalive sessions.
-- ============================================================

SELECT
  `key`,
  src_ip,
  dst_ip,
  dst_port,
  COUNT(*) AS packet_count,
  SUM(tcp_payload_len) AS payload_bytes,
  MIN(timestamp_epoch) AS started,
  MAX(mss) AS mss
FROM `packet-telemetry`
WHERE tcp_payload_len > 0
GROUP BY `key`, src_ip, dst_ip, dst_port;

-- ============================================================
-- Query 8: Network Path Fingerprint (MSS)
-- MSS reveals the network path:
--   16344 = loopback (no encapsulation)
--   1380  = WireGuard tunnel (1420 MTU - 40 headers)
--   1460  = standard ethernet
-- Session changing MSS = changed network path = trust signal.
-- ============================================================

SELECT
  `key`,
  MAX(mss) AS mss,
  CASE 
    WHEN MAX(mss) > 10000 THEN 'loopback'
    WHEN MAX(mss) BETWEEN 1300 AND 1399 THEN 'wireguard-tunnel'
    WHEN MAX(mss) BETWEEN 1400 AND 1460 THEN 'ethernet'
    ELSE 'unknown'
  END AS network_path
FROM `packet-telemetry`
WHERE mss IS NOT NULL AND mss > 0
GROUP BY `key`;

-- ============================================================
-- Query 9: OS Fingerprint (wscale)
-- Window scale in SYN reveals the OS:
--   wscale=6 = macOS
--   wscale=7 = Linux
--   wscale=8 = Windows 10+
-- wscale change between sessions from same pkey = device changed.
-- ============================================================

SELECT
  `key`,
  src_ip,
  direction,
  MAX(wscale) AS wscale,
  CASE 
    WHEN MAX(wscale) = 6 THEN 'macOS'
    WHEN MAX(wscale) = 7 THEN 'Linux'
    WHEN MAX(wscale) = 8 THEN 'Windows'
    ELSE 'unknown'
  END AS os_fingerprint
FROM `packet-telemetry`
WHERE wscale IS NOT NULL AND wscale > 0
GROUP BY `key`, src_ip, direction;

-- ============================================================
-- Query 10: Cross-Stream Correlation
-- All connection-making processes correlated with all data
-- sessions. No hardcoded process names — the trust engine
-- discovers which processes are generating traffic.
-- ============================================================

SELECT
  a.process,
  a.event,
  COUNT(DISTINCT p.`key`) AS concurrent_sessions,
  COUNT(*) AS ambient_events
FROM `ambient-telemetry` a
CROSS JOIN `packet-telemetry` p
WHERE a.event = 'CONN'
  AND p.tcp_payload_len > 0
GROUP BY a.process, a.event;
