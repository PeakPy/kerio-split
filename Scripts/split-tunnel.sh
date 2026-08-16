#!/bin/bash
# Kerio Control split-tunnel helper for macOS.
#
# Removes Kerio full-tunnel hijacks (0/1 + 128.0/1) and installs routes from
# Config/targets.txt (or Application Support copy) via the VPN gateway.
#
# Usage:
#   sudo ./Scripts/split-tunnel.sh capture|apply|restore|status

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Prefer user-writable Application Support config (DMG /Applications install).
REAL_HOME="${SUDO_USER:+$(eval echo "~${SUDO_USER}")}"
REAL_HOME="${REAL_HOME:-$HOME}"
SUPPORT_TARGETS="${REAL_HOME}/Library/Application Support/KerioSplit/Config/targets.txt"
FALLBACK_TARGETS="${REAL_HOME}/.kerio-split/Config/targets.txt"
if [[ -f "$SUPPORT_TARGETS" ]]; then
  TARGETS_FILE="$SUPPORT_TARGETS"
elif [[ -f "$FALLBACK_TARGETS" ]]; then
  TARGETS_FILE="$FALLBACK_TARGETS"
elif [[ -f "$ROOT/Config/targets.txt" ]]; then
  TARGETS_FILE="$ROOT/Config/targets.txt"
else
  TARGETS_FILE="$SUPPORT_TARGETS"
fi

# When run via sudo, HOME may be /var/root — prefer invoking user's home.
STATE_DIR="${REAL_HOME}/Library/Application Support/KerioSplit"
# Always reclaim ownership after sudo so the GUI can write here later.
if [[ "$(id -u)" -eq 0 && -n "${SUDO_USER:-}" ]]; then
  mkdir -p "$STATE_DIR/Config" 2>/dev/null || true
  chown -R "${SUDO_USER}:staff" "$STATE_DIR" 2>/dev/null || true
  chmod -R u+rwX "$STATE_DIR" 2>/dev/null || true
fi
if [[ ! -d "$STATE_DIR" ]] || { [[ "$(id -u)" -ne 0 ]] && [[ ! -w "$STATE_DIR" ]]; }; then
  STATE_DIR="${REAL_HOME}/.kerio-split"
fi
STATE_FILE="$STATE_DIR/saved-routes.env"

mkdir -p "$STATE_DIR"

log() { echo "[KerioSplit] $*"; }
die() { echo "[KerioSplit] ERROR: $*" >&2; exit 1; }

need_root() {
  [[ "$(id -u)" -eq 0 ]] || die "run with sudo"
}

# --- detection (works across MacBooks) --------------------------------------

lan_default_gateway() {
  netstat -rn -f inet 2>/dev/null | awk '
    $1 == "default" && $4 ~ /^en[0-9]+$/ { print $2; exit }
  '
}

lan_default_interface() {
  netstat -rn -f inet 2>/dev/null | awk '
    $1 == "default" && $4 ~ /^en[0-9]+$/ { print $4; exit }
  '
}

vpn_fulltunnel_gateway() {
  netstat -rn -f inet 2>/dev/null | awk '
    $1 == "0/1" { print $2; exit }
  '
}

vpn_fulltunnel_interface() {
  netstat -rn -f inet 2>/dev/null | awk '
    $1 == "0/1" { print $NF; exit }
  '
}

# Globals filled by load_state
BEFORE_DEFAULT_GW=""
BEFORE_DEFAULT_IF=""
BEFORE_IFACES=""
BEFORE_DNS_SERVICE=""
BEFORE_DNS=""
VPN_IF=""
VPN_GW=""

state_get() {
  local key="$1"
  [[ -f "$STATE_FILE" ]] || return 0
  local line val
  line="$(grep -E "^${key}=" "$STATE_FILE" 2>/dev/null | tail -1 || true)"
  [[ -n "$line" ]] || return 0
  val="${line#*=}"
  if [[ "$val" == \'*\' ]]; then
    val="${val:1:${#val}-2}"
  elif [[ "$val" == \"*\" ]]; then
    val="${val:1:${#val}-2}"
  fi
  printf '%s' "$val"
}

load_state() {
  BEFORE_DEFAULT_GW="$(state_get BEFORE_DEFAULT_GW)"
  BEFORE_DEFAULT_IF="$(state_get BEFORE_DEFAULT_IF)"
  BEFORE_IFACES="$(state_get BEFORE_IFACES)"
  BEFORE_DNS_SERVICE="$(state_get BEFORE_DNS_SERVICE)"
  BEFORE_DNS="$(state_get BEFORE_DNS)"
  VPN_IF="$(state_get VPN_IF)"
  VPN_GW="$(state_get VPN_GW)"
}

detect_vpn_interface() {
  local from_route
  from_route="$(vpn_fulltunnel_interface || true)"
  if [[ -n "$from_route" ]]; then
    echo "$from_route"
    return 0
  fi

  load_state

  local ifc inet
  for ifc in $(ifconfig -l); do
    case "$ifc" in
      utun*|kvnet*|kerio*) ;;
      *) continue ;;
    esac
    inet="$(ifconfig "$ifc" 2>/dev/null | awk '/inet /{print $2; exit}')"
    [[ -n "$inet" ]] || continue
    if [[ -n "${BEFORE_IFACES:-}" && " ${BEFORE_IFACES} " != *" $ifc "* ]]; then
      echo "$ifc"
      return 0
    fi
  done

  for ifc in $(ifconfig -l); do
    case "$ifc" in utun*) ;; *) continue ;; esac
    if ifconfig "$ifc" 2>/dev/null | grep -q 'inet '; then
      echo "$ifc"
      return 0
    fi
  done
  return 1
}

detect_vpn_gateway() {
  local gw
  gw="$(vpn_fulltunnel_gateway || true)"
  if [[ -n "$gw" ]]; then
    echo "$gw"
    return 0
  fi

  local ifc inet
  ifc="$(detect_vpn_interface || true)"
  [[ -n "$ifc" ]] || return 1
  inet="$(ifconfig "$ifc" 2>/dev/null | awk '/inet /{print $2; exit}')"
  [[ -n "$inet" ]] || return 1
  echo "${inet%.*}.1"
}

primary_network_service() {
  local ifc="$1"
  networksetup -listallhardwareports 2>/dev/null | awk -v dev="$ifc" '
    /^Hardware Port:/ { port=$0; sub(/^Hardware Port: /,"",port) }
    /^Device:/ && $2==dev { print port; exit }
  '
}

read_targets() {
  [[ -f "$TARGETS_FILE" ]] || die "missing targets file: $TARGETS_FILE"
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    {
      if ($1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/) print $1
    }
  ' "$TARGETS_FILE"
}

# --- state ------------------------------------------------------------------

save_before_state() {
  local gw ifc ifaces dns svc stamp
  gw="$(lan_default_gateway || true)"
  ifc="$(lan_default_interface || true)"
  ifaces="$(ifconfig -l)"
  svc="$(primary_network_service "${ifc:-en0}" || true)"
  dns=""
  if [[ -n "$svc" ]]; then
    dns="$(networksetup -getdnsservers "$svc" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    case "$dns" in
      There*) dns="" ;;
    esac
  fi
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # Always single-quote values so spaces (DNS / iface lists) never break parsing.
  cat > "$STATE_FILE" <<EOF
BEFORE_DEFAULT_GW='${gw}'
BEFORE_DEFAULT_IF='${ifc}'
BEFORE_IFACES='${ifaces}'
BEFORE_DNS_SERVICE='${svc}'
BEFORE_DNS='${dns}'
SAVED_AT='${stamp}'
EOF
  if [[ -n "${SUDO_USER:-}" ]]; then
    chown "${SUDO_USER}" "$STATE_FILE" 2>/dev/null || true
  fi
  log "saved pre-VPN state → $STATE_FILE"
  log "  LAN default $gw via $ifc | DNS($svc)=${dns:-dhcp}"
}

ensure_state() {
  if [[ -f "$STATE_FILE" ]] && grep -q "^BEFORE_DEFAULT_GW='" "$STATE_FILE" 2>/dev/null; then
    load_state
    [[ -n "$BEFORE_DEFAULT_GW" ]] && return 0
  fi
  if [[ -f "$STATE_FILE" ]]; then
    log "replacing broken/legacy state file"
  else
    log "no prior capture — auto-saving current LAN default"
  fi
  save_before_state
  load_state
}

# --- route ops --------------------------------------------------------------

delete_full_tunnel_hijack() {
  local vpn_gw="$1"
  local vpn_if="$2"

  if [[ -n "$vpn_gw" ]]; then
    route -n delete -net 0.0.0.0/1 "$vpn_gw" >/dev/null 2>&1 || true
    route -n delete -net 128.0.0.0/1 "$vpn_gw" >/dev/null 2>&1 || true
  fi
  if [[ -n "$vpn_if" ]]; then
    route -n delete -net 0.0.0.0/1 -interface "$vpn_if" >/dev/null 2>&1 || true
    route -n delete -net 128.0.0.0/1 -interface "$vpn_if" >/dev/null 2>&1 || true
    # Only remove VPN-scoped default — never the LAN default on en*
    route -n delete default -ifscope "$vpn_if" >/dev/null 2>&1 || true
  fi
  route -n delete -net 0.0.0.0/1 >/dev/null 2>&1 || true
  route -n delete -net 128.0.0.0/1 >/dev/null 2>&1 || true
  log "removed full-tunnel hijack (0/1 + 128.0/1)"
}

restore_lan_default() {
  load_state
  local gw="${BEFORE_DEFAULT_GW:-}"
  gw="${gw:-$(lan_default_gateway || true)}"
  [[ -n "$gw" ]] || die "cannot find LAN gateway"
  if ! netstat -rn -f inet | awk -v g="$gw" '$1=="default" && $2==g && $4 ~ /^en/ { found=1 } END{ exit !found }'; then
    route -n add default "$gw" 2>/dev/null || route -n change default "$gw" 2>/dev/null || true
    log "ensured LAN default → $gw"
  else
    log "LAN default OK → $gw"
  fi
}

restore_lan_dns() {
  load_state
  local svc="${BEFORE_DNS_SERVICE:-}"
  local dns="${BEFORE_DNS:-}"
  [[ -n "$svc" ]] || svc="$(primary_network_service "$(lan_default_interface || echo en0)" || true)"
  [[ -n "$svc" ]] || return 0

  local cleaned="" ip
  for ip in $dns; do
    case "$ip" in
      There|aren\'t|any|DNS|Servers|set|on*) continue ;;
      172.16.*) continue ;;
      *) cleaned="$cleaned $ip" ;;
    esac
  done
  cleaned="$(echo "$cleaned" | xargs 2>/dev/null || true)"

  if [[ -z "$cleaned" ]]; then
    networksetup -setdnsservers "$svc" Empty 2>/dev/null || true
    log "DNS on $svc → DHCP/Empty"
  else
    # shellcheck disable=SC2086
    networksetup -setdnsservers "$svc" $cleaned 2>/dev/null || true
    log "DNS on $svc → $cleaned"
  fi
}

add_split_routes() {
  local vpn_gw="$1"
  local vpn_if="$2"
  local t
  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    if [[ "$t" == */* ]]; then
      route -n delete -net "$t" >/dev/null 2>&1 || true
      # Prefer gateway (Kerio pattern); fall back to -interface
      if route -n add -net "$t" "$vpn_gw" >/dev/null 2>&1; then
        log "VPN route net $t → $vpn_gw"
      elif route -n add -net "$t" -interface "$vpn_if" >/dev/null 2>&1; then
        log "VPN route net $t → iface $vpn_if"
      else
        die "failed to add net route $t"
      fi
    else
      route -n delete -host "$t" >/dev/null 2>&1 || true
      if route -n add -host "$t" "$vpn_gw" >/dev/null 2>&1; then
        log "VPN route host $t → $vpn_gw"
      elif route -n add -host "$t" -interface "$vpn_if" >/dev/null 2>&1; then
        log "VPN route host $t → iface $vpn_if"
      else
        die "failed to add host route $t"
      fi
    fi
  done < <(read_targets)
}

remove_split_routes() {
  local t
  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    if [[ "$t" == */* ]]; then
      route -n delete -net "$t" 2>/dev/null || true
    else
      route -n delete -host "$t" 2>/dev/null || true
    fi
    log "removed $t"
  done < <(read_targets)
}

verify_split() {
  local sample probe hijack
  sample="$(read_targets | head -1 || true)"
  probe="192.168.70.194"
  hijack="$(netstat -rn -f inet | awk '$1=="0/1"{print "YES"; exit}')"
  echo
  echo "---- verify ----"
  echo -n "route to 1.1.1.1 iface: "
  route -n get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2}'
  echo "route to $probe:"
  route -n get "$probe" 2>/dev/null | awk '/gateway:|interface:/{print "  " $0}'
  if [[ -n "$sample" ]]; then
    echo "targets head: $sample"
  fi
  echo "0/1 hijack present: ${hijack:-no}"
}

# --- commands ---------------------------------------------------------------

cmd_capture() { save_before_state; }

cmd_status() {
  echo "targets_file: $TARGETS_FILE"
  echo "state_file:   $STATE_FILE"
  [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" || echo "(no saved state)"
  echo
  echo "LAN default: $(lan_default_gateway || echo ?) via $(lan_default_interface || echo ?)"
  echo "VPN 0/1 gw:  $(vpn_fulltunnel_gateway || echo none) if=$(vpn_fulltunnel_interface || echo none)"
  echo "VPN detect:  if=$(detect_vpn_interface || echo none) gw=$(detect_vpn_gateway || echo none)"
  echo "targets:"
  read_targets | sed 's/^/  /' || true
  echo
  netstat -rn -f inet | head -35
}

cmd_apply() {
  need_root
  ensure_state
  load_state

  local vpn_if vpn_gw stamp
  vpn_if="$(detect_vpn_interface || true)"
  vpn_gw="$(detect_vpn_gateway || true)"
  [[ -n "$vpn_if" ]] || die "Kerio VPN interface not found — connect Kerio first"
  [[ -n "$vpn_gw" ]] || die "Kerio VPN gateway not found"
  log "Kerio iface=$vpn_if gateway=$vpn_gw"

  delete_full_tunnel_hijack "$vpn_gw" "$vpn_if"
  restore_lan_default
  restore_lan_dns
  add_split_routes "$vpn_gw" "$vpn_if"

  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  grep -E "^BEFORE_|^SAVED_AT=" "$STATE_FILE" > "${STATE_FILE}.tmp" || true
  cat >> "${STATE_FILE}.tmp" <<EOF
VPN_IF='${vpn_if}'
VPN_GW='${vpn_gw}'
APPLIED_AT='${stamp}'
EOF
  mv "${STATE_FILE}.tmp" "$STATE_FILE"

  log "split tunnel ON — only targets.txt via Kerio; rest via LAN"
  verify_split
}

cmd_restore() {
  need_root
  remove_split_routes || true
  load_state
  if [[ -n "${BEFORE_DEFAULT_GW:-}" ]]; then
    route -n add default "$BEFORE_DEFAULT_GW" 2>/dev/null || true
  fi
  log "split routes removed (Kerio connection itself unchanged)"
}

usage() {
  cat <<EOF
Usage: sudo $0 <capture|apply|restore|status>
EOF
}

main() {
  case "${1:-}" in
    capture) cmd_capture ;;
    apply) cmd_apply ;;
    restore) cmd_restore ;;
    status) cmd_status ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
