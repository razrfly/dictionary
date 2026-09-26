"""Safety regressions for the historical risk-screen CLI.

Run with: python3 -m unittest discover -s docs/audits/2026-09-26-issue194 -p 'test_screen.py'
"""
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


class ScreenSafetyTest(unittest.TestCase):
    script = Path(__file__).with_name("screen.py")

    def invoke(self, source, rows, summary):
        return subprocess.run(
            [sys.executable, "-O", str(self.script), str(source),
             "--rows", str(rows), "--summary", str(summary)],
            capture_output=True, text=True, check=False,
        )

    def test_output_aliases_are_rejected_before_any_file_changes(self):
        for pair in [(0, 1), (0, 2), (1, 2)]:
            with self.subTest(pair=pair), tempfile.TemporaryDirectory() as directory:
                paths = [Path(directory) / name for name in ("input", "rows", "summary")]
                for path in paths:
                    path.write_text("preserve me")
                paths[pair[1]] = paths[pair[0]]
                result = self.invoke(*paths)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("distinct files", result.stderr)
                self.assertTrue(all(p.read_text() == "preserve me" for p in paths))

    def test_symlink_and_hardlink_aliases_are_rejected(self):
        for kind in ("symlink", "hardlink"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                source = Path(directory) / "input"
                source.write_text("preserve me")
                alias = Path(directory) / "alias"
                if kind == "symlink":
                    alias.symlink_to(source)
                else:
                    os.link(source, alias)
                summary = Path(directory) / "summary"
                result = self.invoke(source, alias, summary)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("distinct files", result.stderr)
                self.assertEqual(source.read_text(), "preserve me")
                self.assertFalse(summary.exists())

    def test_duplicate_ids_are_rejected_with_optimization_enabled(self):
        with tempfile.TemporaryDirectory() as directory:
            source, rows, summary = [Path(directory) / name for name in ("input", "rows", "summary")]
            source.write_text("object_id\n42\n42\n")
            result = self.invoke(source, rows, summary)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("duplicate object_id", result.stderr)
            self.assertFalse(rows.exists())
            self.assertFalse(summary.exists())


if __name__ == "__main__":
    unittest.main()
