#!/usr/bin/env python3
"""Check source-export cleanup only inside disposable temporary fixtures."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


EXPORT_SCRIPT = Path(__file__).with_name("export-source.py").read_text()


class SourceExportSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="micduck-export-test-")
        self.base = Path(self.temporary.name).resolve()
        self.project = self.base / "project"
        (self.project / "scripts").mkdir(parents=True)
        (self.project / "dist").mkdir()
        (self.project / "sentinel.txt").write_text("must survive")
        self.script = self.project / "scripts/export-source.py"
        self.script.write_text(EXPORT_SCRIPT)

    def tearDown(self):
        self.temporary.cleanup()

    def test_traversal_is_rejected_before_creating_or_removing_anything(self):
        for suffix in ["dist/new-child/../..", "dist/new-child/../../.."]:
            with self.subTest(suffix=suffix):
                result = subprocess.run(
                    [sys.executable, str(self.script), "--output", str(self.project / suffix)],
                    capture_output=True, text=True,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((self.project / "sentinel.txt").read_text(), "must survive")
                self.assertFalse((self.project / "dist/new-child").exists())

    def test_failed_creation_does_not_remove_another_process_directory(self):
        for name in [
            "Package.swift", "README.md", "LICENSE", "NOTICE", ".gitignore",
            "Resources/Info.plist", "Resources/CodexMicDuck.entitlements",
            "Resources/CodexMicDuckAppIcon.png", "Resources/CodexMicDuckMenuBar.svg",
            "docs/BUILDING.md",
            ".github/workflows/check.yml",
        ]:
            target = self.project / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("fixture")
        output = self.base / "raced-output"
        probe = '''
import pathlib, runpy, sys
script, output = sys.argv[1:3]
original = pathlib.Path.mkdir
def race_mkdir(self, *args, **kwargs):
    if str(self) == output:
        original(self, *args, **kwargs)
        (self / "sentinel.txt").write_text("owned by another process")
        raise FileExistsError("simulated creation race")
    return original(self, *args, **kwargs)
pathlib.Path.mkdir = race_mkdir
sys.argv = [script, "--output", output]
runpy.run_path(script, run_name="__main__")
'''
        result = subprocess.run(
            [sys.executable, "-c", probe, str(self.script), str(output)],
            capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((output / "sentinel.txt").read_text(), "owned by another process")


if __name__ == "__main__":
    unittest.main()
