#!/bin/zsh
# App Intents metadata for the widget extension (Resources/Metadata.appintents). WidgetKit reads it to
# offer the "Choose Metric" configuration; Xcode generates it in a build phase, SwiftPM does not.
# Same two steps Xcode runs: the compiler's const-value extraction, then appintentsmetadataprocessor.
#   scripts/widget-metadata.sh <swift build bin path> <appex>/Contents/Resources
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
BIN="$1"
OUT="$2"
MODULE=ActivityPlusWidgets
SOURCES=(Sources/$MODULE/*.swift(N:A))
ARCH="$(uname -m)"
TOOLCHAIN="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The protocols whose conformances the compiler records (AppIntent, AppEnum, …), from the toolchain.
python3 -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1]))["constValueProtocols"]))' \
  "$TOOLCHAIN/usr/share/swift/SwiftConstantValues/AppIntents.json" > "$WORK/protocols.json"

# Type-checking is enough to get the const values; the binary itself comes from swift build.
xcrun swiftc -typecheck -wmo -parse-as-library -swift-version 5 -application-extension \
  -module-name "$MODULE" -target "$ARCH-apple-macos15.0" -sdk "$SDK" -I "$BIN" -I "$BIN/Modules" \
  "${SOURCES[@]}" \
  -emit-const-values-path "$WORK/$MODULE.swiftconstvalues" \
  -Xfrontend -const-gather-protocols-file -Xfrontend "$WORK/protocols.json"

printf '%s\n' "${SOURCES[@]}" > "$WORK/sources.txt"
echo "$WORK/$MODULE.swiftconstvalues" > "$WORK/constvalues.txt"
: > "$WORK/none.txt"
mkdir -p "$OUT"
xcrun appintentsmetadataprocessor --output "$OUT" --toolchain-dir "$TOOLCHAIN" --module-name "$MODULE" \
  --sdk-root "$SDK" --xcode-version "$(xcodebuild -version | awk '/Build version/ { print $3 }')" \
  --platform-family macOS --deployment-target 15.0 --target-triple "$ARCH-apple-macos15.0" \
  --source-file-list "$WORK/sources.txt" --swift-const-vals-list "$WORK/constvalues.txt" \
  --metadata-file-list "$WORK/none.txt" --static-metadata-file-list "$WORK/none.txt" --force 2>&1 \
  | grep -v -E "Starting appintentsmetadataprocessor|Writing Metadata.appintents|Metadata root:" || true
[[ -f "$OUT/Metadata.appintents/extract.actionsdata" ]] || { echo "✗ No App Intents metadata for the widgets" >&2; exit 1; }
