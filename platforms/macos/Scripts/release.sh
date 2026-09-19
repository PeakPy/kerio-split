#!/bin/bash
# Build KerioSplit.app and optionally installer packages under ./dist
set -euo pipefail

PLATFORM="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
DIST="${DIST_DIR:-$REPO/dist}"
STAGE="$DIST/stage"
APP="$STAGE/KerioSplit.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
BUNDLE="$RES/KerioSplitBundle"
APP_SRC="$PLATFORM/KerioSplit"
SCRIPTS="$PLATFORM/Scripts"
CONFIG="$REPO/config"
VERSION_FILE="$REPO/VERSION"
PKG_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
# Single public version everywhere (marketing + bundle build).
PKG_BUILD="${PKG_BUILD:-$PKG_VERSION}"
PKG_ID="dev.ehsanakbari.KerioSplit"
UNINSTALL_PKG_ID="dev.ehsanakbari.KerioSplit.uninstall"
INSTALL_PKG="$DIST/KerioSplit.pkg"
UNINSTALL_PKG="$DIST/KerioSplit-Uninstall.pkg"
DMG="$DIST/KerioSplit.dmg"
SDK="$(xcrun --show-sdk-path)"
TARGET="arm64-apple-macosx13.0"
APP_ONLY=0

if [[ "${1:-}" == "--app-only" ]]; then
  APP_ONLY=1
fi

rm -rf "$STAGE"
mkdir -p "$MACOS" "$RES" "$BUNDLE/Scripts" "$BUNDLE/Config" "$BUNDLE/Assets"

cp "$REPO/assets/branding/logo/app-icon-1024.png" "$APP_SRC/Resources/AppLogo.png" 2>/dev/null || true
cp "$REPO/assets/branding/logo/app-mark.png" "$APP_SRC/Resources/AppMark.png" 2>/dev/null || true
cp "$REPO/assets/branding/logo/app-mark-template.png" "$APP_SRC/Resources/AppMarkTemplate.png" 2>/dev/null || true
cp "$APP_SRC/Resources/AppLogo.png" "$RES/AppLogo.png" 2>/dev/null \
  || cp "$APP_SRC/Assets.xcassets/AppIcon.appiconset/icon_512.png" "$RES/AppLogo.png"
cp "$APP_SRC/Resources/AppMark.png" "$RES/AppMark.png" 2>/dev/null || true
cp "$APP_SRC/Resources/AppMarkTemplate.png" "$RES/AppMarkTemplate.png" 2>/dev/null || true
cp "$APP_SRC/Assets.xcassets/AppIcon.appiconset/icon_512.png" "$RES/AppIcon.png" 2>/dev/null || true
cp "$RES/AppLogo.png" "$BUNDLE/Assets/AppLogo.png"
cp "$RES/AppMark.png" "$BUNDLE/Assets/AppMark.png" 2>/dev/null || true
cp "$SCRIPTS/split-tunnel.sh" "$BUNDLE/Scripts/"
cp "$SCRIPTS/keriosplit-ctl" "$BUNDLE/Scripts/"
cp "$SCRIPTS/install-helper.sh" "$BUNDLE/Scripts/"
cp "$CONFIG/targets.txt" "$BUNDLE/Config/"
cp "$CONFIG/config.example.json" "$BUNDLE/Config/"
chmod +x "$BUNDLE/Scripts/"*.sh "$BUNDLE/Scripts/keriosplit-ctl"

if command -v sips >/dev/null && command -v iconutil >/dev/null; then
  ICONSET="$STAGE/AppIcon.iconset"
  mkdir -p "$ICONSET"
  SRC="$APP_SRC/Assets.xcassets/AppIcon.appiconset/icon_1024.png"
  if [[ -f "$SRC" ]]; then
    for s in 16 32 128 256 512; do
      sips -z "$s" "$s" "$SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null 2>&1 || true
      sips -z $((s * 2)) $((s * 2)) "$SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null 2>&1 || true
    done
    iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns" 2>/dev/null || true
  fi
  rm -rf "$ICONSET"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
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
	<string>dev.ehsanakbari.KerioSplit</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Kerio Split</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${PKG_VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${PKG_BUILD}</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSAppleEventsUsageDescription</key>
	<string>Kerio Split uses System Events to click Connect or Disconnect in the official Kerio VPN Client, and asks once for your Mac password to install the route helper.</string>
	<key>NSAccessibilityUsageDescription</key>
	<string>Kerio Split clicks Connect or Disconnect in the official Kerio VPN Client menu extra, then applies or restores split. It does not implement the Kerio VPN protocol.</string>
	<key>NSHumanReadableCopyright</key>
	<string>Copyright © 2026 Kerio Split contributors</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "Compiling…"
swiftc -parse-as-library \
  "$APP_SRC/KerioSplitApp.swift" \
  "$APP_SRC/ContentView.swift" \
  "$APP_SRC/OverviewDashboard.swift" \
  "$APP_SRC/MenuBarContent.swift" \
  "$APP_SRC/ResourceMonitor.swift" \
  "$APP_SRC/TunnelController.swift" \
  "$APP_SRC/KerioLauncher.swift" \
  "$APP_SRC/KerioClientConfig.swift" \
  "$APP_SRC/StandardVPN.swift" \
  "$APP_SRC/Brand.swift" \
  "$APP_SRC/AppConfig.swift" \
  "$APP_SRC/HelperService.swift" \
  "$APP_SRC/UIComponents.swift" \
  -o "$MACOS/KerioSplit" \
  -sdk "$SDK" \
  -target "$TARGET" \
  -framework SwiftUI \
  -framework AppKit \
  -framework Foundation \
  -framework ServiceManagement \
  -framework UserNotifications \
  -framework ApplicationServices \
  -O

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
xattr -cr "$APP" >/dev/null 2>&1 || true

rm -rf "$DIST/KerioSplit.app"
cp -R "$APP" "$DIST/KerioSplit.app"
echo "App: $DIST/KerioSplit.app"

if [[ "$APP_ONLY" -eq 1 ]]; then
  exit 0
fi

# --- .pkg installer (copies KerioSplit.app → /Applications, non-relocatable) ---
PKG_ROOT="$DIST/pkgroot"
PKG_SCRIPTS_INSTALL="$DIST/pkgscripts-install"
PKG_SCRIPTS_UNINSTALL="$DIST/pkgscripts-uninstall"
COMPONENT_PKG="$DIST/KerioSplit-component.pkg"
UNINSTALL_COMPONENT_PKG="$DIST/KerioSplit-uninstall-component.pkg"
COMPONENT_PLIST="$SCRIPTS/pkg/component.plist"

rm -rf "$PKG_ROOT" "$PKG_SCRIPTS_INSTALL" "$PKG_SCRIPTS_UNINSTALL"
mkdir -p "$PKG_ROOT" "$PKG_SCRIPTS_INSTALL" "$PKG_SCRIPTS_UNINSTALL"
# Avoid AppleDouble ._* junk that can confuse Installer’s script runner.
export COPYFILE_DISABLE=1
cp -R "$APP" "$PKG_ROOT/KerioSplit.app"
cp "$SCRIPTS/pkg/install/preinstall" "$PKG_SCRIPTS_INSTALL/preinstall"
cp "$SCRIPTS/pkg/install/postinstall" "$PKG_SCRIPTS_INSTALL/postinstall"
cp "$SCRIPTS/pkg/uninstall/postinstall" "$PKG_SCRIPTS_UNINSTALL/postinstall"
chmod 755 "$PKG_SCRIPTS_INSTALL/preinstall" "$PKG_SCRIPTS_INSTALL/postinstall" "$PKG_SCRIPTS_UNINSTALL/postinstall"
# Drop Finder AppleDouble / quarantine on scripts (Installer is picky).
xattr -cr "$PKG_SCRIPTS_INSTALL" "$PKG_SCRIPTS_UNINSTALL" >/dev/null 2>&1 || true
find "$PKG_SCRIPTS_INSTALL" "$PKG_SCRIPTS_UNINSTALL" -name '._*' -delete 2>/dev/null || true

rm -f "$COMPONENT_PKG" "$UNINSTALL_COMPONENT_PKG" "$INSTALL_PKG" "$UNINSTALL_PKG"
pkgbuild \
  --root "$PKG_ROOT" \
  --component-plist "$COMPONENT_PLIST" \
  --identifier "$PKG_ID" \
  --version "$PKG_VERSION" \
  --install-location /Applications \
  --scripts "$PKG_SCRIPTS_INSTALL" \
  "$COMPONENT_PKG"

# Flat product installer (friendly Installer.app UI)
DIST_RESOURCES="$DIST/pkg-dist-resources"
rm -rf "$DIST_RESOURCES"
mkdir -p "$DIST_RESOURCES"
cp "$SCRIPTS/pkg/welcome.html" "$DIST_RESOURCES/"
cp "$SCRIPTS/pkg/conclusion.html" "$DIST_RESOURCES/"
# distribution.xml references the component by relative name in --package-path
sed "s/version=\"__VERSION__\"/version=\"$PKG_VERSION\"/" \
  "$SCRIPTS/pkg/distribution.xml" > "$DIST/distribution.xml"

productbuild \
  --distribution "$DIST/distribution.xml" \
  --resources "$DIST_RESOURCES" \
  --package-path "$DIST" \
  "$INSTALL_PKG"
rm -f "$COMPONENT_PKG" "$DIST/distribution.xml"
rm -rf "$DIST_RESOURCES"

# Uninstaller product (script-only component + Installer UI)
pkgbuild \
  --nopayload \
  --identifier "$UNINSTALL_PKG_ID" \
  --version "$PKG_VERSION" \
  --scripts "$PKG_SCRIPTS_UNINSTALL" \
  "$UNINSTALL_COMPONENT_PKG"

UNINSTALL_RESOURCES="$DIST/pkg-uninstall-resources"
rm -rf "$UNINSTALL_RESOURCES"
mkdir -p "$UNINSTALL_RESOURCES"
cp "$SCRIPTS/pkg/uninstall-welcome.html" "$UNINSTALL_RESOURCES/welcome.html"
cp "$SCRIPTS/pkg/uninstall-conclusion.html" "$UNINSTALL_RESOURCES/conclusion.html"
sed "s/version=\"__VERSION__\"/version=\"$PKG_VERSION\"/" \
  "$SCRIPTS/pkg/uninstall-distribution.xml" > "$DIST/uninstall-distribution.xml"

productbuild \
  --distribution "$DIST/uninstall-distribution.xml" \
  --resources "$UNINSTALL_RESOURCES" \
  --package-path "$DIST" \
  "$UNINSTALL_PKG"
rm -f "$UNINSTALL_COMPONENT_PKG" "$DIST/uninstall-distribution.xml"
rm -rf "$UNINSTALL_RESOURCES"

xattr -cr "$INSTALL_PKG" "$UNINSTALL_PKG" >/dev/null 2>&1 || true
echo "Installer:   $INSTALL_PKG"
echo "Uninstaller: $UNINSTALL_PKG"

# DMG ships both packages (install + uninstall)
DMG_STAGE="$DIST/dmgstage"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
cp "$INSTALL_PKG" "$DMG_STAGE/Install Kerio Split.pkg"
cp "$UNINSTALL_PKG" "$DMG_STAGE/Uninstall Kerio Split.pkg"
cat > "$DMG_STAGE/README.txt" <<'TXT'
Kerio Split

Install
1. Double-click "Install Kerio Split.pkg"
2. Follow the Installer prompts (admin password)
3. Open Kerio Split from Applications / Launchpad
4. First open may require: right-click → Open
5. Tap Install route helper (one-time Mac password)

Uninstall
1. Double-click "Uninstall Kerio Split.pkg"
2. Enter your Mac password when asked
3. The app, helper, and Kerio Split support files are removed
TXT

rm -f "$DMG" "$DIST/rw.dmg"
hdiutil create -volname "Kerio Split" -srcfolder "$DMG_STAGE" -ov -format UDRW "$DIST/rw.dmg"
hdiutil convert "$DIST/rw.dmg" -format UDZO -o "$DMG"
rm -f "$DIST/rw.dmg"
rm -rf "$PKG_ROOT" "$PKG_SCRIPTS_INSTALL" "$PKG_SCRIPTS_UNINSTALL" "$DMG_STAGE"
xattr -cr "$DMG" >/dev/null 2>&1 || true
echo "DMG: $DMG"
