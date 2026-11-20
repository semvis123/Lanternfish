#!/bin/zsh
# Builds build/Lanternfish.app (not sandboxed: scanning needs raw sockets and ARP access).
# Signed ad-hoc by default; set CODESIGN_IDENTITY (e.g. "Apple Development: …", see
# `security find-identity -p codesigning -v`) for a stable identity that keeps granted
# privacy permissions across rebuilds.
set -euo pipefail
cd "${0:A:h}/.."

CONFIG="${1:-release}"
# Version shown in About/Finder. Defaults to the latest tag (v1.2.3 -> 1.2.3) and the commit count.
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
SCRATCH="${SCRATCH:-.build/app}"
# DEBUG_HOOKS=1 compiles in the LANTERNFISH_* env hooks (snapshots etc.); off by default in release.
HOOK_FLAGS=()
[[ "${DEBUG_HOOKS:-0}" == 1 ]] && HOOK_FLAGS=(-Xswiftc -DLANTERNFISH_DEBUG_HOOKS)
swift build -c "$CONFIG" --scratch-path "$SCRATCH" --product Lanternfish "${HOOK_FLAGS[@]}"
BIN="$SCRATCH/$CONFIG/Lanternfish"

APP="${APP_OUT:-build/Lanternfish.app}"
rm -rf "$APP"
mkdir -p "$(dirname "$APP")" "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Lanternfish"
cp Sources/LanternfishKit/Resources/oui.tsv "$APP/Contents/Resources/oui.tsv"
# App icon (from scripts/generate-icon.swift): layered Liquid Glass icon + flat .icns fallback.
cp assets/Assets.car assets/AppIcon.icns "$APP/Contents/Resources/"

BONJOUR=$(grep -oE '"_[a-z0-9-]*\._(tcp|udp)"' Sources/LanternfishKit/Names/BonjourScanner.swift | sort -u | tr -d '"' \
  | sed 's|.*|        <string>&</string>|')

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.kriyak.lanternfish</string>
    <key>CFBundleName</key><string>Lanternfish</string>
    <key>CFBundleDisplayName</key><string>Lanternfish</string>
    <key>CFBundleExecutable</key><string>Lanternfish</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>NSAccentColorName</key><string>AccentColor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>27.0</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 Kriyak</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Lanternfish looks for devices on your local network to show their names, addresses and open ports.</string>
    <key>NSLocationUsageDescription</key>
    <string>Lanternfish uses your location permission only to read the Wi-Fi network name (SSID), as macOS requires.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>Lanternfish uses your location permission only to read the Wi-Fi network name (SSID), as macOS requires.</string>
    <key>NSAppTransportSecurity</key>
    <dict><key>NSAllowsLocalNetworking</key><true/></dict>
    <key>NSBonjourServices</key>
    <array>
$BONJOUR
    </array>
</dict>
</plist>
PLIST

IDENTITY="${CODESIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
echo "Built $APP"
