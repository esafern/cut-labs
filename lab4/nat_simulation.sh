#!/bin/bash
#
# CUT Lab 4 — NAT Simulation via WireGuard Port Change
#
# Demonstrates that the WireGuard pkey is the durable identity anchor,
# not the 4-tuple. When the agent's UDP port changes (simulating NAT
# rebind or mobile roaming), the tunnel re-establishes on the same pkey.
#
# Patent ref: US 12,309,132 B1 — the trust engine treats 4-tuple changes
# as roam events and evaluates ambient factors to distinguish legitimate
# roaming from session hijack.
#
# Prerequisites:
#   - WireGuard agent running on Mac (wg-agent.conf, port 51820)
#   - WireGuard daemon running in Docker container (wg0.conf, port 51821)
#   - Tunnel verified with: ping -c 1 10.0.0.2
#
# Usage: ./nat_simulation.sh

set -e

LAB_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_CONF="$LAB_DIR/wg-agent.conf"
AGENT_51830_CONF="$LAB_DIR/wg-agent-51830.conf"
DAEMON_PUBKEY=$(cat "$LAB_DIR/daemon_public.key")
AGENT_PUBKEY=$(cat "$LAB_DIR/agent_public.key")
AGENT_PRIVKEY=$(cat "$LAB_DIR/agent_private.key")

echo "=============================================="
echo "  CUT Lab 4 — NAT Simulation (Port Change)"
echo "=============================================="
echo ""

echo "=== Phase 1: Verify baseline tunnel ==="
echo ""
echo "Agent (Mac):"
sudo wg show | grep -E "(public key|listening port|endpoint)" || {
    echo "ERROR: Agent WireGuard not running. Start with:"
    echo "  sudo wg-quick up $AGENT_CONF"
    exit 1
}
echo ""
echo "Daemon (Docker):"
docker exec wg-daemon wg show | grep -E "(public key|listening port|endpoint)" || {
    echo "ERROR: Daemon container not running."
    exit 1
}
echo ""

echo "Ping test (baseline):"
ping -c 1 -W 2 10.0.0.2 > /dev/null 2>&1 && echo "  PASS — tunnel is up" || {
    echo "  FAIL — tunnel not working"
    exit 1
}
echo ""

echo "Recording baseline 4-tuple..."
BASELINE_PORT=$(sudo wg show | grep "listening port" | awk '{print $3}')
BASELINE_ENDPOINT=$(docker exec wg-daemon wg show | grep endpoint | awk '{print $2}')
echo "  Agent listening port: $BASELINE_PORT"
echo "  Daemon sees agent at: $BASELINE_ENDPOINT"
echo ""

read -p "Press Enter to simulate NAT (port change 51820 → 51830)..."
echo ""

echo "=== Phase 2: Create alternate config (port 51830) ==="
cat > "$AGENT_51830_CONF" << EOF
[Interface]
PrivateKey = $AGENT_PRIVKEY
ListenPort = 51830
Address = 10.0.0.1/24

[Peer]
PublicKey = $DAEMON_PUBKEY
AllowedIPs = 10.0.0.2/32
Endpoint = 127.0.0.1:51821
PersistentKeepalive = 25
EOF
echo "  Created $AGENT_51830_CONF"
echo ""

echo "=== Phase 3: Tear down agent on port 51820 ==="
sudo wg-quick down "$AGENT_CONF" 2>/dev/null || true
echo "  Agent stopped"
echo ""

echo "=== Phase 4: Bring up agent on port 51830 ==="
sudo wg-quick up "$AGENT_51830_CONF"
echo ""

echo "=== Phase 5: Nudge daemon to new endpoint ==="
echo "  (Simulates WireGuard roaming — daemon learns new source port)"
docker exec wg-daemon wg set wg0 peer "$AGENT_PUBKEY" endpoint host.docker.internal:51830
echo "  Daemon endpoint updated"
echo ""

echo "=== Phase 6: Verify tunnel survived ==="
echo ""
echo "Ping test (post-NAT):"
ping -c 3 10.0.0.2 && echo "" || {
    echo "  Tunnel did not survive — check container"
    exit 1
}

echo "=== Phase 7: Compare before and after ==="
echo ""
NEW_PORT=$(sudo wg show | grep "listening port" | awk '{print $3}')
NEW_ENDPOINT=$(docker exec wg-daemon wg show | grep endpoint | awk '{print $2}')

echo "  BEFORE:"
echo "    Agent port:     $BASELINE_PORT"
echo "    Daemon saw:     $BASELINE_ENDPOINT"
echo ""
echo "  AFTER:"
echo "    Agent port:     $NEW_PORT"
echo "    Daemon sees:    $NEW_ENDPOINT"
echo ""

echo "  IDENTITY (unchanged):"
echo "    Agent pkey:     $AGENT_PUBKEY"
echo "    Daemon pkey:    $DAEMON_PUBKEY"
echo ""

echo "=== Result ==="
echo ""
echo "  4-tuple CHANGED: port $BASELINE_PORT → $NEW_PORT"
echo "  pkey UNCHANGED:  same public keys on both sides"
echo "  Tunnel SURVIVED: ping successful after port change"
echo ""
echo "  Trust engine interpretation:"
echo "    → Roam event detected (endpoint changed)"
echo "    → Identity verified (pkey matches)"
echo "    → Evaluate ambient factors for step-up decision"
echo ""

read -p "Press Enter to restore original config (port 51820)..."
echo ""

echo "=== Phase 8: Restore ==="
sudo wg-quick down "$AGENT_51830_CONF" 2>/dev/null || true
sudo wg-quick up "$AGENT_CONF"
docker exec wg-daemon wg set wg0 peer "$AGENT_PUBKEY" endpoint host.docker.internal:51820
echo ""
echo "Restored to port 51820. Verifying..."
ping -c 1 -W 2 10.0.0.2 > /dev/null 2>&1 && echo "  PASS — tunnel restored" || echo "  FAIL — check config"
echo ""
echo "Done."
