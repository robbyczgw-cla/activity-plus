#!/usr/bin/env python3
"""Writes translations into Resources/Localizable.xcstrings.

    scripts/l10n-apply.py de translations.json

The JSON maps the English key to either a string (the translation) or a plural object
{"one": …, "other": …}. A key "__en_plurals__" may hold English plural forms for keys whose
English text should also change with the count (one/other).
"""
import json
import sys

CATALOG = "Resources/Localizable.xcstrings"
lang, path = sys.argv[1], sys.argv[2]
catalog = json.load(open(CATALOG))
strings = catalog["strings"]
data = json.load(open(path))

def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}

def plural(forms):
    return {"variations": {"plural": {form: unit(text) for form, text in forms.items()}}}

applied, unknown = 0, []
for key, forms in data.pop("__en_plurals__", {}).items():
    if key not in strings:
        unknown.append(key); continue
    strings[key].setdefault("localizations", {})["en"] = plural(forms)
for key, value in data.items():
    if key not in strings:
        unknown.append(key); continue
    loc = strings[key].setdefault("localizations", {})
    loc[lang] = plural(value) if isinstance(value, dict) else unit(value)
    applied += 1

json.dump(catalog, open(CATALOG, "w"), ensure_ascii=False, indent=2, sort_keys=True)
print(f"{lang}: {applied} applied" + (f", {len(unknown)} unknown keys: {unknown[:8]}" if unknown else ""))
