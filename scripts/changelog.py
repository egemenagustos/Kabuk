#!/usr/bin/env python3
"""Keeps CHANGELOG.md and README's "What's new" in step. Used by scripts/release.sh.

  changelog.py release <version> <date>   Unreleased becomes <version>; a new empty Unreleased opens
  changelog.py notes <version>            prints that version's section, for the GitHub release
  changelog.py readme <version>           rewrites README's What's new block from that section
  changelog.py unreleased                 exits 1 when Unreleased has no entries
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHANGELOG = ROOT / "CHANGELOG.md"
README = ROOT / "README.md"
REPO = "https://github.com/egemenagustos/Kabuk"
HEADING = re.compile(r"^## \[(?P<name>[^\]]+)\](?: - (?P<date>\S+))?\s*$", re.M)


def sections(text):
    """(name, date, start, end) for every '## [x]' section; end stops at the next section or the link list."""
    found = list(HEADING.finditer(text))
    links = re.search(r"^\[[^\]]+\]: ", text, re.M)
    limit = links.start() if links else len(text)
    result = []
    for i, m in enumerate(found):
        end = found[i + 1].start() if i + 1 < len(found) else limit
        result.append((m["name"], m["date"], m.end(), end))
    return result


def body(text, name):
    for n, _, start, end in sections(text):
        if n == name:
            return text[start:end].strip()
    sys.exit(f"CHANGELOG.md has no [{name}] section")


def has_entries(section):
    return any(line.startswith("- ") for line in section.splitlines())


def release(version, date):
    text = CHANGELOG.read_text()
    if any(n == version for n, *_ in sections(text)):
        sys.exit(f"CHANGELOG.md already has [{version}]")
    if not has_entries(body(text, "Unreleased")):
        sys.exit("Unreleased has no entries; nothing to release")
    text = text.replace("## [Unreleased]", f"## [Unreleased]\n\n## [{version}] - {date}", 1)
    previous = next((n for n, *_ in sections(text) if n not in ("Unreleased", version)), None)
    old = re.search(r"^\[Unreleased\]: .*$", text, re.M)
    links = f"[Unreleased]: {REPO}/compare/v{version}...HEAD\n"
    links += f"[{version}]: {REPO}/compare/v{previous}...v{version}" if previous else f"[{version}]: {REPO}/releases/tag/v{version}"
    text = text[:old.start()] + links + text[old.end():] if old else text.rstrip() + "\n\n" + links + "\n"
    CHANGELOG.write_text(text)


def readme(version):
    text = CHANGELOG.read_text()
    date = next(d for n, d, *_ in sections(text) if n == version)
    lines = [f"**{version}** ({date}):", ""]
    kind = None
    for line in body(text, version).splitlines():
        if line.startswith("### "):
            kind = line[4:].strip()
        elif line.startswith("- "):
            lines.append(f"- {kind}: {line[2:]}" if kind else line)
    lines += ["", "See **[CHANGELOG.md](CHANGELOG.md)** for every version and what is on `main` but not released yet."]
    block = "<!-- whats-new:start -->\n" + "\n".join(lines) + "\n<!-- whats-new:end -->"
    old = README.read_text()
    new = re.sub(r"<!-- whats-new:start -->.*?<!-- whats-new:end -->", lambda _: block, old, flags=re.S)
    if new == old and block not in old:
        sys.exit("README.md has no whats-new markers")
    README.write_text(new)


def main(args):
    if args[:1] == ["release"] and len(args) == 3:
        release(args[1], args[2])
    elif args[:1] == ["notes"] and len(args) == 2:
        print(body(CHANGELOG.read_text(), args[1]))
    elif args[:1] == ["readme"] and len(args) == 2:
        readme(args[1])
    elif args == ["unreleased"]:
        sys.exit(0 if has_entries(body(CHANGELOG.read_text(), "Unreleased")) else 1)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
