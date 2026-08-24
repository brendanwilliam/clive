#!/usr/bin/env python3
"""Render the checksum-pinned Clive Homebrew cask for a GitHub Release."""

from __future__ import annotations

import argparse
import re
import sys


VERSION_PATTERN = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[.-][0-9A-Za-z.-]+)?$")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Render the Clive Homebrew cask from verified release metadata."
    )
    parser.add_argument("--version", required=True)
    parser.add_argument("--sha256", required=True)
    return parser.parse_args()


def render(version: str, sha256: str) -> str:
    if not VERSION_PATTERN.fullmatch(version):
        raise ValueError("version must be a semantic version without a v prefix")
    if not SHA256_PATTERN.fullmatch(sha256):
        raise ValueError("sha256 must be a lowercase 64-character hexadecimal digest")

    return f'''cask "clive" do
  version "{version}"
  sha256 "{sha256}"

  url "https://github.com/brendanwilliam/clive/releases/download/v#{{version}}/clive.pkg"
  name "Clive"
  desc "Securely access a Mac terminal from an iPhone"
  homepage "https://github.com/brendanwilliam/clive"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  pkg "clive.pkg"

  uninstall pkgutil: "com.clive.pkg",
            delete: [
              "/Applications/Clive.app",
              "/usr/local/bin/clive",
            ]

  # Keep paired-device state on ordinary uninstall. `brew uninstall --zap` is the
  # explicit opt-in path for removing this user-scoped state.
  zap trash: "~/Library/Application Support/clive"
end
'''


def main() -> int:
    arguments = parse_arguments()
    try:
        sys.stdout.write(render(arguments.version, arguments.sha256))
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
