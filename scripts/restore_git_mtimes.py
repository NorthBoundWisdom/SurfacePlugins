#!/usr/bin/env python3
"""Set every tracked file's mtime to the time of the last commit that changed it.

A fresh checkout stamps all files with the checkout time, and SwiftPM treats any changed mtime as
a changed input, so a restored build cache would be recompiled in full. With commit times, files
untouched since the cached build keep their recorded mtime and only changed files rebuild.
Requires full history (`fetch-depth: 0`); a shallow clone would give every file the same time.
"""

import os
import subprocess
import sys
from pathlib import Path


def git(*arguments: str) -> str:
    return subprocess.run(
        ["git", "-c", "core.quotePath=false", *arguments], check=True, capture_output=True, text=True
    ).stdout


def main() -> int:
    root = Path(git("rev-parse", "--show-toplevel").strip())
    if git("rev-parse", "--is-shallow-repository").strip() == "true":
        print("restore_git_mtimes: shallow clone; fetch full history first", file=sys.stderr)
        return 1
    pending = set(git("ls-files").splitlines())
    stamp = None
    restored = 0
    # Newest first: the first commit that names a path is its last change.
    for line in git("log", "--format=@%ct", "--name-only", "--no-renames", "HEAD").splitlines():
        if line.startswith("@"):
            stamp = int(line[1:])
        elif line in pending:
            pending.discard(line)
            path = root / line
            if path.is_file() and not path.is_symlink():
                os.utime(path, (stamp, stamp))
                restored += 1
            if not pending:
                break
    print(f"restore_git_mtimes: {restored} files set to their last commit time", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
