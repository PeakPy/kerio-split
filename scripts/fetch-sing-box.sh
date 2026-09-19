#!/usr/bin/env bash
# Download sing-box into Application Support for Kerio Split built-in outbound.
set -euo pipefail

VERSION="${SINGBOX_VERSION:-1.11.15}"
SUPPORT="${HOME}/Library/Application Support/KerioSplit/Helpers"
mkdir -p "$SUPPORT"

ARCH="$(uname -m)"
case "$ARCH" in
  arm64|aarch64) REMOTE_ARCH="darwin-arm64" ;;
  x86_64) REMOTE_ARCH="darwin-amd64" ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-${REMOTE_ARCH}.tar.gz"
echo "Fetching $URL"
curl -fsSL "$URL" -o "$TMP/sing-box.tgz"
tar -xzf "$TMP/sing-box.tgz" -C "$TMP"
BIN="$(find "$TMP" -type f -name sing-box | head -1)"
[[ -n "$BIN" ]] || { echo "sing-box binary missing from archive" >&2; exit 1; }
cp "$BIN" "$SUPPORT/sing-box"
chmod +x "$SUPPORT/sing-box"
xattr -cr "$SUPPORT/sing-box" 2>/dev/null || true
echo "Installed: $SUPPORT/sing-box"
"$SUPPORT/sing-box" version || true
