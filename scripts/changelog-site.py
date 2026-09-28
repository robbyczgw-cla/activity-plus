#!/usr/bin/env python3
"""Renders docs/release-notes/v*.md into the homepage's changelog page.

    scripts/changelog-site.py [SITE_DIR]      default ../activityplus-site

Writes changelog.html (same frame as legal.html) and changelog.md. The date of
each version is the date of the commit that added its notes file.
"""
import html
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SITE = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ROOT.parent / "activityplus-site")
NOTES = ROOT / "docs" / "release-notes"


def version_key(path):
    return tuple(int(p) for p in path.stem.lstrip("v").split("."))


def release_date(path):
    out = subprocess.run(["git", "log", "--diff-filter=A", "-1", "--format=%cs", "--", str(path)],
                         cwd=ROOT, capture_output=True, text=True).stdout.strip()
    return out or ""


def inline(text):
    text = html.escape(text, quote=False)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    return re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', text)


def to_html(markdown):
    """The small subset the release notes use: paragraphs, **Heading** lines, - lists."""
    out, items = [], []

    def flush():
        if items:
            out.append("<ul>" + "".join(f"<li>{inline(i)}</li>" for i in items) + "</ul>")
            items.clear()

    for line in markdown.strip().splitlines():
        line = line.rstrip()
        if line.startswith("- "):
            items.append(line[2:])
            continue
        flush()
        if not line:
            continue
        heading = re.fullmatch(r"\*\*([^*]+)\*\*", line)
        out.append(f"<h3>{html.escape(heading.group(1))}</h3>" if heading else f"<p>{inline(line)}</p>")
    flush()
    return "\n".join(out)


notes = sorted(NOTES.glob("v*.md"), key=version_key, reverse=True)
sections_html, sections_md = [], []
for path in notes:
    version, date = path.stem.lstrip("v"), release_date(path)
    body = path.read_text()
    stamp = f' <span class="changelog-date">{date}</span>' if date else ""
    sections_html.append(f'    <section id="v{version}">\n    <h2>{version}{stamp}</h2>\n{to_html(body)}\n    </section>')
    sections_md.append(f"## {version}" + (f" ({date})" if date else "") + f"\n\n{body.strip()}\n")

frame = (SITE / "legal.html").read_text()
head, _, rest = frame.partition("<main")
foot = rest[rest.index("</main>") + len("</main>"):]
head = re.sub(r"<title>.*?</title>", "<title>Changelog — Activity+</title>", head)
head = re.sub(r'<meta name="description" content="[^"]*">',
              '<meta name="description" content="What changed in each version of Activity+.">', head)
head = head.replace('href="/legal.md"', 'href="/changelog.md"')
page = (head + '<main class="legal changelog" id="main">\n    <h1>Changelog</h1>\n'
        '    <p>Every version of Activity+ and what it brought. Updates arrive in the app on their own; '
        '<a href="/#download">the download</a> is always the newest.</p>\n'
        + "\n".join(sections_html) + "\n  </main>" + foot)
(SITE / "changelog.html").write_text(page)
(SITE / "changelog.md").write_text("# Activity+ changelog\n\n" + "\n".join(sections_md))
print(f"changelog: {len(notes)} versions -> {SITE / 'changelog.html'}")
