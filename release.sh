#!/bin/bash
# Build, sign (hardened runtime), package, and notarize "Halo for Claude"
# into a distributable .dmg. Run this to cut a release people can download and
# open with a double-click — no Gatekeeper warnings.
#
# One-time setup (see README "Releasing"): create an app-specific password at
# https://appleid.apple.com, then store notary credentials once with:
#   xcrun notarytool store-credentials "halo-notary" \
#       --apple-id "you@example.com" --team-id "VDQ9CQ46C5"
#
# Then just: ./release.sh
set -euo pipefail
cd "$(dirname "$0")"

APP="Halo for Claude.app"
DMG="Halo-for-Claude.dmg"
VOLNAME="Halo for Claude"
NOTARY_PROFILE="${NOTARY_PROFILE:-halo-notary}"

# --- 1. Find the Developer ID Application certificate ------------------------
CODESIGN_ID=$(security find-identity -v -p codesigning \
    | grep -m1 -oE '"Developer ID Application[^"]*"' | tr -d '"' || true)
if [ -z "$CODESIGN_ID" ]; then
    echo "error: no 'Developer ID Application' certificate in your keychain." >&2
    echo "       Create one in Xcode › Settings › Accounts › Manage Certificates." >&2
    exit 1
fi
echo "Signing identity: $CODESIGN_ID"

# --- 2. Check notary credentials are set up ---------------------------------
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "error: notary profile '$NOTARY_PROFILE' not found." >&2
    echo "       Set it up once (needs an app-specific password from" >&2
    echo "       https://appleid.apple.com):" >&2
    echo "         xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\" >&2
    echo "             --apple-id \"you@example.com\" --team-id \"VDQ9CQ46C5\"" >&2
    exit 1
fi

# --- 3. Build, then re-sign with hardened runtime + secure timestamp --------
# Notarization requires both; the plain build.sh signature has neither.
./build.sh >/dev/null
codesign --force --options runtime --timestamp --sign "$CODESIGN_ID" "$APP"
echo "Signed with hardened runtime."

# --- 4. Package into a drag-to-Applications .dmg ----------------------------
STAGING=$(mktemp -d)
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"
codesign --force --timestamp --sign "$CODESIGN_ID" "$DMG"
echo "Built $DMG"

# --- 5. Notarize and staple the ticket (so it verifies offline) -------------
echo "Submitting to Apple for notarization (this can take a few minutes)…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

echo ""
echo "✓ Done. $DMG is signed, notarized, and stapled — ready to distribute."
xcrun stapler validate "$DMG"
