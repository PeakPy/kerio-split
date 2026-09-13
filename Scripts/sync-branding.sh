#!/bin/bash
# Single master icon → transparent plate + marks + README banners.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
MASTER="$REPO/assets/branding/logo/app-icon-1024.png"
SOURCE="$REPO/assets/branding/logo/app-icon-original.jpg"
APP="$REPO/platforms/macos/KerioSplit"
ICONSET="$APP/Assets.xcassets/AppIcon.appiconset"
MARKSET="$APP/Assets.xcassets/AppMark.imageset"
TMP="/tmp/keriosplit-logo-src.png"

[[ -f "$SOURCE" ]] || { echo "missing locked source logo: $SOURCE" >&2; exit 1; }
sips -s format png "$SOURCE" --out "$TMP" >/dev/null
python3 "$REPO/scripts/clean-logo-alpha.py" "$TMP" "$MASTER"

mkdir -p "$APP/Resources" "$MARKSET"
cp "$MASTER" "$APP/Resources/AppLogo.png"
cp "$MASTER" "$ICONSET/icon_1024.png"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$MASTER" --out "$ICONSET/icon_${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$MASTER" --out "$ICONSET/icon_${s}@2x.png" >/dev/null
done

swift "$REPO/scripts/sync-branding.swift" "$REPO"

cp "$REPO/assets/branding/logo/app-mark.png" "$MARKSET/app-mark.png"
sips -z 512 512 "$REPO/assets/branding/logo/app-mark.png" --out "$MARKSET/app-mark-2x.png" >/dev/null
cp "$REPO/assets/branding/logo/app-mark.png" "$APP/Resources/AppMark.png"
cp "$REPO/assets/branding/logo/app-mark-template.png" "$APP/Resources/AppMarkTemplate.png"

echo "Branding synced"
