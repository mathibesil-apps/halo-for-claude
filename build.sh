#!/bin/bash
# Build "Halo for Claude.app" — Claude Code usage in your menu bar.
set -euo pipefail
cd "$(dirname "$0")"

APP="Halo for Claude.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal binary: compile each arch, then lipo them so it runs on both Apple
# Silicon and Intel Macs. macOS 13 is the floor (SMAppService "Launch at login").
BIN_TMP=$(mktemp -d)
swiftc -O -target arm64-apple-macos13.0  -o "$BIN_TMP/Halo-arm64"  Sources/main.swift
swiftc -O -target x86_64-apple-macos13.0 -o "$BIN_TMP/Halo-x86_64" Sources/main.swift
lipo -create "$BIN_TMP/Halo-arm64" "$BIN_TMP/Halo-x86_64" -o "$APP/Contents/MacOS/Halo"
rm -rf "$BIN_TMP"

# App icon: build AppIcon.icns from the 1024px source (sips + iconutil ship with macOS).
if [ -f icon/AppIcon-1024.png ]; then
    ICONSET=$(mktemp -d)/AppIcon.iconset
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z $size $size          icon/AppIcon-1024.png --out "$ICONSET/icon_${size}x${size}.png"     >/dev/null
        sips -z $((size*2)) $((size*2)) icon/AppIcon-1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$(dirname "$ICONSET")"
fi

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Halo</string>
    <key>CFBundleIdentifier</key><string>com.mathiasbesil.halo</string>
    <key>CFBundleName</key><string>Halo for Claude</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.06</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

# macOS ties Keychain permission to the code signature, so an ad-hoc signature —
# which changes on every build — makes it ask again after each rebuild. Signing
# with a real identity, when the machine has one, makes the permission stick.
# Override with CODESIGN_ID="Some Identity", or CODESIGN_ID=- to force ad-hoc.
if [ -z "${CODESIGN_ID:-}" ]; then
    CODESIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -m1 -oE '"(Developer ID Application|Apple Development)[^"]*"' \
        | tr -d '"' || true)
fi
if [ -n "${CODESIGN_ID:-}" ] && [ "$CODESIGN_ID" != "-" ]; then
    codesign --force --sign "$CODESIGN_ID" "$APP"
    echo "Built $APP  (signed: $CODESIGN_ID)"
else
    codesign --force --sign - "$APP"
    echo "Built $APP  (ad-hoc signed; macOS will re-ask for Keychain access after each rebuild)"
fi
