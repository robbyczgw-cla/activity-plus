#!/bin/zsh
# Builds dist/Activity+.app (release, ad-hoc signed) and optionally launches it.
#   scripts/build-app.sh          build
#   scripts/build-app.sh --run    build, quit the running copy, launch
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"

swift build -c release --product ActivityPlus
swift build -c release --product aplus
BIN="$(swift build -c release --show-bin-path)"

APP="dist/Activity+.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ActivityPlus" "$APP/Contents/MacOS/"
cp "$BIN/aplus" "$APP/Contents/Resources/"
cp Resources/Info.plist "$APP/Contents/"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--run" ]]; then
  pkill -x ActivityPlus 2>/dev/null || true
  sleep 0.5
  open "$APP"
fi
