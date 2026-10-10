#!/usr/bin/env python3
"""Adds the English literals that Activity+'s own views receive as String to the string catalog.

The compiler only extracts literals it can see becoming a LocalizedStringKey. CardHeader, StatLine, .help and
AppKit menu titles take a String and look it up at runtime, so their literals are collected here and marked
"manual" (xcstringstool sync leaves manual entries alone).
"""
import json
import pathlib
import re
import sys

catalog_path, source_dir = sys.argv[1], sys.argv[2]
catalog = json.load(open(catalog_path))
strings = catalog.setdefault("strings", {})

# Where a String literal is UI text: the argument of these labels, up to the next labeled argument.
STARTS = [r"CardHeader\(title:", r"StatLine\(label:", r"trailing:", r"\.help\(", r"NSMenuItem\(title:",
          r"addItem\(withTitle:", r"row\(name:", r"detail:", r"emptyText:", r"title:"]
LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')
NEXT_ARG = re.compile(r",\s*(systemImage|tint|value|action|keyEquivalent|icon|drop|scale|isRemainder|button|url|page)\s*:")

def looks_like_text(s: str) -> bool:
    if "\\(" in s or len(s) < 2:            # interpolations are handled with String(localized:) at the call site
        return False
    if re.fullmatch(r"[a-z0-9_.\-]+", s):    # SF Symbols, identifiers, keys
        return False
    if re.fullmatch(r"[a-z]+:[A-Za-z0-9_.\-]+", s):  # page keys like "metric:memory"
        return False
    if s.startswith(("http", "/", "x-apple", "at.hifiteam", "com.", "ACTIVITYPLUS")):
        return False
    return bool(re.search(r"[A-Za-z]", s))

added = 0
for path in pathlib.Path(source_dir).rglob("*.swift"):
    for line in path.read_text().splitlines():
        if line.strip().startswith("//"):
            continue
        for start in STARTS:
            for m in re.finditer(start, line):
                segment = line[m.end():]
                stop = NEXT_ARG.search(segment)
                if stop:
                    segment = segment[:stop.start()]
                for literal in LITERAL.findall(segment):
                    if "\\(" in literal:
                        continue
                    text = literal.replace('\\"', '"').replace("\\n", "\n")
                    if looks_like_text(text) and text not in strings:
                        strings[text] = {"extractionState": "manual"}
                        added += 1

json.dump(catalog, open(catalog_path, "w"), ensure_ascii=False, indent=2, sort_keys=True)
print(f"l10n: {len(strings)} strings in the catalog ({added} added from Activity+'s own views)")
