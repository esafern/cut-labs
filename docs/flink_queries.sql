-- CUT Trust Engine — Flink SQL Queries
-- Run in Confluent Cloud Flink SQL workspace
-- Prerequisites: USE CATALOG `default`; USE `packetsCluster`;

-- ============================================================
-- Query 1: Session Summary (all labs)
-- Shows every TCP session across all captures with packet counts,
-- byte volumes, minimum window, and MSS (network path indicator).
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
-- Query 2: Zero Window Detection (trust signal)
-- Finds flow stalls — DPI choke indicator.
-- Patent: trust engine detects anomalies in {src/dest/len/timestamp}.
-- win_value=0 is a WIRE field, detectable at the relay with no state.
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
-- Query 3: Device Fingerprint (ambient factors)
-- Patent: "device characteristics, operating system, installed
-- applications, a list of then-running processes."
-- Every process that made network syscalls during capture.
-- ============================================================

SELECT
  process,
  event,
  COUNT(*) AS event_count,
  SUM(CASE WHEN `bytes` IS NOT NULL THEN `bytes` ELSE 0 END) AS total_bytes
FROM `ambient-telemetry`
GROUP BY process, event;

-- ============================================================
-- Query 4: Packet-Ambient Correlation (the trust engine join)
-- Correlates network telemetry with process identity.
-- "At the moment this packet crossed the relay, which process
-- on the device generated it?"
-- ============================================================

SELECT 
  p.`key` AS session,
  p.src_ip,
  p.dst_port,
  p.tcp_payload_len,
  p.direction,
  a.process,
  a.event,
  a.`bytes` AS ambient_bytes
FROM `packet-telemetry` p
CROSS JOIN `ambient-telemetry` a
WHERE a.process = 'nc'
  AND p.tcp_payload_len > 0
  AND p.dst_port = 9999
LIMIT 10;
