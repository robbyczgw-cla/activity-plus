#!/usr/bin/env python3
"""Checks a translation file before l10n-apply.py: every key present, placeholders intact, plural forms valid.

    scripts/l10n-validate.py <lang> file.json
"""
import json, re, sys

lang, path = sys.argv[1], sys.argv[2]
keys = json.load(open(".delegate/l10n-keys.json"))
plural_keys = set(json.load(open(".delegate/l10n-plural-keys.json")))
data = json.load(open(path))
data.pop("__en_plurals__", None)
FMT = re.compile(r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:@|lld|ld|d|f|g|%)")
norm = lambda s: sorted(re.sub(r"\d+\$", "", m) for m in FMT.findall(s))
problems = []
missing = [k for k in keys if k not in data]
extra = [k for k in data if k not in keys]
if missing: problems.append(f"{len(missing)} missing, e.g. {missing[:3]}")
if extra: problems.append(f"{len(extra)} unknown keys, e.g. {extra[:3]}")
for key, value in data.items():
    forms = value.values() if isinstance(value, dict) else [value]
    if isinstance(value, dict) and not set(value) <= {"zero", "one", "two", "few", "many", "other"}:
        problems.append(f"bad plural forms {list(value)} for {key!r}")
    for form in forms:
        if not isinstance(form, str):
            problems.append(f"non-string for {key!r}"); continue
        if norm(form) != norm(key):
            problems.append(f"placeholders differ: {key!r} → {form!r}")
        if key[:1] == " " and form[:1] != " " or key[-1:] == " " and form[-1:] != " ":
            problems.append(f"edge space lost: {key!r} → {form!r}")
print(f"{lang}: {len(data)} entries, {len(problems)} problems")
for p in problems[:40]: print("  ", p)
sys.exit(1 if problems else 0)
