#!/bin/bash
# make-app.sh — build Release and assemble the signed RamGuard.app bundle.
# Option B path (SwiftPM + scripted bundling, user-approved pivot):
# every step is verified so the bundle is correct by construction.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-1.0.0}"
APP="dist/RamGuard.app"

echo "==> swift build --configuration release"
swift build --configuration release

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/RamGuard "$APP/Contents/MacOS/RamGuard"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>RAM Guard</string>
    <key>CFBundleDisplayName</key>
    <string>RAM Guard</string>
    <key>CFBundleIdentifier</key>
    <string>dev.ramguard.RamGuard</string>
    <key>CFBundleExecutable</key>
    <string>RamGuard</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSSupportsAutomaticTerminationAndAppNap</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License</string>
</dict>
</plist>
EOF

echo "==> ad-hoc codesign (signature must never be removed on arm64)"
codesign --force --sign - "$APP"

echo "==> verification"
plutil -lint "$APP/Contents/Info.plist"
PLIST_CHECK=$(plutil -extract LSUIElement raw "$APP/Contents/Info.plist")
[ "$PLIST_CHECK" = "true" ] || { echo "FAIL: LSUIElement not true"; exit 1; }
NAP_CHECK=$(plutil -extract NSSupportsAutomaticTerminationAndAppNap raw "$APP/Contents/Info.plist")
[ "$NAP_CHECK" = "false" ] || { echo "FAIL: App Nap key not false"; exit 1; }
codesign -dv "$APP" 2>&1 | grep -E "Signature=adhoc" || { echo "FAIL: not ad-hoc signed"; exit 1; }
ENTITLEMENTS=$(codesign -d --entitlements :- "$APP" 2>&1 || true)
echo "entitlements: [$ENTITLEMENTS]"
ARCH=$(lipo -info "$APP/Contents/MacOS/RamGuard")
echo "$ARCH" | grep -q arm64 || { echo "FAIL: no arm64 slice"; exit 1; }
echo "$ARCH" | grep -qv x86_64 || echo "note: universal (x86_64 slice present)"
echo "OK: $APP ($VERSION) — ad-hoc signed, LSUIElement on, App Nap off, arm64"
