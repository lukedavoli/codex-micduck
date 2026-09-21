#!/usr/bin/env python3
"""Export a reviewable public source tree without local builds or planning files."""

import argparse
from pathlib import Path
import shutil
import subprocess
import sys


ROOT_FILES = ("Package.swift", "README.md", "LICENSE", "NOTICE", ".gitignore")
RESOURCE_FILES = (
    "Info.plist", "CodexMicDuck.entitlements", "CodexMicDuckAppIcon.png",
    "CodexMicDuckMenuBar.svg",
)
TREE_EXTENSIONS = {
    "Sources": {".swift"},
    "Tests": {".swift"},
    "scripts": {".sh", ".py"},
    "website": {".html", ".css", ".js", ".json", ".svg", ".png", ".ico", ".txt", ".md"},
}
EXCLUDED_DIRS = {"node_modules", "screenshots", "review", "test-results", "playwright-report", "__pycache__"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    project = Path(__file__).resolve().parent.parent
    # Resolve traversal and symlinked parents before any containment or cleanup decision.
    output = args.output.expanduser().resolve()
    if output.exists() or output.is_symlink():
        parser.error("output must be a new directory")
    if output.is_relative_to(project) and not output.is_relative_to(project / "dist"):
        parser.error("export outside the project or under dist/")

    files = [project / name for name in ROOT_FILES]
    files += [project / "Resources" / name for name in RESOURCE_FILES]
    files += [project / "docs" / "BUILDING.md"]
    files += [project / ".github" / "workflows" / "check.yml"]
    for folder, extensions in TREE_EXTENSIONS.items():
        tree = project / folder
        if not tree.exists():
            continue
        for path in sorted(tree.rglob("*")):
            relative = path.relative_to(tree)
            if any(part.startswith(".") or part in EXCLUDED_DIRS for part in relative.parts):
                continue
            if path.is_symlink():
                parser.error(f"symlinks are not permitted in public source: {path.relative_to(project)}")
            if path.is_file() and path.suffix in extensions:
                files.append(path)
    for source in files:
        if not source.is_file() or source.is_symlink():
            parser.error(f"required source is missing or linked: {source.relative_to(project)}")

    created_output = False
    try:
        output.mkdir(parents=True, exist_ok=False)
        created_output = True
        for source in files:
            target = output / source.relative_to(project)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
            target.chmod(0o755 if source.parent.name == "scripts" else 0o644)
        if sys.platform == "darwin":
            subprocess.run(["xattr", "-cr", str(output)], check=True)
        subprocess.run([sys.executable, str(project / "scripts/verify-public-files.py"), str(output)], check=True)
    except (OSError, subprocess.CalledProcessError):
        # This directory was created by this invocation and contains only copies.
        if created_output:
            shutil.rmtree(output)
        print("Source export failed; no completed export was produced.", file=sys.stderr)
        return 1
    print(f"Exported {len(files)} public files to {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
