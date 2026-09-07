"""Offline Docker release download, bundle, and upgrade checks."""
import hashlib
import io
import json
import os
from pathlib import Path
import runpy
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
Base = runpy.run_path(str(ROOT / 'scripts/test-github-install.py'))['GitHubInstallerTests']


class DockerDownloadTests(Base):
    def make_bundle(self, unsafe=False):
        self.asset = f'PocketIMG-{self.version}-docker-install.tar.gz'
        with tarfile.open(self.directory / self.asset, 'w:gz') as bundle:
            for name in ('compose.yaml', 'scripts/install-docker.sh', 'scripts/deploy-docker.py'):
                info = tarfile.TarInfo(name)
                content = b'fixture only\n'
                info.size = len(content)
                if unsafe and name == 'compose.yaml':
                    info.type, info.linkname, info.size = tarfile.SYMTYPE, '/etc/passwd', 0
                bundle.addfile(info, io.BytesIO(content))
        digest = hashlib.sha256((self.directory / self.asset).read_bytes()).hexdigest()
        (self.directory / (self.asset + '.sha256')).write_text(f'{digest}  {self.asset}\n')

    def release(self, tag, assets=True, **flags):
        result = super().release(tag, assets, **flags)
        for asset in result['assets']:
            asset['name'] = asset['name'].replace('linux-amd64', 'docker')
        return result

    def run_installer(self, *args):
        return super().run_installer('--docker', *args)

    def test_selects_latest_compatible_server_and_extracts(self):
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.directory / 'download/compose.yaml').is_file())
        self.assertFalse((self.directory / 'download/pocketimg').exists())


class BundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='pocketimg-docker-test-')
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.source, self.target = self.directory / 'source', self.directory / 'target'
        self.source.mkdir()
        self.digest = 'sha256:' + 'a' * 64
        subprocess.run(['bash', str(ROOT / 'scripts/package-docker-installer.sh'), '0.10.0', self.digest, str(self.directory)], check=True)
        with tarfile.open(self.directory / 'PocketIMG-0.10.0-docker-install.tar.gz') as bundle:
            bundle.extractall(self.source, filter='data')
        tools = self.directory / 'bin'
        tools.mkdir()
        docker = tools / 'docker'
        docker.write_text('''#!/usr/bin/env bash
echo "$*" >> "$DOCKER_CALLS"
case "$*" in
  'compose config --environment') if [[ -n ${PIH_PORT:-} ]]; then echo "PIH_PORT=$PIH_PORT"; fi ;;
  'compose ps --all --quiet pocketimg') echo existing ;;
  inspect*) echo 19876 ;;
  'compose run '*) echo 'fixture token' ;;
  'compose build '*) exit 99 ;;
esac
''')
        docker.chmod(0o755)
        self.calls = self.directory / 'calls'
        self.env = dict(os.environ, PATH=f'{tools}:{os.environ["PATH"]}', DOCKER_CALLS=str(self.calls))
        for name in ('PIH_IMAGE', 'PIH_PORT', 'PIH_INSTALL_PULL', 'PIH_INSTALL_QUIET'):
            self.env.pop(name, None)

    def deploy(self, port=''):
        return subprocess.run(['python3', str(self.source / 'scripts/deploy-docker.py'), str(self.source), str(self.target), port], env=self.env, capture_output=True, text=True)

    def test_bundle_pins_digest_without_build_context(self):
        compose = (self.source / 'compose.yaml').read_text()
        self.assertIn(self.digest, compose)
        self.assertNotIn('build:', compose)
        self.assertNotIn('context:', compose)

    def test_install_and_repeat_preserve_config_and_port(self):
        first = self.deploy()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertIn('19876', first.stdout)
        (self.target / '.env').write_text('PIH_COOKIE_SECURE=true\n')
        second = self.deploy()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual((self.target / '.env').read_text(), 'PIH_COOKIE_SECURE=true\n')
        self.assertIn('compose pull pocketimg', self.calls.read_text())
        self.assertNotIn('compose build', self.calls.read_text())

    def test_custom_port(self):
        result = self.deploy('23456')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('23456', result.stdout)

    def test_refuses_unmanaged_directory(self):
        self.target.mkdir()
        (self.target / 'keep').write_text('keep')
        self.assertNotEqual(self.deploy().returncode, 0)
        self.assertEqual((self.target / 'keep').read_text(), 'keep')

    def test_refuses_edited_compose(self):
        self.assertEqual(self.deploy().returncode, 0)
        (self.target / 'compose.yaml').write_text('user config')
        self.assertNotEqual(self.deploy().returncode, 0)
        self.assertEqual((self.target / 'compose.yaml').read_text(), 'user config')

    def test_refuses_symlink(self):
        self.target.symlink_to(self.source, target_is_directory=True)
        self.assertNotEqual(self.deploy().returncode, 0)


if __name__ == '__main__':
    # Do not collect the imported Linux fixture class a second time.
    del Base
    unittest.main()
