#!/usr/bin/env python3
"""Points the homepage's download section at a new release.

    scripts/site-download.py VERSION ZIP [SITE_DIR]

Sets the version, the zip link and size, the SHA-256 and the "What's new" link in
index.html, index.md and llms.txt. Fails if an expected spot is missing, so a
changed page layout cannot silently leave an old checksum behind.
"""
import hashlib
import pathlib
import re
import sys

version, zip_path = sys.argv[1], pathlib.Path(sys.argv[2])
site = pathlib.Path(sys.argv[3] if len(sys.argv) > 3 else pathlib.Path(__file__).resolve().parent.parent.parent / "activityplus-site")
sha = hashlib.sha256(zip_path.read_bytes()).hexdigest()
size = f"{zip_path.stat().st_size / 1_048_576:.1f} MB"
name = f"Activity+-{version}.zip"


def patch(file, rules):
    path = site / file
    text = path.read_text()
    for pattern, replacement in rules:
        text, count = re.subn(pattern, replacement, text)
        if count == 0:
            sys.exit(f"site-download: no match for {pattern!r} in {file}")
    path.write_text(text)


zip_link = (r"/download/Activity\+-[\d.]+\.zip", f"/download/{name}")
patch("index.html", [
    (r"<span data-version>[\d.]+</span>", f"<span data-version>{version}</span>"),
    zip_link,
    (r"Download Activity\+ \([\d.]+ MB\)", f"Download Activity+ ({size})"),
    (r"<code data-sha>[0-9a-f]{64}</code>", f"<code data-sha>{sha}</code>"),
    (r"/changelog#v[\d.]+\">What's new in [\d.]+", f"/changelog#v{version}\">What's new in {version}"),
])
patch("index.md", [
    (r"## Activity\+ [\d.]+", f"## Activity+ {version}"),
    zip_link,
    (r"Download Activity\+ \([\d.]+ MB\)", f"Download Activity+ ({size})"),
    (r"SHA-256 `[0-9a-f]{64}`", f"SHA-256 `{sha}`"),
    (r"\[What's new in [\d.]+\]\(/changelog#v[\d.]+\)", f"[What's new in {version}](/changelog#v{version})"),
])
patch("llms.txt", [zip_link])
print(f"site-download: {version}, {size}, sha256 {sha[:12]}…")
