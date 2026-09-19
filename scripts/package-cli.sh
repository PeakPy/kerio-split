#!/usr/bin/env bash
# Build portable CLI archives for Linux and Windows (shared core + OS adapter).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
DIST="${DIST_DIR:-$ROOT/dist}"
TARGET="${1:-all}"

mkdir -p "$DIST"

stage_common() {
  local stage="$1"
  mkdir -p "$stage/lib" "$stage/bin" "$stage/config"
  cp -R "$ROOT/core/keriosplit" "$stage/lib/"
  cp "$ROOT/config/config.example.json" "$stage/config/"
  find "$stage/lib" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
  find "$stage/lib" -type f -name '*.pyc' -delete 2>/dev/null || true
}

write_python_launcher() {
  local path="$1"
  local default_platform="$2"
  cat > "$path" <<EOF
#!/usr/bin/env python3
"""Kerio Split CLI launcher (portable archive)."""
from __future__ import annotations

import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path[:0] = [str(ROOT / "lib")]

os.environ.setdefault("KERIOSPLIT_PLATFORM", "${default_platform}")
if "KERIOSPLIT_CONFIG" not in os.environ:
    example = ROOT / "config" / "config.example.json"
    if example.is_file():
        os.environ["KERIOSPLIT_CONFIG"] = str(example)

from keriosplit.cli import main

raise SystemExit(main())
EOF
  chmod +x "$path"
}

package_linux() {
  local name="keriosplit-${VERSION}-linux"
  local stage="$DIST/${name}"
  rm -rf "$stage" "$DIST/${name}.tar.gz"
  stage_common "$stage"
  cp -R "$ROOT/platforms/linux/keriosplit_linux" "$stage/lib/"
  cp "$ROOT/platforms/linux/README.md" "$stage/README.md"
  write_python_launcher "$stage/bin/keriosplit" "linux"
  cat > "$stage/INSTALL.txt" <<TXT
Kerio Split ${VERSION} — Linux CLI

Requires: Python 3.9+, iproute2 (ip), root for apply/restore.

  export PATH="\$PWD/bin:\$PATH"
  keriosplit ping
  sudo keriosplit apply --config ./config/config.example.json -v
  sudo keriosplit restore
  keriosplit status

Companion for Kerio Control VPN Client — not a Kerio protocol client.
TXT
  tar -C "$DIST" -czf "$DIST/${name}.tar.gz" "$name"
  rm -rf "$stage"
  echo "Linux archive: $DIST/${name}.tar.gz"
}

package_windows() {
  local name="keriosplit-${VERSION}-windows"
  local stage="$DIST/${name}"
  rm -rf "$stage" "$DIST/${name}.zip" "$DIST/${name}.tar.gz"
  stage_common "$stage"
  cp -R "$ROOT/platforms/windows/keriosplit_windows" "$stage/lib/"
  cp "$ROOT/platforms/windows/README.md" "$stage/README.md"
  write_python_launcher "$stage/bin/keriosplit" "windows"
  cat > "$stage/bin/keriosplit.cmd" <<'TXT'
@echo off
setlocal
set "ROOT=%~dp0.."
set "PYTHONPATH=%ROOT%\lib;%PYTHONPATH%"
if not defined KERIOSPLIT_PLATFORM set KERIOSPLIT_PLATFORM=windows
if not defined KERIOSPLIT_CONFIG set KERIOSPLIT_CONFIG=%ROOT%\config\config.example.json
python -m keriosplit %*
TXT
  cat > "$stage/INSTALL.txt" <<TXT
Kerio Split ${VERSION} — Windows CLI (preview)

Route engine is still a stub. Shared config/CLI:

  set PYTHONPATH=%CD%\\lib
  python -m keriosplit ping --platform dry-run

Real apply/restore needs the WinAPI engine on a Windows host/VM.
TXT
  (
    cd "$DIST"
    if command -v zip >/dev/null 2>&1; then
      zip -qr "${name}.zip" "$name"
      echo "Windows archive: $DIST/${name}.zip"
    else
      tar -czf "${name}.tar.gz" "$name"
      echo "Windows archive: $DIST/${name}.tar.gz"
    fi
  )
  rm -rf "$stage"
}

case "$TARGET" in
  linux) package_linux ;;
  windows) package_windows ;;
  all)
    package_linux
    package_windows
    ;;
  *)
    echo "usage: $0 [linux|windows|all]" >&2
    exit 2
    ;;
esac
