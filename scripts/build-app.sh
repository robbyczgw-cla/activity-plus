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
# Test builds get their own identity, so they never collide with the installed app: no shared settings, privacy
# answers, notifications or helper registration. release.sh sets RELEASE_BUILD=1 and keeps the real one.
if [[ "${RELEASE_BUILD:-}" != "1" ]]; then
  /usr/libexec/PlistBuddy -c "Set CFBundleIdentifier at.hifiteam.activityplus.dev" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add CFBundleDisplayName string Activity+ Dev" "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set CFBundleDisplayName Activity+ Dev" "$APP/Contents/Info.plist"
fi
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Translations: the string catalog compiles to <lang>.lproj/Localizable.strings(dict) next to the app's resources.
[[ -f Resources/Localizable.xcstrings ]] && xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$APP/Contents/Resources" >/dev/null
# Sparkle ships as a binary framework; the executable finds it through @executable_path/../Frameworks.
mkdir -p "$APP/Contents/Frameworks"
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - --timestamp=none --identifier at.hifiteam.activityplus.helper "$APP/Contents/MacOS/ActivityPlusHelper"
codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--run" ]]; then
  # Only the copy in dist/, never the installed app.
  pkill -f "^$PWD/dist/Activity\+\.app/Contents/MacOS/ActivityPlus" 2>/dev/null || true
  sleep 0.5
  open "$APP"
fi
