import importlib.machinery
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader("release", str(ROOT / "bin/omacosy-aerospace-release"))
spec = importlib.util.spec_from_loader(loader.name, loader)
release = importlib.util.module_from_spec(spec)
loader.exec_module(release)


class ReleaseSafetyTests(unittest.TestCase):
    def test_missing_key_has_no_signing_fallback(self):
        with patch.object(release, "run", return_value=types.SimpleNamespace(stdout="")) as command:
            with self.assertRaisesRegex(ValueError, "unavailable"):
                release.signing_identity("A" * 40)
            self.assertEqual(command.call_count, 1)
            self.assertEqual(command.call_args.args[0][0], "security")

    def test_existing_release_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)
            (target / "unique").write_text("keep")
            with self.assertRaisesRegex(ValueError, "already exists"):
                release.build(types.SimpleNamespace(output=target))
            self.assertEqual((target / "unique").read_text(), "keep")

    def test_cli_version_mismatch_preserves_installed_cli(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cli = root / "aerospace"
            cli.write_text("original")
            args = types.SimpleNamespace(release=root, app=root / "AeroSpace.app", cli=cli)
            with patch.object(release, "verify_release", return_value={"signing_identity": "A" * 40, "version": "new"}), \
                 patch.object(release, "verify_signature"), \
                 patch.object(release, "app_version", return_value="old"):
                with self.assertRaisesRegex(ValueError, "versions differ"):
                    release.install_cli(args)
            self.assertEqual(cli.read_text(), "original")

    def test_protection_refuses_implicit_certificate_rotation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / ".config/omacosy/aerospace-managed.json"
            marker.parent.mkdir(parents=True)
            marker.write_text(json.dumps({"signing_identity": "A" * 40}))
            before = marker.read_bytes()
            with patch.object(release.Path, "home", return_value=root), \
                 patch.object(release, "signing_identity", return_value="B" * 40), \
                 patch.object(release, "verify_signature"), \
                 patch.object(release, "app_version", return_value="version"), \
                 patch.object(release, "executable", return_value=marker):
                with self.assertRaisesRegex(ValueError, "rotation"):
                    release.protect(types.SimpleNamespace(identity=None, app=Path("/Applications/AeroSpace.app")))
            self.assertEqual(marker.read_bytes(), before)

    def test_cli_corruption_is_rejected_before_install(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "app-binary"
            binary.write_text("signed application")
            cli = root / "aerospace"
            cli.write_text("original CLI")
            metadata = {"signing_identity": "A" * 40, "app_sha256": release.digest(binary),
                        "cli_sha256": release.digest(cli), "version": "version"}
            (root / "release.json").write_text(json.dumps(metadata))
            cli.write_text("corrupted CLI")
            with patch.object(release, "verify_signature"), patch.object(release, "executable", return_value=binary):
                with self.assertRaisesRegex(ValueError, "CLI does not match"):
                    release.verify_release(root)

    def test_brewfile_preserves_only_existing_managed_app(self):
        for marker, app, expected in [(True, True, False), (False, True, True), (True, False, True)]:
            script = """
            require 'json'
            $casks = []
            def cask(name, *); $casks << name; end
            def brew(*); end
            def tap(*); end
            def mas(*); end
            def vscode(*); end
            File.define_singleton_method(:file?) { |p| p.end_with?('aerospace-managed.json') && MARKER }
            File.define_singleton_method(:directory?) { |p| p == '/Applications/AeroSpace.app' && APP }
            eval(File.read(ARGV[0]), TOPLEVEL_BINDING, ARGV[0])
            puts JSON.generate($casks)
            """.replace("MARKER", str(marker).lower()).replace("APP", str(app).lower())
            result = subprocess.run(["ruby", "-e", script, str(ROOT / "Brewfile")],
                                    text=True, capture_output=True, check=True)
            self.assertEqual("aerospace" in json.loads(result.stdout), expected)


if __name__ == "__main__":
    unittest.main()
