#!/bin/zsh
# Builds dist/Activity+.app (release, ad-hoc signed) and optionally launches it.
#   scripts/build-app.sh          build
#   scripts/build-app.sh --run    build, quit the running copy, launch
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

swift build -c release --product ActivityPlus
swift build -c release --product aplus
swift build -c release --product ActivityPlusHelper
swift build -c release --product ActivityPlusWidgets
BIN="$(swift build -c release --show-bin-path)"

APP="dist/Activity+.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ActivityPlus" "$APP/Contents/MacOS/"
cp "$BIN/aplus" "$APP/Contents/Resources/"
# Privileged helper, registered on demand through SMAppService (Settings → General).
cp "$BIN/ActivityPlusHelper" "$APP/Contents/MacOS/"
mkdir -p "$APP/Contents/Library/LaunchDaemons"
cp Resources/LaunchDaemons/at.hifiteam.activityplus.helper.plist "$APP/Contents/Library/LaunchDaemons/"
cp Resources/Info.plist "$APP/Contents/"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Translations: the string catalog compiles to <lang>.lproj/Localizable.strings(dict) next to the app's resources.
[[ -f Resources/Localizable.xcstrings ]] && xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$APP/Contents/Resources" >/dev/null
# Sparkle ships as a binary framework; the executable finds it through @executable_path/../Frameworks.
mkdir -p "$APP/Contents/Frameworks"
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
# Desktop / Notification Center widgets: a WidgetKit app extension with its own Info.plist (versions follow
# the app's), the app's translations and the App Intents metadata for its configuration.
APPEX="$APP/Contents/PlugIns/ActivityPlusWidgets.appex"
mkdir -p "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"
cp "$BIN/ActivityPlusWidgets" "$APPEX/Contents/MacOS/"
cp Resources/Widgets/Info.plist "$APPEX/Contents/"
for key in CFBundleShortVersionString CFBundleVersion; do
  /usr/libexec/PlistBuddy -c "Set $key $(/usr/libexec/PlistBuddy -c "Print $key" Resources/Info.plist)" "$APPEX/Contents/Info.plist"
done
plutil -replace CFBundleLocalizations -json "$(plutil -extract CFBundleLocalizations json -o - Resources/Info.plist)" "$APPEX/Contents/Info.plist"
[[ -f Resources/Localizable.xcstrings ]] && xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$APPEX/Contents/Resources" >/dev/null
scripts/widget-metadata.sh "$BIN" "$APPEX/Contents/Resources"
# SIGN_IDENTITY="Apple Development" signs with your team instead of ad hoc: only then does macOS let the app
# and the widget share the App Group container, so use it to try the widgets locally.
SIGN="${SIGN_IDENTITY:--}"
codesign --force --sign "$SIGN" --timestamp=none --entitlements Resources/Widgets/ActivityPlusWidgets.entitlements "$APPEX"
codesign --force --sign "$SIGN" --timestamp=none --identifier at.hifiteam.activityplus.helper "$APP/Contents/MacOS/ActivityPlusHelper"
if [[ "$SIGN" == "-" ]]; then
  codesign --force --sign - --timestamp=none "$APP"
else
  codesign --force --sign "$SIGN" --timestamp=none --entitlements Resources/ActivityPlus.entitlements "$APP"
fi
echo "Built $APP"

if [[ "${1:-}" == "--run" ]]; then
  pkill -x ActivityPlus 2>/dev/null || true
  sleep 0.5
  open "$APP"
fi
