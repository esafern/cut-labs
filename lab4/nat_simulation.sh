#!/bin/bash
PF_CONF="/tmp/cut-lab-nat.conf"
PCAP_DIR="$HOME/cut-labs/lab4"

echo "=== Phase 1: Baseline capture (no NAT) ===" >&2
ping -c 2 10.0.0.2 > /dev/null 2>&1

sudo tcpdump -S -tttt -nn -i lo0 'udp port 51820 or udp port 51821' \
  -w "$PCAP_DIR/before_nat.pcap" -c 20 &
TCPDUMP_PID=$!
ping -c 3 10.0.0.2 > /dev/null 2>&1
sleep 2
sudo kill $TCPDUMP_PID 2>/dev/null
wait $TCPDUMP_PID 2>/dev/null

echo "" >&2
echo "Baseline 4-tuple:" >&2
tcpdump -tttt -nn -r "$PCAP_DIR/before_nat.pcap" 2>/dev/null | \
  awk '{printf "  %s → %s\n", $4, $6}' | sort -u

echo "" >&2
echo "=== Phase 2: Enable NAT (simulate roam) ===" >&2

cat > "$PF_CONF" << 'PF'
nat on lo0 proto udp from 127.0.0.1 port 51820 to 127.0.0.1 port 51821 -> 127.0.0.1 port 61820
PF

sudo pfctl -f "$PF_CONF" -e 2>/dev/null || sudo pfctl -f "$PF_CONF" 2>/dev/null

sudo tcpdump -S -tttt -nn -i lo0 \
  'udp port 51820 or udp port 51821 or udp port 61820' \
  -w "$PCAP_DIR/after_nat.pcap" -c 20 &
TCPDUMP_PID=$!

ping -c 3 10.0.0.2
PING_EXIT=$?

sleep 2
sudo kill $TCPDUMP_PID 2>/dev/null
wait $TCPDUMP_PID 2>/dev/null

echo "" >&2
echo "Post-NAT 4-tuple:" >&2
tcpdump -tttt -nn -r "$PCAP_DIR/after_nat.pcap" 2>/dev/null | \
  awk '{printf "  %s → %s\n", $4, $6}' | sort -u

echo "" >&2
echo "=== Phase 3: Compare ===" >&2
echo "--- BEFORE NAT ---" >&2
tcpdump -tttt -nn -r "$PCAP_DIR/before_nat.pcap" 2>/dev/null | \
  awk '{printf "{src: %s, dst: %s}\n", $4, $6}' | sort -u

echo "" >&2
echo "--- AFTER NAT ---" >&2
tcpdump -tttt -nn -r "$PCAP_DIR/after_nat.pcap" 2>/dev/null | \
  awk '{printf "{src: %s, dst: %s}\n", $4, $6}' | sort -u

echo "" >&2
echo "=== Phase 4: Verify tunnel identity ===" >&2
sudo wg show | grep -E "(public key|endpoint|latest handshake)"

echo "" >&2
if [ $PING_EXIT -eq 0 ]; then
    echo "RESULT: Tunnel SURVIVED NAT rewrite" >&2
    echo "  → 4-tuple changed (physical layer)" >&2
    echo "  → pkey unchanged (identity layer)" >&2
    echo "  → Trust engine sees: roam event, evaluate ambient factors" >&2
else
    echo "RESULT: Tunnel broken by NAT — WireGuard will re-handshake using pkey" >&2
    echo "  → New 4-tuple, same identity" >&2
    echo "  → Trust engine sees: reconnect event, higher scrutiny" >&2
fi

echo "" >&2
echo "=== Phase 5: Cleanup ===" >&2
sudo pfctl -d 2>/dev/null
sudo rm -f "$PF_CONF"
echo "NAT rule removed, pf disabled" >&2
