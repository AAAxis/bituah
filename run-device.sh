#!/usr/bin/env bash
# Build the iOS demo and install it on a connected iPhone (USB or same Wi-Fi, "Trust this computer" done).
# Requires Xcode signed in with the team in iOSApp/project.yml (Xcode ▸ Settings ▸ Accounts).
set -euo pipefail
cd "$(dirname "$0")/iOSApp"
[ -d Vendor/libtesseract/libtesseract.xcframework ] || ./setup.sh
xcodegen generate >/dev/null
UDID=$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /connected/ {print $(NF-4)}' | head -1)
UDID="${1:-$UDID}"
[ -n "$UDID" ] || { echo "No connected iPhone found. Plug it in, unlock it, then: ./run-device.sh <UDID>"; xcrun devicectl list devices; exit 1; }
xcodebuild -project BituahApp.xcodeproj -scheme BituahApp -configuration Debug \
  -destination "id=$UDID" -allowProvisioningUpdates -derivedDataPath build build 2>&1 | grep -E "error|warning: no|BUILD" || true
APP=$(find build/Build/Products/Debug-iphoneos -name "BituahApp.app" -maxdepth 1 | head -1)
xcrun devicectl device install app --device "$UDID" "$APP"
xcrun devicectl device process launch --device "$UDID" com.dima.bituah
