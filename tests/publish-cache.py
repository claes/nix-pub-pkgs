#!/usr/bin/env python3
"""Test publishing without AWS: redirect only the test copy command to a file cache."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parents[1]


class PublishTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="publish-tests-")
        cls.addClassCleanup(cls.tmp.cleanup)
        cls.root = Path(cls.tmp.name)
        cls.real_nix = shutil.which("nix")
        # Small real multi-output package with an independent runtime reference.
        expr = '''let
          f = builtins.getFlake (toString ./.);
          pkgs = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
          dep = pkgs.runCommand "publish-test-dependency" {} "mkdir -p $out";
        in pkgs.runCommand "publish-test-package" {
          outputs = [ "out" "doc" ];
        } "mkdir -p $out $doc; echo ${dep} > $out/reference; echo docs > $doc/readme"
        '''
        result = subprocess.check_output(
            [cls.real_nix, "build", "--impure", "--json", "--no-link", "--expr", expr],
            cwd=ROOT, text=True,
        )
        built = json.loads(result)[0]
        # Request the nondefault doc output explicitly as well.
        all_outputs = json.loads(subprocess.check_output(
            [cls.real_nix, "build", "--no-link", "--json", built["drvPath"] + "^*"], text=True))
        cls.paths = sorted(all_outputs[0]["outputs"].values())
        cls.manifest = cls.root / "paths"
        cls.manifest.write_text("".join(p + "\n" for p in cls.paths))
        subprocess.run(["nix-store", "--generate-binary-cache-key", "local-publish-test-1",
                        str(cls.root / "private"), str(cls.root / "public")], check=True)
        cls.private = (cls.root / "private").read_text().strip()
        cls.public = (cls.root / "public").read_text().strip()
        cls.bin = cls.root / "bin"
        cls.bin.mkdir()
        # Production script remains AWS-only. The test shim preserves the signing
        # parameter and executes real native Nix file-cache copying, never AWS.
        wrapper = cls.bin / "nix"
        wrapper.write_text('''#!/usr/bin/env python3
import json, os, stat, sys
from pathlib import Path
from urllib.parse import parse_qs, urlsplit
args = sys.argv[1:]
if args[0] == "copy":
    index = args.index("--to") + 1
    url = urlsplit(args[index])
    query = parse_qs(url.query)
    key = Path(query["secret-key"][0])
    assert key.read_text().strip() == os.environ["TEST_PRIVATE"]
    assert "NIX_CACHE_SIGNING_KEY" not in os.environ
    Path(os.environ["TEST_RECORD"]).write_text(json.dumps({
        "url": args[index], "mode": stat.S_IMODE(key.stat().st_mode), "key": str(key),
        "paths": args[index + 1:],
    }))
    if os.environ.get("TEST_FAIL"):
        sys.exit(24)
    args[index] = Path(os.environ["TEST_CACHE"]).as_uri() + "?secret-key=" + query["secret-key"][0]
os.execv(os.environ["REAL_NIX"], [os.environ["REAL_NIX"], *args])
''')
        wrapper.chmod(0o755)

    def run_publish(self, **overrides):
        env = {**os.environ, "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
               "AWS_ACCESS_KEY_ID": "test-id", "AWS_SECRET_ACCESS_KEY": "test-secret",
               "AWS_REGION": "eu-north-1", "S3_BUCKET": "local-test-bucket",
               "NIX_CACHE_SIGNING_KEY": self.private, "OUTPUTS_FILE": str(self.manifest),
               "REAL_NIX": self.real_nix, "TEST_PRIVATE": self.private,
               "TEST_RECORD": str(self.root / "record"), "TEST_CACHE": str(self.root / "cache"),
               **overrides}
        return subprocess.run(["bash", "-x", str(ROOT / "scripts/publish-cache.sh")],
                              cwd="/tmp", env=env, text=True, capture_output=True)

    def test_signed_cache_closure_repeated_copy_and_isolated_restore(self):
        for _ in range(2):
            result = self.run_publish()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn(self.private, result.stdout + result.stderr)
            record = json.loads((self.root / "record").read_text())
            self.assertEqual(record["mode"], 0o600)
            self.assertFalse(Path(record["key"]).exists())
            url = urlsplit(record["url"])
            self.assertEqual(url.scheme, "s3")
            self.assertEqual(url.netloc, "local-test-bucket")
            self.assertEqual(parse_qs(url.query)["region"], ["eu-north-1"])
            self.assertEqual(parse_qs(url.query)["multipart-upload"], ["true"])
            self.assertEqual(record["paths"], self.paths)
        cache = self.root / "cache"
        self.assertTrue((cache / "nix-cache-info").exists())
        closure = subprocess.check_output([self.real_nix, "path-info", "--recursive", *self.paths], text=True).splitlines()
        self.assertGreater(len(closure), len(self.paths))
        for path in closure:
            narinfo = (cache / (Path(path).name.split("-")[0] + ".narinfo")).read_text()
            self.assertIn("Sig: local-publish-test-1:", narinfo)
            nar = next(line[5:] for line in narinfo.splitlines() if line.startswith("URL: "))
            self.assertTrue((cache / nar).is_file())
        store = "local?root=" + str(self.root / "isolated")
        subprocess.run([self.real_nix, "copy", "--from", cache.as_uri(), "--to", store,
                        "--option", "trusted-public-keys", self.public, *self.paths], check=True)
        subprocess.run([self.real_nix, "store", "verify", "--store", store, "--all",
                        "--sigs-needed", "1", "--option", "trusted-public-keys", self.public], check=True)

    def test_copy_failure_cleans_key_and_hides_secret(self):
        result = self.run_publish(TEST_FAIL="1")
        self.assertEqual(result.returncode, 24)
        record = json.loads((self.root / "record").read_text())
        self.assertFalse(Path(record["key"]).exists())
        self.assertNotIn(self.private, result.stdout + result.stderr)

    def test_missing_configuration_and_manifest(self):
        for name in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_REGION", "S3_BUCKET", "NIX_CACHE_SIGNING_KEY"):
            result = self.run_publish(**{name: ""})
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(name, result.stderr)
        self.assertNotEqual(self.run_publish(OUTPUTS_FILE=str(self.root / "absent")).returncode, 0)
        self.assertNotEqual(self.run_publish(S3_BUCKET="bucket?endpoint=other").returncode, 0)

    def test_empty_and_invalid_manifest(self):
        manifest = self.root / "empty"
        manifest.touch()
        self.assertEqual(self.run_publish(OUTPUTS_FILE=str(manifest)).returncode, 0)
        manifest.write_text("not-a-store-path\n")
        self.assertNotEqual(self.run_publish(OUTPUTS_FILE=str(manifest)).returncode, 0)


if __name__ == "__main__":
    unittest.main()
