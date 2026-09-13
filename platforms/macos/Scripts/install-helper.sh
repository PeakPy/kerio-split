#!/bin/bash
# One-time privileged helper install.
# After this, the app runs: sudo -n /usr/local/libexec/keriosplit-ctl …
# without a password prompt.
#
# Must be invoked as root. The macOS user MUST be passed as INSTALL_USER
# because AppleScript "with administrator privileges" does not set SUDO_USER
# (Apple TN2065). Guessing $USER here can write sudoers for root, which
# leaves the real user prompting forever.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PLATFORM="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"

USER_NAME="${INSTALL_USER:-${SUDO_USER:-}}"
if [[ -z "$USER_NAME" || "$USER_NAME" == "root" ]]; then
  echo "install-helper: INSTALL_USER must be the macOS login name (not root)" >&2
  echo "  INSTALL_USER='${INSTALL_USER:-}' SUDO_USER='${SUDO_USER:-}' USER='${USER:-}'" >&2
  exit 1
fi
if [[ ! "$USER_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "install-helper: refusing unsafe username: $USER_NAME" >&2
  exit 1
fi

[[ "$(id -u)" -eq 0 ]] || { echo "run as root"; exit 1; }

REAL_HOME="$(dscl . -read "/Users/${USER_NAME}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
if [[ -z "$REAL_HOME" || ! -d "$REAL_HOME" ]]; then
  REAL_HOME="$(eval echo "~${USER_NAME}")"
fi
if [[ -z "$REAL_HOME" || ! -d "$REAL_HOME" ]]; then
  echo "install-helper: cannot resolve home for ${USER_NAME}" >&2
  exit 1
fi

SUPPORT="${REAL_HOME}/Library/Application Support/KerioSplit"
LIBEXEC="/usr/local/libexec"
CTL="$LIBEXEC/keriosplit-ctl"
SUDOERS="/etc/sudoers.d/keriosplit"

SRC_CTL="$HERE/keriosplit-ctl"
SRC_ENGINE="$HERE/split-tunnel.sh"
[[ -x "$SRC_CTL" ]] || SRC_CTL="$PLATFORM/Scripts/keriosplit-ctl"
[[ -x "$SRC_ENGINE" ]] || SRC_ENGINE="$PLATFORM/Scripts/split-tunnel.sh"
[[ -x "$SRC_CTL" ]] || { echo "missing keriosplit-ctl next to installer"; exit 1; }
[[ -x "$SRC_ENGINE" ]] || { echo "missing split-tunnel.sh next to installer"; exit 1; }

mkdir -p "$SUPPORT/Scripts" "$SUPPORT/Config" "$LIBEXEC"

DEST_ENGINE="$SUPPORT/Scripts/split-tunnel.sh"
if [[ "$SRC_ENGINE" != "$DEST_ENGINE" ]]; then
  cp "$SRC_ENGINE" "$DEST_ENGINE"
  chmod 755 "$DEST_ENGINE"
fi

cp "$SRC_CTL" "$CTL"
chmod 755 "$CTL"
chown root:wheel "$CTL"
chown -R "${USER_NAME}:staff" "$SUPPORT"

if [[ ! -f "$SUPPORT/Config/config.json" ]]; then
  for example in \
    "$HERE/../Config/config.example.json" \
    "$REPO/config/config.example.json" \
    "$SUPPORT/Config/config.example.json"
  do
    if [[ -f "$example" ]]; then
      cp "$example" "$SUPPORT/Config/config.json"
      break
    fi
  done
  [[ -f "$SUPPORT/Config/config.json" ]] && chown "${USER_NAME}:staff" "$SUPPORT/Config/config.json"
fi

TMP_SUDOERS="$(mktemp /tmp/keriosplit-sudoers.XXXXXX)"
cat > "$TMP_SUDOERS" <<EOF
# Kerio Split — Ehsan Akbari
# Narrow NOPASSWD: only this binary, only this user.
# Filename has no '.' so sudo's includedir will actually read it.
${USER_NAME} ALL=(root) NOPASSWD: ${CTL}
EOF
chmod 440 "$TMP_SUDOERS"
chown root:wheel "$TMP_SUDOERS"
visudo -cf "$TMP_SUDOERS"
cp "$TMP_SUDOERS" "$SUDOERS"
chmod 440 "$SUDOERS"
chown root:wheel "$SUDOERS"
rm -f "$TMP_SUDOERS"
visudo -cf "$SUDOERS"

echo "Helper installed for ${USER_NAME}"
echo "  ctl:     $CTL"
echo "  sudoers: $SUDOERS"
echo "  support: $SUPPORT"
echo "  home:    $REAL_HOME"

echo "Verifying passwordless sudo…"
VERIFY_OUT="$(mktemp /tmp/keriosplit-verify.XXXXXX)"
if sudo -u "$USER_NAME" /usr/bin/sudo -n "$CTL" ping >"$VERIFY_OUT" 2>&1; then
  echo "Passwordless sudo OK"
  cat "$VERIFY_OUT"
  rm -f "$VERIFY_OUT"
else
  echo "Passwordless sudo FAILED for ${USER_NAME}:" >&2
  cat "$VERIFY_OUT" >&2
  rm -f "$VERIFY_OUT"
  exit 1
fi
