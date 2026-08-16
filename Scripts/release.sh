#!/bin/bash
# Build KerioSplit.app and optionally a DMG under ./dist
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
STAGE="$DIST/stage"
APP="$STAGE/KerioSplit.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
BUNDLE="$RES/KerioSplitBundle"
DMG="$DIST/KerioSplit-Mehrad.dmg"
SDK="$(xcrun --show-sdk-path)"
TARGET="arm64-apple-macosx13.0"
APP_ONLY=0

if [[ "${1:-}" == "--app-only" ]]; then
  APP_ONLY=1
fi

rm -rf "$STAGE"
mkdir -p "$MACOS" "$RES" "$BUNDLE/Scripts" "$BUNDLE/Config" "$BUNDLE/Assets"

cp "$ROOT/KerioSplit/Assets.xcassets/MehradLogo.imageset/tom.h@example.org" "$RES/MehradLogo.png"
cp "$ROOT/KerioSplit/Assets.xcassets/MehradLogo.imageset/tom.h@example.org" "$BUNDLE/Assets/MehradLogo.png"
cp "$ROOT/KerioSplit/Assets.xcassets/AppIcon.appiconset/icon_512.png" "$RES/AppIcon.png" 2>/dev/null || true
cp "$ROOT/Scripts/split-tunnel.sh" "$BUNDLE/Scripts/"
cp "$ROOT/Scripts/keriosplit-ctl" "$BUNDLE/Scripts/"
cp "$ROOT/Scripts/install-helper.sh" "$BUNDLE/Scripts/"
cp "$ROOT/Config/targets.txt" "$BUNDLE/Config/"
cp "$ROOT/Config/config.example.json" "$BUNDLE/Config/"
chmod +x "$BUNDLE/Scripts/"*.sh "$BUNDLE/Scripts/keriosplit-ctl"

if command -v sips >/dev/null && command -v iconutil >/dev/null; then
  ICONSET="$STAGE/AppIcon.iconset"
  mkdir -p "$ICONSET"
  SRC="$ROOT/KerioSplit/Assets.xcassets/AppIcon.appiconset/icon_1024.png"
  if [[ -f "$SRC" ]]; then
    for s in 16 32 128 256 512; do
      sips -z "$s" "$s" "$SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null 2>&1 || true
      sips -z $((s * 2)) $((s * 2)) "$SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null 2>&1 || true
    done
    iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns" 2>/dev/null || true
  fi
  rm -rf "$ICONSET"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>Kerio Split</string>
	<key>CFBundleExecutable</key>
	<string>KerioSplit</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>ir.mehrad.KerioSplit</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Kerio Split</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.5.1</string>
	<key>CFBundleVersion</key>
	<string>51</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSAppleEventsUsageDescription</key>
	<string>Kerio Split needs administrator privileges to update network routes.</string>
	<key>NSHumanReadableCopyright</key>
	<string>Copyright © Mehrad Technical Team</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "Compiling…"
swiftc -parse-as-library \
  "$ROOT/KerioSplit/KerioSplitApp.swift" \
  "$ROOT/KerioSplit/ContentView.swift" \
  "$ROOT/KerioSplit/OverviewDashboard.swift" \
  "$ROOT/KerioSplit/MenuBarContent.swift" \
  "$ROOT/KerioSplit/ResourceMonitor.swift" \
  "$ROOT/KerioSplit/TunnelController.swift" \
  "$ROOT/KerioSplit/Brand.swift" \
  "$ROOT/KerioSplit/AppConfig.swift" \
  "$ROOT/KerioSplit/HelperService.swift" \
  "$ROOT/KerioSplit/UIComponents.swift" \
  -o "$MACOS/KerioSplit" \
  -sdk "$SDK" \
  -target "$TARGET" \
  -framework SwiftUI \
  -framework AppKit \
  -framework Foundation \
  -framework ServiceManagement \
  -framework UserNotifications \
  -O

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
xattr -cr "$APP" >/dev/null 2>&1 || true

rm -rf "$DIST/KerioSplit.app"
cp -R "$APP" "$DIST/KerioSplit.app"
echo "App: $DIST/KerioSplit.app"

if [[ "$APP_ONLY" -eq 1 ]]; then
  exit 0
fi

# DMG layout: app + Applications symlink (installer convention)
ln -sfn /Applications "$STAGE/Applications"
cat > "$STAGE/README.txt" <<'TXT'
Kerio Split
Mehrad Technical Team

1. Drag KerioSplit onto Applications
2. Eject this volume
3. Open KerioSplit from Launchpad / Applications
4. First open may require: right-click → Open
TXT

rm -f "$DMG" "$DIST/rw.dmg"
hdiutil create -volname "Kerio Split" -srcfolder "$STAGE" -ov -format UDRW "$DIST/rw.dmg"
hdiutil convert "$DIST/rw.dmg" -format UDZO -o "$DMG"
rm -f "$DIST/rw.dmg"
xattr -cr "$DMG" >/dev/null 2>&1 || true
echo "DMG: $DMG"
