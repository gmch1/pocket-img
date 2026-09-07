"""Exercise the public installer with an offline GitHub response/asset fixture."""
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class GitHubInstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pocketimg-github-test-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.version = "0.10.0"
        self.asset = f"PocketIMG-{self.version}-linux-amd64-install.tar.gz"
        self.make_bundle()
        releases = [
            self.release("macos-v9.0.0"),
            self.release("server-v0.9.0"),
            self.release("server-v0.11.0", assets=False),
            self.release("server-v0.12.0", prerelease=True),
            self.release("server-v0.13.0", draft=True),
            self.release("server-v0.10.0"),
        ]
        (self.directory / "releases.json").write_text(json.dumps(releases))
        tools = self.directory / "bin"
        tools.mkdir()
        curl = tools / "curl"
        curl.write_text("""#!/usr/bin/env python3
import os, pathlib, shutil, sys
args = sys.argv[1:]
url = next(a for a in args if a.startswith('https://'))
destination = pathlib.Path(args[args.index('-o') + 1])
fixture = pathlib.Path(os.environ['INSTALL_FIXTURE'])
if url.startswith('https://api.github.com/repos/gmch1/pocket-img/releases?'):
    source = fixture / 'releases.json'
else:
    assert '/server-v0.10.0/' in url, 'Wrong component or version selected'
    source = fixture / url.rsplit('/', 1)[1]
shutil.copyfile(source, destination)
""")
        curl.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}", INSTALL_FIXTURE=str(self.directory))

    def release(self, tag, assets=True, **flags):
        asset = f"PocketIMG-{tag.removeprefix('server-v')}-linux-amd64-install.tar.gz"
        return dict(tag_name=tag, assets=[dict(name=asset), dict(name=asset + ".sha256")] if assets else [], **flags)

    def make_bundle(self, unsafe=False):
        with tarfile.open(self.directory / self.asset, "w:gz") as bundle:
            for name in ("pocketimg", "scripts/install-linux.sh", "deploy/linux/pocketimg.service"):
                info = tarfile.TarInfo(name)
                content = b"fixture only\n"
                info.size = len(content)
                if unsafe and name == "pocketimg":
                    info.type = tarfile.SYMTYPE
                    info.linkname = "/etc/passwd"
                    info.size = 0
                bundle.addfile(info, io.BytesIO(content))
        digest = hashlib.sha256((self.directory / self.asset).read_bytes()).hexdigest()
        (self.directory / (self.asset + ".sha256")).write_text(f"{digest}  {self.asset}\n")

    def run_installer(self, *args):
        return subprocess.run(
            ["bash", str(ROOT / "install.sh"), "--download-only", str(self.directory / "download"), *args],
            env=self.env, text=True, capture_output=True, timeout=20,
        )

    def test_selects_latest_compatible_server_and_extracts(self):
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("0.10.0", result.stdout)
        self.assertTrue((self.directory / "download/scripts/install-linux.sh").is_file())
        self.assertTrue(os.access(self.directory / "download/pocketimg", os.X_OK))

    def test_pinned_version(self):
        result = self.run_installer("--version", "server-v0.10.0")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_checksum_mismatch_never_extracts(self):
        (self.directory / self.asset).write_bytes(b"corrupt")
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA-256", result.stderr)
        self.assertFalse((self.directory / "download").exists())

    def test_rejects_unsafe_archive(self):
        self.make_bundle(unsafe=True)
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("结构异常", result.stderr)
        self.assertFalse((self.directory / "download").exists())

    def test_no_compatible_release(self):
        (self.directory / "releases.json").write_text(json.dumps([self.release("server-v0.5.2", assets=False)]))
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("尚无支持一键安装", result.stderr)

    def test_rejects_invalid_version(self):
        result = self.run_installer("--version", "../main")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("版本格式", result.stderr)

    def test_accepts_custom_port(self):
        result = self.run_installer("--port", "19876")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_invalid_ports(self):
        for port in ("0", "80", "65536", "abc", "-1", "12345678901234567890"):
            with self.subTest(port=port):
                result = self.run_installer("--port", port)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("端口必须", result.stderr)

    def test_does_not_overwrite_download_directory(self):
        target = self.directory / "download"
        target.mkdir()
        (target / "keep").write_text("existing")
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((target / "keep").read_text(), "existing")


if __name__ == "__main__":
    unittest.main()
