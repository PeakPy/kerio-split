#!/bin/sh
# Privileged Linux smoke test — no Kerio binary required.
# Simulates a tun device + full-tunnel hijack, then runs apply/restore.
set -eu

echo "== dry-run unit path =="
python3 -m keriosplit ping --platform dry-run
python3 -m keriosplit apply --platform dry-run -v --config /src/config/config.example.json

echo "== linux fake tunnel =="
# Clean leftover state
rm -rf /tmp/keriosplit-state
mkdir -p /tmp/keriosplit-state

# Fake Kerio-like NIC
ip link add kvnet0 type dummy 2>/dev/null || true
ip link set kvnet0 up
ip addr add 10.8.0.2/24 peer 10.8.0.1 dev kvnet0 2>/dev/null || ip addr add 10.8.0.2/24 dev kvnet0

# Fake LAN default (dummy gateway on lo is awkward; use a second dummy)
ip link add lan0 type dummy 2>/dev/null || true
ip link set lan0 up
ip addr add 192.168.1.10/24 dev lan0
ip route replace default via 192.168.1.1 dev lan0 onlink

# Full-tunnel hijack like Kerio
ip route replace 0.0.0.0/1 via 10.8.0.1 dev kvnet0 onlink
ip route replace 128.0.0.0/1 via 10.8.0.1 dev kvnet0 onlink

python3 -m keriosplit status --platform linux --config /src/config/config.example.json
python3 -m keriosplit apply --platform linux -v --config /src/config/config.example.json

echo "-- routes after apply --"
ip route show | sed -n '1,40p'

# Expect VPN CIDR via kvnet and hijack gone
ip route show 192.168.70.0/24 | grep -q kvnet0
ip route show 0.0.0.0/1 | grep -q . && exit 1 || true
ip route show 128.0.0.0/1 | grep -q . && exit 1 || true

python3 -m keriosplit restore --platform linux -v --config /src/config/config.example.json
ip route show 192.168.70.0/24 | grep -q . && exit 1 || true

echo "linux docker smoke OK"
