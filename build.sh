#!/bin/bash
# Build Halo.app — Claude Code usage in your menu bar.
set -euo pipefail
cd "$(dirname "$0")"

APP="Halo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -o "$APP/Contents/MacOS/Halo" Sources/main.swift

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Halo</string>
    <key>CFBundleIdentifier</key><string>com.mathiasbesil.halo</string>
    <key>CFBundleName</key><string>Halo</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.01</string>
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
