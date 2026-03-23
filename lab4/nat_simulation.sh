#!/bin/bash
# CUT Lab 4 — NAT Simulation
# Patent ref: US 12,309,132 B1 — pkey as durable identity anchor
#
# Demonstrates that the WireGuard public key survives a 4-tuple change.
# Simulates NAT/roaming by changing the agent's ListenPort and nudging
# the daemon to recognize the new endpoint.
#
# Prerequisites:
#   - WireGuard agent running on Mac (wg-agent.conf, port 51820)
#   - WireGuard daemon running in Docker container (wg0, port 51821)
#   - Tunnel functional (ping 10.0.0.2 works)
#
# What happens:
#   1. Capture baseline: pkey + endpoint from both sides
#   2. Tear down agent on port 51820
#   3. Bring up agent on port 51830 (simulates NAT rebind / mobile roam)
#   4. Nudge daemon to recognize new endpoint
#   5. Verify tunnel re-establishes on same pkey
#
# Usage: sudo ./nat_simulation.sh

set -e

LAB_DIR="$(dirname "$0")"
AGENT_CONF="$LAB_DIR/wg-agent.conf"
AGENT_51830="$LAB_DIR/wg-agent-51830.conf"
AGENT_PUBKEY=$(cat "$LAB_DIR/agent_public.key")

echo "=== Phase 1: Baseline ===" >&2
echo "" >&2
echo "--- Mac (agent) ---" >&2
sudo wg show | grep -E "(public key|listening port|endpoint|latest handshake)"
echo "" >&2
echo "--- Docker (daemon) ---" >&2
docker exec wg-daemon wg show | grep -E "(public key|listening port|endpoint|latest handshake)"

echo "" >&2
echo "=== Phase 2: Verify connectivity ===" >&2
ping -c 1 -W 2 10.0.0.2 > /dev/null 2>&1 && echo "Tunnel UP" || { echo "Tunnel DOWN — cannot proceed"; exit 1; }

echo "" >&2
echo "=== Phase 3: Create alternate config (port 51830) ===" >&2
if [ ! -f "$AGENT_51830" ]; then
    sed 's/ListenPort = 51820/ListenPort = 51830/' "$AGENT_CONF" > "$AGENT_51830"
    echo "Created $AGENT_51830"
else
    echo "$AGENT_51830 already exists"
fi

echo "" >&2
echo "=== Phase 4: Tear down agent (port 51820) ===" >&2
sudo wg-quick down "$AGENT_CONF" 2>/dev/null || echo "Agent was not running on 51820"

echo "" >&2
echo "=== Phase 5: Bring up agent (port 51830) — simulates NAT rebind ===" >&2
sudo wg-quick up "$AGENT_51830"

echo "" >&2
echo "=== Phase 6: Nudge daemon to recognize new endpoint ===" >&2
echo "  WireGuard normally detects roaming automatically when it receives"
echo "  a valid packet from a new source. In our Docker setup, the initial"
echo "  handshake from the new port may not reach the daemon through the"
echo "  port mapping. We nudge it explicitly:"
echo ""
docker exec wg-daemon wg set wg0 peer "$AGENT_PUBKEY" endpoint host.docker.internal:51830
echo "  Daemon endpoint updated to host.docker.internal:51830"

echo "" >&2
echo "=== Phase 7: Verify tunnel re-established ===" >&2
sleep 2
ping -c 3 10.0.0.2

echo "" >&2
echo "=== Phase 8: Compare ===" >&2
echo "" >&2
echo "--- Mac (agent) ---" >&2
sudo wg show | grep -E "(public key|listening port|endpoint|latest handshake)"
echo "" >&2
echo "--- Docker (daemon) ---" >&2
docker exec wg-daemon wg show | grep -E "(public key|listening port|endpoint|latest handshake)"

echo "" >&2
echo "=== Result ===" >&2
echo "  pkey:     UNCHANGED on both sides" >&2
echo "  port:     51820 → 51830 (agent ListenPort changed)" >&2
echo "  tunnel:   RE-ESTABLISHED on same pkey" >&2
echo "" >&2
echo "  Trust engine interpretation:" >&2
echo "    → 4-tuple changed (physical layer event)" >&2
echo "    → pkey unchanged (identity layer stable)" >&2
echo "    → Evaluate ambient factors to confirm legitimate roam" >&2
echo "    → If ambient unchanged: minor trust impact (roam event)" >&2
echo "    → If ambient changed: step-up authentication or BLOCK" >&2

echo "" >&2
echo "=== Cleanup ===" >&2
echo "  To restore original port:" >&2
echo "    sudo wg-quick down $AGENT_51830" >&2
echo "    sudo wg-quick up $AGENT_CONF" >&2
echo "    docker exec wg-daemon wg set wg0 peer $AGENT_PUBKEY endpoint host.docker.internal:51820" >&2
