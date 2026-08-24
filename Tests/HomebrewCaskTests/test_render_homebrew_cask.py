#!/usr/bin/env python3
"""Focused checks for the generated Homebrew cask."""

from __future__ import annotations

import pathlib
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
RENDERER = ROOT / "scripts" / "render-homebrew-cask.py"
CHECKSUM = "3caf9b1fd5432533d4335a76df942d1d6368c453fde1f74f8ef7ccf039f07fd4"


class RenderHomebrewCaskTests(unittest.TestCase):
    def run_renderer(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(RENDERER), *arguments],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_renders_release_url_and_checksum(self) -> None:
        result = self.run_renderer("--version", "1.0.1-beta.1", "--sha256", CHECKSUM)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('version "1.0.1-beta.1"', result.stdout)
        self.assertIn(f'sha256 "{CHECKSUM}"', result.stdout)
        self.assertIn(
            'url "https://github.com/brendanwilliam/clive/releases/download/v#{version}/clive.pkg"',
            result.stdout,
        )
        self.assertIn('depends_on arch: :arm64', result.stdout)
        self.assertIn("depends_on macos: :sonoma", result.stdout)
        self.assertIn('pkgutil: "com.clive.pkg"', result.stdout)
        self.assertIn('zap trash: "~/Library/Application Support/clive"', result.stdout)
        self.assertNotIn("verified:", result.stdout)

    def test_refuses_malformed_release_metadata(self) -> None:
        result = self.run_renderer("--version", "v1.0.1", "--sha256", "not-a-checksum")

        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertIn("error:", result.stderr)


if __name__ == "__main__":
    unittest.main()
