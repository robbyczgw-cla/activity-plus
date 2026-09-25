#!/bin/zsh
# Builds, signs with Developer ID (hardened runtime), notarizes and staples Activity+.
# Result: dist/Activity+.app (stapled) and dist/Activity+-<version>.zip, ready to hand out.
#
# One-time setup — stores the App Store Connect API key as a keychain profile:
#   xcrun notarytool store-credentials activityplus \
#     --key ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"

IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Robert Czesany (P35939S43T)}"
PROFILE="${NOTARY_PROFILE:-activityplus}"
APP="dist/Activity+.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)

scripts/build-app.sh
# Build number = commit count, so every release is newer than the last one.
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $(git rev-list --count HEAD)" "$APP/Contents/Info.plist"

echo "→ Signing with $IDENTITY"
# Inside-out: nested executables and frameworks first, the app last.
find "$APP/Contents" -type f \( -perm -u+x -o -name "*.dylib" \) ! -path "*/MacOS/ActivityPlus" -print0 |
  while IFS= read -r -d '' file; do
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$file"
  done
if [[ -d "$APP/Contents/Frameworks" ]]; then
  for framework in "$APP"/Contents/Frameworks/*.framework(N); do
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$framework"
  done
fi
codesign --force --options runtime --timestamp --entitlements Resources/ActivityPlus.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "→ Notarizing (usually 1–5 minutes)"
ZIP="dist/Activity+-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"

# Re-zip so the handed-out archive contains the stapled ticket (works offline too).
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl -a -vv "$APP"
echo "✓ $ZIP"
