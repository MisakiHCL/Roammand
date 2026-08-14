#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0

from __future__ import annotations

import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
INLINE_LINK = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
EXTERNAL_PREFIXES = ("http://", "https://", "mailto:", "#")


def tracked_markdown_files() -> list[Path]:
    result = subprocess.run(
        [
            "git",
            "ls-files",
            "-z",
            "--cached",
            "--others",
            "--exclude-standard",
            "*.md",
            "*.MD",
        ],
        cwd=ROOT,
        check=True,
        capture_output=True,
    )
    files = [
        ROOT / raw_path.decode("utf-8")
        for raw_path in result.stdout.split(b"\0")
        if raw_path
    ]
    return [path for path in files if path.is_file()]


def local_target(raw_target: str) -> str | None:
    target = raw_target.strip().split(maxsplit=1)[0].strip("<>")
    if not target or target.startswith(EXTERNAL_PREFIXES):
        return None
    return target.split("#", maxsplit=1)[0]


def main() -> int:
    failures: list[str] = []
    for document in tracked_markdown_files():
        text = document.read_text(encoding="utf-8")
        for match in INLINE_LINK.finditer(text):
            target = local_target(match.group(1))
            if target is None:
                continue
            resolved = (document.parent / target).resolve()
            line = text.count("\n", 0, match.start()) + 1
            try:
                resolved.relative_to(ROOT)
            except ValueError:
                failures.append(
                    f"{document.relative_to(ROOT)}:{line}: link escapes public repository: {target}"
                )
                continue
            if not resolved.exists():
                failures.append(
                    f"{document.relative_to(ROOT)}:{line}: missing local link target: {target}"
                )

    if failures:
        print("\n".join(failures))
        return 1

    print("Markdown links ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
