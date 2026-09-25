#!/bin/zsh
# Builds, signs with Developer ID (hardened runtime), notarizes and staples Activity+.
# Result: dist/Activity+.app (stapled) and dist/Activity+-<version>.zip, ready to hand out.
#   scripts/release.sh             sign + notarize
#   scripts/release.sh --site      … and put the zip + a signed appcast.xml into the homepage (../activityplus-site)
#   scripts/release.sh --publish   … and create the GitHub release with appcast.xml (notes: docs/release-notes/v<version>.md)
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
sign() { codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@"; }
# Inside-out: Sparkle's XPC services and helper apps, then the framework, our CLI, and the app last.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
if [[ -d "$SPARKLE" ]]; then
  for item in "$SPARKLE"/XPCServices/*.xpc(N) "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app"; do
    [[ -e "$item" ]] && sign "$item"
  done
  sign "$APP/Contents/Frameworks/Sparkle.framework"
fi
sign "$APP/Contents/Resources/aplus"
sign --identifier at.hifiteam.activityplus.helper "$APP/Contents/MacOS/ActivityPlusHelper"
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

# Homepage: activityplus.xyz serves the download and the update feed (works while the repo is private).
if [[ "${1:-}" == "--site" ]]; then
  SITE="${SITE_DIR:-../activityplus-site}"
  mkdir -p "$SITE/download"
  cp "$ZIP" "$SITE/download/"
  STAGE="dist/appcast-site"
  rm -rf "$STAGE" && mkdir -p "$STAGE"
  # Keep older zips next to the new one so generate_appcast lists the history.
  cp "$SITE"/download/*.zip "$STAGE/"
  .build/artifacts/sparkle/Sparkle/bin/generate_appcast --account activityplus \
    --download-url-prefix "https://activityplus.xyz/download/" --link "https://activityplus.xyz" "$STAGE"
  cp "$STAGE/appcast.xml" "$SITE/appcast.xml"
  # The appcast references the delta updates generate_appcast just made: publish them too.
  rm -f "$SITE"/download/*.delta
  cp "$STAGE"/*.delta "$SITE/download/" 2>/dev/null || true
  shasum -a 256 "$ZIP" | awk '{print $1}' > "$SITE/download/latest.sha256"
  echo "✓ Site updated: $SITE/download/$(basename "$ZIP") + appcast.xml"
fi

# Appcast for Sparkle: signed with the EdDSA key in the keychain (account "activityplus").
# Every GitHub release carries appcast.xml, so .../releases/latest/download/appcast.xml always points at the newest.
if [[ "${1:-}" == "--publish" ]]; then
  STAGE="dist/appcast"
  rm -rf "$STAGE" && mkdir -p "$STAGE"
  cp "$ZIP" "$STAGE/"
  .build/artifacts/sparkle/Sparkle/bin/generate_appcast --account activityplus \
    --download-url-prefix "https://github.com/robbyczgw-cla/activity-plus/releases/download/v$VERSION/" \
    --link "https://github.com/robbyczgw-cla/activity-plus" "$STAGE"
  NOTES="${RELEASE_NOTES:-docs/release-notes/v$VERSION.md}"
  gh release create "v$VERSION" "$ZIP" "$STAGE/appcast.xml" --repo robbyczgw-cla/activity-plus \
    --title "Activity+ $VERSION" --notes-file "$NOTES"
  echo "✓ Published v$VERSION"
fi
