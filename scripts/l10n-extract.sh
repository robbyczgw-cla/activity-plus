#!/bin/zsh
# Collects every translatable string into Resources/Localizable.xcstrings.
#   scripts/l10n-extract.sh            update the catalog
#   scripts/l10n-extract.sh --check    also fail when a language has untranslated strings (used by release.sh)
#
# Two sources: the Swift compiler's own extraction (Text("…"), Button("…"), String(localized: "…"), …) and the
# English literals handed to Activity+'s own views (CardHeader, StatLine, .help, menu items), which take a String
# and look it up at runtime with LocalizedStringKey.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CATALOG=Resources/Localizable.xcstrings
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

[[ -f "$CATALOG" ]] || echo '{"sourceLanguage":"en","strings":{},"version":"1.0"}' > "$CATALOG"
swift build --product ActivityPlus -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT" >/dev/null
xcrun xcstringstool sync "$CATALOG" --stringsdata "$OUT"/*.stringsdata
python3 scripts/l10n-manual.py "$CATALOG" Sources/ActivityPlus

if [[ "${1:-}" == "--check" ]]; then
  python3 - "$CATALOG" <<'EOF'
import json, sys
catalog = json.load(open(sys.argv[1]))
import plistlib
languages = [l for l in plistlib.load(open("Resources/Info.plist", "rb"))["CFBundleLocalizations"] if l != "en"]
missing = {lang: [] for lang in languages}
for key, entry in catalog["strings"].items():
    if not key.strip() or entry.get("shouldTranslate") is False or entry.get("extractionState") == "stale":
        continue
    for lang in languages:
        unit = entry.get("localizations", {}).get(lang, {})
        if "stringUnit" not in unit and "variations" not in unit:
            missing[lang].append(key)
bad = {lang: keys for lang, keys in missing.items() if keys}
for lang, keys in bad.items():
    print(f"{lang}: {len(keys)} untranslated, e.g. {keys[:5]}")
sys.exit(1 if bad else 0)
EOF
fi
