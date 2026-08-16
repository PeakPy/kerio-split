#!/bin/bash
# Snapshot routing/DNS/interfaces before or after Kerio connect.
# Usage: ./Scripts/diagnose.sh before|after
set -u

LABEL="${1:-snapshot}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/Diagnostics"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/kerio-${LABEL}-${STAMP}.txt"

{
  echo "======== KerioSplit diagnose ($LABEL) ========"
  echo "date: $(date)"
  echo "host: $(hostname)"
  echo
  sw_vers
  echo
  echo "----- processes -----"
  ps aux 2>/dev/null | grep -iE 'kerio|kvpn' | grep -v grep || true
  echo
  echo "----- ifconfig -----"
  ifconfig -a
  echo
  echo "----- scutil --nwi -----"
  scutil --nwi 2>/dev/null || true
  echo
  echo "----- netstat -rn -f inet -----"
  netstat -rn -f inet
  echo
  echo "----- route get default -----"
  route -n get default 2>/dev/null || true
  echo
  echo "----- route get 1.1.1.1 -----"
  route -n get 1.1.1.1 2>/dev/null || true
} | tee "$OUT"

echo
echo "Saved: $OUT"
