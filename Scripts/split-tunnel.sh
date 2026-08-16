#!/bin/bash
# Kerio Control split-tunnel engine for macOS.
# Reads config JSON (vpn routes, bypass routes, options).
#
# Usage: sudo ./Scripts/split-tunnel.sh capture|apply|restore|status
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REAL_HOME="${SUDO_USER:+$(eval echo "~${SUDO_USER}")}"
REAL_HOME="${REAL_HOME:-$HOME}"
SUPPORT="${REAL_HOME}/Library/Application Support/KerioSplit"
STATE_DIR="$SUPPORT"
FALLBACK="${REAL_HOME}/.kerio-split"

if [[ "$(id -u)" -eq 0 && -n "${SUDO_USER:-}" ]]; then
  mkdir -p "$SUPPORT/Config" "$SUPPORT/Scripts" 2>/dev/null || true
  chown -R "${SUDO_USER}:staff" "$SUPPORT" 2>/dev/null || true
  chmod -R u+rwX "$SUPPORT" 2>/dev/null || true
fi

if [[ ! -d "$STATE_DIR" ]] || { [[ "$(id -u)" -ne 0 ]] && [[ ! -w "$STATE_DIR" ]]; }; then
  STATE_DIR="$FALLBACK"
fi
mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/saved-routes.env"

CONFIG_FILE="${KERIOSPLIT_CONFIG:-}"
if [[ -z "$CONFIG_FILE" ]]; then
  for c in \
    "$SUPPORT/Config/config.json" \
    "$FALLBACK/Config/config.json" \
    "$ROOT/Config/config.json" \
    "$ROOT/Config/config.example.json"
  do
    if [[ -f "$c" ]]; then CONFIG_FILE="$c"; break; fi
  done
fi

# Legacy targets.txt still supported if no JSON
TARGETS_TXT="$SUPPORT/Config/targets.txt"
[[ -f "$TARGETS_TXT" ]] || TARGETS_TXT="$ROOT/Config/targets.txt"

log() { echo "[KerioSplit] $*"; }
die() { echo "[KerioSplit] ERROR: $*" >&2; exit 1; }
need_root() { [[ "$(id -u)" -eq 0 ]] || die "run with sudo"; }

json_list() {
  local key="$1"
  /usr/bin/python3 - "$CONFIG_FILE" "$key" <<'PY' 2>/dev/null || true
import json, sys
path, key = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    sys.exit(0)
items = data.get(key) or []
for item in items:
    s = str(item).strip()
    if s and not s.startswith("#"):
        print(s)
PY
}

json_opt_bool() {
  local key="$1" default="${2:-true}"
  /usr/bin/python3 - "$CONFIG_FILE" "$key" "$default" <<'PY' 2>/dev/null || echo "$default"
import json, sys
path, key, default = sys.argv[1], sys.argv[2], sys.argv[3].lower() == "true"
try:
    with open(path) as f:
        data = json.load(f)
    opts = data.get("options") or {}
    val = opts.get(key, default)
    print("true" if val else "false")
except Exception:
    print("true" if default else "false")
PY
}

json_dns() {
  /usr/bin/python3 - "$CONFIG_FILE" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    for d in (data.get("options") or {}).get("customDns") or []:
        print(str(d).strip())
except Exception:
    pass
PY
}

is_cidr_or_ip() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]
}

read_vpn_routes() {
  if [[ -n "${CONFIG_FILE:-}" && -f "$CONFIG_FILE" ]]; then
    local list
    list="$(json_list vpnRoutes)"
    if [[ -n "$list" ]]; then
      printf '%s\n' "$list"
      return 0
    fi
  fi
  # Legacy fallback
  if [[ -f "$TARGETS_TXT" ]]; then
    awk '/^[[:space:]]*#/ {next} /^[[:space:]]*$/ {next} { if ($1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/) print $1 }' "$TARGETS_TXT"
  fi
}

read_bypass_routes() {
  [[ -n "${CONFIG_FILE:-}" && -f "$CONFIG_FILE" ]] || return 0
  json_list bypassRoutes
}

lan_default_gateway() {
  netstat -rn -f inet 2>/dev/null | awk '$1=="default" && $4 ~ /^en[0-9]+$/ { print $2; exit }'
}
lan_default_interface() {
  netstat -rn -f inet 2>/dev/null | awk '$1=="default" && $4 ~ /^en[0-9]+$/ { print $4; exit }'
}
vpn_fulltunnel_gateway() {
  netstat -rn -f inet 2>/dev/null | awk '$1=="0/1" { print $2; exit }'
}
vpn_fulltunnel_interface() {
  netstat -rn -f inet 2>/dev/null | awk '$1=="0/1" { print $NF; exit }'
}

BEFORE_DEFAULT_GW=""; BEFORE_DEFAULT_IF=""; BEFORE_IFACES=""
BEFORE_DNS_SERVICE=""; BEFORE_DNS=""; VPN_IF=""; VPN_GW=""

state_get() {
  local key="$1" line val
  [[ -f "$STATE_FILE" ]] || return 0
  line="$(grep -E "^${key}=" "$STATE_FILE" 2>/dev/null | tail -1 || true)"
  [[ -n "$line" ]] || return 0
  val="${line#*=}"
  if [[ "$val" == \'*\' ]]; then val="${val:1:${#val}-2}"
  elif [[ "$val" == \"*\" ]]; then val="${val:1:${#val}-2}"; fi
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

primary_network_service() {
  local ifc="$1"
  networksetup -listallhardwareports 2>/dev/null | awk -v dev="$ifc" '
    /^Hardware Port:/ { port=$0; sub(/^Hardware Port: /,"",port) }
    /^Device:/ && $2==dev { print port; exit }
  '
}

detect_vpn_interface() {
  local from_route ifc inet
  from_route="$(vpn_fulltunnel_interface || true)"
  [[ -n "$from_route" ]] && { echo "$from_route"; return 0; }
  load_state
  for ifc in $(ifconfig -l); do
    case "$ifc" in utun*|kvnet*|kerio*) ;; *) continue ;; esac
    inet="$(ifconfig "$ifc" 2>/dev/null | awk '/inet /{print $2; exit}')"
    [[ -n "$inet" ]] || continue
    if [[ -n "${BEFORE_IFACES:-}" && " ${BEFORE_IFACES} " != *" $ifc "* ]]; then
      echo "$ifc"; return 0
    fi
  done
  for ifc in $(ifconfig -l); do
    case "$ifc" in utun*) ;; *) continue ;; esac
    if ifconfig "$ifc" 2>/dev/null | grep -q 'inet '; then echo "$ifc"; return 0; fi
  done
  return 1
}

detect_vpn_gateway() {
  local gw ifc inet
  gw="$(vpn_fulltunnel_gateway || true)"
  [[ -n "$gw" ]] && { echo "$gw"; return 0; }
  ifc="$(detect_vpn_interface || true)"
  [[ -n "$ifc" ]] || return 1
  inet="$(ifconfig "$ifc" 2>/dev/null | awk '/inet /{print $2; exit}')"
  [[ -n "$inet" ]] || return 1
  echo "${inet%.*}.1"
}

save_before_state() {
  local gw ifc ifaces dns svc stamp
  gw="$(lan_default_gateway || true)"
  ifc="$(lan_default_interface || true)"
  ifaces="$(ifconfig -l)"
  svc="$(primary_network_service "${ifc:-en0}" || true)"
  dns=""
  if [[ -n "$svc" ]]; then
    dns="$(networksetup -getdnsservers "$svc" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    case "$dns" in There*) dns="" ;; esac
  fi
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cat > "$STATE_FILE" <<EOF
BEFORE_DEFAULT_GW='${gw}'
BEFORE_DEFAULT_IF='${ifc}'
BEFORE_IFACES='${ifaces}'
BEFORE_DNS_SERVICE='${svc}'
BEFORE_DNS='${dns}'
SAVED_AT='${stamp}'
EOF
  [[ -n "${SUDO_USER:-}" ]] && chown "${SUDO_USER}" "$STATE_FILE" 2>/dev/null || true
  log "saved LAN state gw=$gw if=$ifc"
}

ensure_state() {
  if [[ -f "$STATE_FILE" ]] && grep -q "^BEFORE_DEFAULT_GW='" "$STATE_FILE" 2>/dev/null; then
    load_state
    [[ -n "$BEFORE_DEFAULT_GW" ]] && return 0
  fi
  save_before_state
  load_state
}

delete_full_tunnel_hijack() {
  local vpn_gw="$1" vpn_if="$2"
  [[ -n "$vpn_gw" ]] && {
    route -n delete -net 0.0.0.0/1 "$vpn_gw" >/dev/null 2>&1 || true
    route -n delete -net 128.0.0.0/1 "$vpn_gw" >/dev/null 2>&1 || true
  }
  [[ -n "$vpn_if" ]] && {
    route -n delete -net 0.0.0.0/1 -interface "$vpn_if" >/dev/null 2>&1 || true
    route -n delete -net 128.0.0.0/1 -interface "$vpn_if" >/dev/null 2>&1 || true
    route -n delete default -ifscope "$vpn_if" >/dev/null 2>&1 || true
  }
  route -n delete -net 0.0.0.0/1 >/dev/null 2>&1 || true
  route -n delete -net 128.0.0.0/1 >/dev/null 2>&1 || true
  log "removed full-tunnel hijack"
}

restore_lan_default() {
  load_state
  local gw="${BEFORE_DEFAULT_GW:-}"
  gw="${gw:-$(lan_default_gateway || true)}"
  [[ -n "$gw" ]] || die "cannot find LAN gateway"
  if ! netstat -rn -f inet | awk -v g="$gw" '$1=="default" && $2==g && $4 ~ /^en/ { found=1 } END{ exit !found }'; then
    route -n add default "$gw" 2>/dev/null || route -n change default "$gw" 2>/dev/null || true
    log "LAN default → $gw"
  else
    log "LAN default OK → $gw"
  fi
}

apply_dns() {
  load_state
  local svc="${BEFORE_DNS_SERVICE:-}"
  [[ -n "$svc" ]] || svc="$(primary_network_service "$(lan_default_interface || echo en0)" || true)"
  [[ -n "$svc" ]] || return 0

  local custom
  custom="$(json_dns | tr '\n' ' ' | xargs 2>/dev/null || true)"
  if [[ -n "$custom" ]]; then
    # shellcheck disable=SC2086
    networksetup -setdnsservers "$svc" $custom 2>/dev/null || true
    log "DNS on $svc → $custom"
    return 0
  fi

  local dns="${BEFORE_DNS:-}" cleaned="" ip
  for ip in $dns; do
    case "$ip" in
      There|aren\'t|any|DNS|Servers|set|on*|172.16.*) continue ;;
      *) cleaned="$cleaned $ip" ;;
    esac
  done
  cleaned="$(echo "$cleaned" | xargs 2>/dev/null || true)"
  if [[ -z "$cleaned" ]]; then
    networksetup -setdnsservers "$svc" Empty 2>/dev/null || true
    log "DNS on $svc → DHCP"
  else
    # shellcheck disable=SC2086
    networksetup -setdnsservers "$svc" $cleaned 2>/dev/null || true
    log "DNS on $svc → $cleaned"
  fi
}

add_route_list() {
  local mode="$1" gw="$2" ifc="$3"  # mode: vpn|bypass
  local t lan_gw
  lan_gw="$(lan_default_gateway || true)"
  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    is_cidr_or_ip "$t" || { log "skip invalid: $t"; continue; }
    if [[ "$t" == */* ]]; then
      route -n delete -net "$t" >/dev/null 2>&1 || true
      if [[ "$mode" == vpn ]]; then
        route -n add -net "$t" "$gw" >/dev/null 2>&1 || route -n add -net "$t" -interface "$ifc" >/dev/null 2>&1 || die "failed net $t"
        log "VPN  $t"
      else
        [[ -n "$lan_gw" ]] || die "no LAN gateway for bypass"
        route -n add -net "$t" "$lan_gw" >/dev/null 2>&1 || die "failed bypass net $t"
        log "BYPASS $t → $lan_gw"
      fi
    else
      route -n delete -host "$t" >/dev/null 2>&1 || true
      if [[ "$mode" == vpn ]]; then
        route -n add -host "$t" "$gw" >/dev/null 2>&1 || route -n add -host "$t" -interface "$ifc" >/dev/null 2>&1 || die "failed host $t"
        log "VPN  $t"
      else
        [[ -n "$lan_gw" ]] || die "no LAN gateway for bypass"
        route -n add -host "$t" "$lan_gw" >/dev/null 2>&1 || die "failed bypass host $t"
        log "BYPASS $t → $lan_gw"
      fi
    fi
  done
}

remove_route_list() {
  local t
  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    if [[ "$t" == */* ]]; then
      route -n delete -net "$t" >/dev/null 2>&1 || true
    else
      route -n delete -host "$t" >/dev/null 2>&1 || true
    fi
    log "removed $t"
  done
}

cmd_capture() { save_before_state; }

cmd_status() {
  echo "config: $CONFIG_FILE"
  echo "state:  $STATE_FILE"
  echo "LAN:    $(lan_default_gateway || echo ?) via $(lan_default_interface || echo ?)"
  echo "VPN:    if=$(detect_vpn_interface || echo none) gw=$(detect_vpn_gateway || echo none)"
  echo "hijack: $(vpn_fulltunnel_gateway >/dev/null && echo yes || echo no)"
  echo "vpnRoutes:"
  read_vpn_routes | sed 's/^/  /' || true
  echo "bypassRoutes:"
  read_bypass_routes | sed 's/^/  /' || true
  echo
  netstat -rn -f inet | head -40
}

cmd_apply() {
  need_root
  ensure_state
  load_state

  local vpn_if vpn_gw
  vpn_if="$(detect_vpn_interface || true)"
  vpn_gw="$(detect_vpn_gateway || true)"
  [[ -n "$vpn_if" ]] || die "Kerio VPN interface not found — connect Kerio first"
  [[ -n "$vpn_gw" ]] || die "Kerio VPN gateway not found"
  log "iface=$vpn_if gateway=$vpn_gw config=$CONFIG_FILE"

  if [[ "$(json_opt_bool removeFullTunnel true)" == "true" ]]; then
    delete_full_tunnel_hijack "$vpn_gw" "$vpn_if"
  fi
  if [[ "$(json_opt_bool restoreLanDefault true)" == "true" ]]; then
    restore_lan_default
  fi
  if [[ "$(json_opt_bool restoreLanDns true)" == "true" ]]; then
    apply_dns
  fi

  # Clear previous managed routes then re-add
  remove_route_list < <(read_vpn_routes; read_bypass_routes) || true
  add_route_list vpn "$vpn_gw" "$vpn_if" < <(read_vpn_routes)
  add_route_list bypass "$vpn_gw" "$vpn_if" < <(read_bypass_routes)

  local stamp
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  grep -E "^BEFORE_|^SAVED_AT=" "$STATE_FILE" > "${STATE_FILE}.tmp" || true
  {
    echo "VPN_IF='${vpn_if}'"
    echo "VPN_GW='${vpn_gw}'"
    echo "APPLIED_AT='${stamp}'"
    echo "CONFIG_FILE='${CONFIG_FILE}'"
  } >> "${STATE_FILE}.tmp"
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
  [[ -n "${SUDO_USER:-}" ]] && chown "${SUDO_USER}" "$STATE_FILE" 2>/dev/null || true

  log "split tunnel applied"
  echo "---- verify ----"
  echo -n "1.1.1.1 → "; route -n get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2}'
  echo "hijack 0/1: $(netstat -rn -f inet | awk '$1=="0/1"{print "yes"; exit} END{if(!found){}}')"
  netstat -rn -f inet | awk '$1=="0/1"{print "yes"; found=1} END{if(!found) print "no"}'
}

cmd_restore() {
  need_root
  remove_route_list < <(read_vpn_routes; read_bypass_routes) || true
  load_state
  if [[ -n "${BEFORE_DEFAULT_GW:-}" ]]; then
    route -n add default "$BEFORE_DEFAULT_GW" 2>/dev/null || true
  fi
  log "managed routes removed"
}

main() {
  case "${1:-}" in
    capture) cmd_capture ;;
    apply) cmd_apply ;;
    restore) cmd_restore ;;
    status) cmd_status ;;
    *) echo "Usage: sudo $0 capture|apply|restore|status"; exit 1 ;;
  esac
}

main "$@"
