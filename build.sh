#!/bin/bash
# Build "Claude Usage.app" — a menu bar app showing Claude Code usage.
set -euo pipefail
cd "$(dirname "$0")"

APP="Claude Usage.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -o "$APP/Contents/MacOS/ClaudeUsage" Sources/main.swift

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ClaudeUsage</string>
    <key>CFBundleIdentifier</key><string>com.mathiasbesil.claude-usage</string>
    <key>CFBundleName</key><string>Claude Usage</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "Built $APP"
