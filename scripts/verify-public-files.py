#!/usr/bin/env python3
"""Fail a public-source or app scan without printing matched private values."""

import argparse
from pathlib import Path
import re
import subprocess
import sys


PATTERNS = {
    "developer home path": re.compile(rb"/(?:Users|home)/[^/\x00\r\n\s]+/"),
    "private temporary build path": re.compile(rb"/private/var/" rb"folders/[^\x00\r\n\s]+"),
    "private key": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"),
    "GitHub access token": re.compile(rb"(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,})"),
    "AWS access key": re.compile(rb"(?:AKIA|ASIA)[A-Z0-9]{16}"),
    "API secret": re.compile(rb"sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{32,}"),
}


def verify(directory: Path, allow_applications_link: bool = False) -> list[str]:
    problems = []
    paths = [directory] + (sorted(directory.rglob("*")) if directory.is_dir() else [])
    for path in paths:
        relative = path.relative_to(directory) if directory.is_dir() else Path(path.name)
        if path.is_symlink():
            if allow_applications_link and relative == Path("Applications") and path.resolve() == Path("/Applications"):
                continue
            # Bundled symlinks must not escape the inspected directory.
            if not path.resolve().is_relative_to(directory.resolve()):
                problems.append(f"{relative}: external symlink")
            continue
        if sys.platform == "darwin":
            names = subprocess.check_output(["xattr", str(path)], text=True).splitlines()
            for name in names:
                encoded = subprocess.check_output(["xattr", "-px", name, str(path)], text=True)
                value = bytes.fromhex(encoded)
                for label, pattern in PATTERNS.items():
                    if pattern.search(value):
                        problems.append(f"{relative}: {label} in extended metadata")
        if not path.is_file():
            continue
        if path.name == ".DS_Store" or path.name.startswith("._"):
            problems.append(f"{relative}: macOS metadata file")
        data = path.read_bytes()
        for label, pattern in PATTERNS.items():
            if pattern.search(data):
                problems.append(f"{relative}: {label}")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path)
    parser.add_argument("--dmg-root", action="store_true", help="allow the DMG's Applications shortcut")
    args = parser.parse_args()
    if not args.path.exists() or args.path.is_symlink():
        parser.error("provide an existing file or directory, not a symlink")
    problems = verify(args.path, allow_applications_link=args.dmg_root)
    if problems:
        print("Public-file scan failed (matched values omitted):", file=sys.stderr)
        for problem in problems:
            print(f"- {problem}", file=sys.stderr)
        return 1
    print("Public-file scan passed: no private paths or common credential markers found.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
