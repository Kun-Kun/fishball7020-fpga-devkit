"""MkDocs hooks: make the site read docs/ exactly as GitHub does.

docs/ is written for GitHub first, so two GitHub behaviours are reproduced here
rather than changing the Markdown:

- Heading anchors. GitHub lowercases a heading, drops punctuation and turns each
  space into a hyphen, so "Option D — JTAG" becomes "option-d--jtag". MkDocs'
  default collapses the double hyphen, which would break every link written
  against GitHub. docs/check_links.py checks links with GitHub's rule, so the
  site uses the same one.
- Links out of docs/. "../README.md" or "../examples/" work on GitHub but are
  not part of the site, so on the site they point at the file on GitHub.
- Paths in raw HTML (<img src>, <picture srcset>) are relative to the file on
  GitHub; on the site each page is a folder deeper, so they are adjusted.
"""
import os
import re

REPO = "https://github.com/matsvandamme/fishball7020-fpga-devkit"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def github_slug(value, separator="-"):
    s = value.strip().lower()
    s = re.sub(r"[^\w\- ]", "", s)
    return s.replace(" ", separator)


def on_config(config):
    config.mdx_configs.setdefault("toc", {})["slugify"] = github_slug
    return config


_LINK = re.compile(r"(\]\(|\b(?:href|src|srcset)=\")(?!https?:|mailto:|#|/)([^)\"\s#]+)")


def on_page_markdown(markdown, page, config, files):
    src_dir = os.path.dirname(page.file.src_path)
    docs_dir = config["docs_dir"]

    # Each page is served one folder deeper than its file ("hardware.md" ->
    # "hardware/"). MkDocs adjusts Markdown links for that, not raw HTML.
    up = "../" * page.url.count("/")

    def fix(m):
        target = os.path.normpath(os.path.join(docs_dir, src_dir, m.group(2)))
        if not os.path.relpath(target, docs_dir).startswith(".."):
            if m.group(1) == "](":
                return m.group(0)
            path = m.group(2)
            if path.endswith(".md"):                 # <a href="x.md"> -> x/
                path = path[:-3] + "/"
            return m.group(1) + up + path
        rel = os.path.relpath(target, ROOT)
        kind = "tree" if os.path.isdir(target) else "blob"
        return m.group(1) + f"{REPO}/{kind}/main/{rel}"

    # Leave fenced code alone: a path in a command is not a link.
    parts = re.split(r"(^```.*?^```)", markdown, flags=re.M | re.S)
    return "".join(p if p.startswith("```") else _LINK.sub(fix, p) for p in parts)


def on_post_build(config):
    """The course is copied as-is, so fix its links in the site's copy only:
    "../page.md" becomes the page's URL, and "../../examples/" (outside the
    site) the folder on GitHub. The repository file keeps its GitHub links."""
    path = os.path.join(config["site_dir"], "course", "index.html")
    if not os.path.exists(path):
        return
    with open(path, encoding="utf-8") as f:
        html = f.read()
    html = re.sub(r'href="\.\./([a-z0-9-]+)\.md(#[^"]*)?"',
                  lambda m: f'href="../{m.group(1)}/{m.group(2) or ""}"', html)
    html = re.sub(r'href="\.\./\.\./([^"]*)"',
                  lambda m: f'href="{REPO}/tree/main/{m.group(1)}"', html)
    with open(path, "w", encoding="utf-8") as f:
        f.write(html)
