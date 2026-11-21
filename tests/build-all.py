#!/usr/bin/env python3
"""Integration tests using isolated flake copies and small real Nix builds."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BuildAllTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="build-all-tests-")
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        for name in ("flake.nix", "flake.lock"):
            shutil.copy(ROOT / name, self.repo / name)
        (self.repo / "packages").mkdir()
        (self.repo / "scripts").mkdir()
        shutil.copy(ROOT / "scripts/build-all.sh", self.repo / "scripts/build-all.sh")
        self.manifest = self.repo / ".build/store-paths"

    def package(self, name, expression):
        directory = self.repo / "packages" / name
        directory.mkdir()
        (directory / "package.nix").write_text(expression)

    def build(self, **env):
        # Run outside the repo to exercise script-relative root resolution.
        return subprocess.run(
            [str(self.repo / "scripts/build-all.sh")], cwd="/tmp",
            env={**os.environ, "SYSTEM": "x86_64-linux", "OUTPUTS_FILE": ".build/store-paths", **env},
            text=True, capture_output=True,
        )

    def test_discovery_all_outputs_and_repeated_execution(self):
        self.package("two-outputs", '''{ runCommand }: runCommand "build-all-two-outputs" {
          outputs = [ "out" "dev" ];
          meta.outputsToInstall = [ "out" ];
        } "mkdir -p $out $dev; echo runtime > $out/runtime; echo headers > $dev/headers"
        ''')
        # Nonpackages must not be imported.
        (self.repo / "packages/ignored.nix").write_text("invalid Nix")
        (self.repo / "packages/support").mkdir()
        first = self.build()
        self.assertEqual(first.returncode, 0, first.stderr)
        paths = self.manifest.read_text().splitlines()
        self.assertEqual(len(paths), 2)
        self.assertEqual(first.stdout.splitlines(), paths)
        self.assertTrue(all(Path(p).is_dir() for p in paths))
        self.assertTrue(any((Path(p) / "headers").exists() for p in paths))
        second = self.build()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(second.stdout, first.stdout)
        self.package("new-tool", '{ runCommand }: runCommand "build-all-new-tool" {} "mkdir -p $out"')
        added = self.build()
        self.assertEqual(added.returncode, 0, added.stderr)
        self.assertEqual(len(added.stdout.splitlines()), 3)
        shutil.rmtree(self.repo / "packages/new-tool")
        removed = self.build()
        self.assertEqual(removed.returncode, 0, removed.stderr)
        self.assertEqual(removed.stdout, first.stdout)

    def test_empty_and_unsupported_system(self):
        empty = self.build()
        self.assertEqual(empty.returncode, 0, empty.stderr)
        self.assertEqual(self.manifest.read_text(), "")
        self.manifest.write_text("stale\n")
        unsupported = self.build(SYSTEM="unsupported-linux")
        self.assertNotEqual(unsupported.returncode, 0)
        self.assertFalse(self.manifest.exists())

    def test_custom_manifest_path(self):
        manifest = self.repo / "custom output" / "paths"
        result = self.build(OUTPUTS_FILE=str(manifest))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(manifest.read_text(), "")
        self.assertFalse(self.manifest.exists())

    def test_failure_invalidates_manifest_and_cleans_temporary_files(self):
        self.package("broken", '{ runCommand }: runCommand "build-all-broken" {} "exit 1"')
        self.manifest.parent.mkdir()
        self.manifest.write_text("stale\n")
        failed = self.build()
        self.assertNotEqual(failed.returncode, 0)
        self.assertFalse(self.manifest.exists())
        self.assertEqual(list(self.manifest.parent.glob(".build-all.*")), [])
        (self.repo / "packages/broken/package.nix").write_text("invalid Nix")
        self.assertNotEqual(self.build().returncode, 0)
        self.assertFalse(self.manifest.exists())


if __name__ == "__main__":
    unittest.main()
