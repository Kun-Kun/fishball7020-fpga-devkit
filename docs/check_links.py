#!/usr/bin/env python3
"""Check the documentation's links, and that every command block says where it runs.

    # run from: the repo root
    python3 docs/check_links.py            # every tracked .md, plus the pages under docs/
    python3 docs/check_links.py FILE...    # just these

For every relative link it checks that the target file exists and, for a
#anchor into a Markdown or HTML file, that the heading or id is there (GitHub's
heading-to-anchor rules, including the -1, -2 suffixes of repeated headings).
External http(s) links are not fetched. In Markdown under docs/ and in the top
README, every bash/sh/shell/matlab code block must open with a line saying
where it runs: `# run from: ...` or `# run on ...` (`%` for MATLAB). Exit 0 if clean, 1 otherwise. CI runs it
(.github/workflows/docs.yml).
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SKIP = ("firmware/src/", "firmware-modern/src/")
FENCE = re.compile(r"^(\s*)(```+|~~~+)(.*)$")
CMD_LANGS = {"bash", "sh", "shell", "console", "matlab"}


def tracked():
    out = subprocess.run(["git", "ls-files", "*.md", "docs/*.html", "docs/**/*.html"],
                         cwd=ROOT, capture_output=True, text=True, check=True).stdout
    return [ROOT / f for f in out.split() if not f.startswith(SKIP) and (ROOT / f).exists()]


def split_code(text):
    """Return (prose with code blocks blanked, [(lang, first_line, lineno)])."""
    prose, blocks, fence, lang, first, start = [], [], None, "", None, 0
    for n, line in enumerate(text.splitlines(), 1):
        m = FENCE.match(line)
        if fence is None and m:
            fence, lang, first, start = m.group(2), m.group(3).strip().lower(), None, n
            prose.append("")
        elif fence is not None:
            if m and m.group(2).startswith(fence[0]) and len(m.group(2)) >= len(fence) and not m.group(3).strip():
                blocks.append((lang, first, start))
                fence = None
            elif first is None and line.strip():
                first = line.strip()
            prose.append("")
        else:
            prose.append(line)
    return "\n".join(prose), blocks


def slug(heading):
    h = re.sub(r"<[^>]+>", "", heading).strip().lower()
    h = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", h)          # [text](link) -> text
    h = re.sub(r"[^\w\- ]", "", h)                          # punctuation and emoji go
    return h.replace(" ", "-")


_anchors = {}


def anchors(path):
    if path not in _anchors:
        text = path.read_text(errors="replace")
        found = set(re.findall(r'<a\s+(?:name|id)="([^"]+)"', text))
        if path.suffix == ".html":
            found |= set(re.findall(r'\bid="([^"]+)"', text))
        else:
            prose, _ = split_code(text)
            seen = {}
            for line in prose.splitlines():
                m = re.match(r"^(?:>\s*)?#{1,6}\s+(.*?)\s*#*\s*$", line)
                if m:
                    s = slug(m.group(1))
                    k = seen.get(s, 0)
                    found.add(s if k == 0 else f"{s}-{k}")
                    seen[s] = k + 1
        _anchors[path] = found
    return _anchors[path]


def links(path, text):
    if path.suffix == ".md":
        prose, _ = split_code(text)
        prose = re.sub(r"`[^`\n]*`", "", prose)
        yield from re.findall(r"\]\(<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\)", prose)
        yield from re.findall(r"^\s*\[[^\]]+\]:\s*(\S+)", prose, flags=re.M)
        text = prose
    yield from re.findall(r'\b(?:href|src)="([^"]+)"', text)


def check(path):
    problems = []
    rel = path.relative_to(ROOT)
    text = path.read_text(errors="replace")
    for link in links(path, text):
        if re.match(r"^[a-z][a-z0-9+.-]*:", link, re.I) or link.startswith("//"):
            continue                                        # http:, mailto:, data: ...
        target, _, anchor = link.partition("#")
        dest = (path.parent / target).resolve() if target else path
        if not dest.is_relative_to(ROOT):
            continue                                        # ../../issues: a GitHub page
        if target.endswith("/") or (dest.is_dir() and (dest / "index.html").exists()):
            dest = dest / "index.html" if (dest / "index.html").exists() else dest
        if not dest.exists():
            problems.append(f"{rel}: missing target {link}")
        elif anchor and dest.suffix in (".md", ".html") and anchor not in anchors(dest):
            problems.append(f"{rel}: no anchor #{anchor} in {link or rel}")
    if path.suffix == ".md" and (rel.parts[0] == "docs" or str(rel) == "README.md"):
        for lang, first, n in split_code(text)[1]:
            if lang.split()[0:1] and lang.split()[0] in CMD_LANGS:
                mark = "%" if lang.startswith("matlab") else "#"
                if not re.match(mark + r" run (from|on)\b", first or ""):
                    problems.append(f"{rel}:{n}: {lang} block does not open with '{mark} run from: ...'")
    return problems


def main(argv):
    files = [pathlib.Path(a).resolve() for a in argv] if argv else tracked()
    problems = [p for f in files for p in check(f)]
    for p in problems:
        print(p)
    print(f"check_links: {len(files)} files, {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
