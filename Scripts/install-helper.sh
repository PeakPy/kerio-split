#!/bin/bash
# One-time privileged helper install.
# After this, the app can run: sudo -n /usr/local/libexec/keriosplit-ctl …
# without prompting for a password.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
USER_NAME="${SUDO_USER:-$USER}"
REAL_HOME="$(eval echo "~${USER_NAME}")"
SUPPORT="${REAL_HOME}/Library/Application Support/KerioSplit"
LIBEXEC="/usr/local/libexec"
CTL="$LIBEXEC/keriosplit-ctl"
SUDOERS="/etc/sudoers.d/keriosplit"

[[ "$(id -u)" -eq 0 ]] || { echo "run as root"; exit 1; }

mkdir -p "$SUPPORT/Scripts" "$SUPPORT/Config" "$LIBEXEC"
cp "$ROOT/Scripts/split-tunnel.sh" "$SUPPORT/Scripts/split-tunnel.sh"
cp "$ROOT/Scripts/keriosplit-ctl" "$CTL"
chmod 755 "$SUPPORT/Scripts/split-tunnel.sh" "$CTL"
chown -R "${USER_NAME}:staff" "$SUPPORT"

# Seed config if missing
if [[ ! -f "$SUPPORT/Config/config.json" ]]; then
  if [[ -f "$ROOT/Config/config.example.json" ]]; then
    cp "$ROOT/Config/config.example.json" "$SUPPORT/Config/config.json"
  else
    cat > "$SUPPORT/Config/config.json" <<'JSON'
{"vpnRoutes":["192.168.70.0/24"],"bypassRoutes":[],"options":{"removeFullTunnel":true,"restoreLanDefault":true,"restoreLanDns":true,"customDns":[],"autoApplyOnLaunch":false}}
JSON
  fi
  chown "${USER_NAME}:staff" "$SUPPORT/Config/config.json"
fi

# Also keep a copy of ctl scripts synced from app on later updates via the app itself.
# Restrict sudoers to this single binary for this user only.
cat > "$SUDOERS" <<EOF
# Kerio Split — Mehrad Technical Team
# Allows passwordless execution of the Kerio Split control tool only.
${USER_NAME} ALL=(root) NOPASSWD: ${CTL}
EOF
chmod 440 "$SUDOERS"
visudo -cf "$SUDOERS"

echo "Helper installed for ${USER_NAME}"
echo "  ctl:     $CTL"
echo "  sudoers: $SUDOERS"
echo "  support: $SUPPORT"
echo "Test: sudo -n $CTL status"
