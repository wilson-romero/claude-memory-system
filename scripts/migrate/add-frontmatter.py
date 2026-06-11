#!/usr/bin/env python3
"""Add the standard frontmatter to vault markdown files that lack it.

Idempotent: files that already start with '---' are left untouched.
Type is inferred from directory / filename prefix; created date from mtime.

Usage: add-frontmatter.py <machine-name> <dir> [<dir> ...]
"""
import os
import sys
from datetime import datetime

PREFIX_TYPES = {
    "feedback_": "feedback",
    "project_": "project",
    "reference_": "reference",
    "user_": "user",
}
DIR_TYPES = {
    "Lecciones": "lesson",
    "daily": "daily",
    "Memoria": "curated",
    "Suenos": "reference",
    "Archivo": "curated",
}


def infer_type(path: str) -> str:
    base = os.path.basename(path)
    for prefix, t in PREFIX_TYPES.items():
        if base.startswith(prefix):
            return t
    for part in path.split(os.sep):
        if part in DIR_TYPES:
            return DIR_TYPES[part]
    return "reference"


def process(path: str, machine: str) -> bool:
    with open(path, encoding="utf-8", errors="replace") as f:
        content = f.read()
    if content.lstrip().startswith("---"):
        return False
    created = datetime.fromtimestamp(os.path.getmtime(path)).strftime("%Y-%m-%d")
    fm = (
        "---\n"
        f"type: {infer_type(path)}\n"
        f"machine: {machine}\n"
        f"created: {created}\n"
        f"updated: {created}\n"
        "tags: []\n"
        "---\n\n"
    )
    tmp = path + ".tmp-fm"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(fm + content)
    os.replace(tmp, path)
    return True


def main() -> None:
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    machine = sys.argv[1]
    changed = 0
    skipped = 0
    for d in sys.argv[2:]:
        if not os.path.isdir(d):
            continue
        for root, dirs, files in os.walk(d):
            dirs[:] = [x for x in dirs if not x.startswith(".")]
            for fn in files:
                if not fn.endswith(".md"):
                    continue
                if process(os.path.join(root, fn), machine):
                    changed += 1
                else:
                    skipped += 1
    print(f"frontmatter: {changed} added, {skipped} already had it")


if __name__ == "__main__":
    main()
