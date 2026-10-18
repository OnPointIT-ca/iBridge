"""Installer tests exercise user-state preservation and shell-free launch paths."""

import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("macos_installer", ROOT / "scripts/install_macos.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class MacInstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ibridge test ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.state = self.root / "Library/Application Support/iBridge"
        self.app = self.root / "Applications/My iBridge.app"
        self.agents = self.root / "Library/LaunchAgents"
        self.node = self.root / "node with spaces/bin/node"
        self.source = self.root / "source/iBridge.app"
        (self.source / "Contents/MacOS").mkdir(parents=True)
        (self.source / "Contents/MacOS/iBridgeHost").write_text("native binary fixture")
        (self.source / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": installer.BUNDLE_ID}))
        self.runtime = self.root / "source/runtime"
        (self.runtime / "gateway/dist").mkdir(parents=True)
        (self.runtime / "gateway/dist/cli.js").write_text("gateway fixture")
        (self.runtime / "shared").mkdir()
        (self.runtime / "shared/operations.json").write_text("{}")
        self.commands = []

    def run_command(self, command, **kwargs):
        self.commands.append((command, kwargs))
        # No pre-existing launchd service is loaded in this fixture.
        code = 1 if command[1:2] == ["print"] else 0
        return subprocess.CompletedProcess(command, code)

    def install(self, **kwargs):
        return installer.install_prepared(self.source, self.runtime, self.state,
                                          self.app, self.agents, self.node,
                                          runner=self.run_command, **kwargs)

    def test_install_preserves_state_and_passes_spaced_paths_as_single_arguments(self):
        self.state.mkdir(parents=True)
        records = {"gateway.sqlite": b"existing clients and journal", "bookmarks.json": b"bookmarks",
                   "config.json": b"personal settings", "secret.txt": b"personal token"}
        for filename, payload in records.items():
            (self.state / filename).write_bytes(payload)
        receipt = self.install()
        for filename, payload in records.items():
            self.assertEqual((self.state / filename).read_bytes(), payload)
        for label in installer.LABELS:
            with (self.agents / (label + ".plist")).open("rb") as handle:
                document = plistlib.load(handle)
            self.assertEqual(document["EnvironmentVariables"]["IBRIDGE_HOME"], str(self.state))
            self.assertIs(document["RunAtLoad"], True)
            self.assertIs(document["KeepAlive"], True)
            self.assertEqual(document["Umask"], 0o077)
        host = plistlib.loads((self.agents / (installer.LABELS[0] + ".plist")).read_bytes())
        gateway = plistlib.loads((self.agents / (installer.LABELS[1] + ".plist")).read_bytes())
        self.assertEqual(host["ProgramArguments"], [str(self.app / "Contents/MacOS/iBridgeHost"), "--serve"])
        self.assertEqual(gateway["ProgramArguments"][0], str(self.node))
        self.assertEqual(gateway["ProgramArguments"][1], str(Path(receipt["runtime"]) / "gateway/dist/cli.js"))
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.state / "installation.json").stat().st_mode & 0o777, 0o600)
        self.assertTrue(all(isinstance(command, list) and not kwargs.get("shell") for command, kwargs in self.commands))
        self.assertEqual(len([command for command, _ in self.commands if "bootstrap" in command]), 2)

    def test_reinstallation_retains_journal_and_uses_new_runtime_directory(self):
        first = self.install(start=False)
        (self.state / "gateway.sqlite").write_bytes(b"keep this write journal")
        (self.source / "Contents/MacOS/iBridgeHost").write_text("updated native binary fixture")
        second = self.install(start=False)
        self.assertNotEqual(first["runtime"], second["runtime"])
        self.assertTrue(Path(first["runtime"]).is_dir())
        self.assertEqual((self.state / "gateway.sqlite").read_bytes(), b"keep this write journal")
        self.assertEqual((self.app / "Contents/MacOS/iBridgeHost").read_text(), "updated native binary fixture")
        self.assertFalse(any("bootstrap" in command for command, _ in self.commands))

    def test_gateway_host_and_port_settings_survive_upgrade(self):
        settings = {"IBRIDGE_ALLOWED_HOSTS": "localhost:21421,mac.example.ts.net", "IBRIDGE_PORT": "21421"}
        self.install(start=False, gateway_environment=settings)
        self.install(start=False)
        document = plistlib.loads((self.agents / (installer.LABELS[1] + ".plist")).read_bytes())
        self.assertEqual(document["EnvironmentVariables"], dict(settings, IBRIDGE_HOME=str(self.state)))
        host = plistlib.loads((self.agents / (installer.LABELS[0] + ".plist")).read_bytes())
        self.assertEqual(host["EnvironmentVariables"], {"IBRIDGE_HOME": str(self.state)})

    def test_refuses_unrelated_existing_app_before_changes(self):
        (self.app / "Contents").mkdir(parents=True)
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "other.app"}))
        with self.assertRaises(ValueError):
            self.install()
        self.assertFalse(self.state.exists())
        self.assertFalse(self.commands)

    def test_refuses_launch_agent_pointing_to_another_state_directory(self):
        self.agents.mkdir(parents=True)
        existing = self.agents / (installer.LABELS[0] + ".plist")
        payload = plistlib.dumps({"Label": installer.LABELS[0], "EnvironmentVariables": {"IBRIDGE_HOME": "/other"}})
        existing.write_bytes(payload)
        with self.assertRaises(ValueError):
            self.install()
        self.assertEqual(existing.read_bytes(), payload)
        self.assertFalse(self.state.exists())

    def test_refuses_destination_and_parent_symlinks(self):
        outside = self.root / "outside"
        outside.mkdir()
        self.state.parent.mkdir(parents=True)
        self.state.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.install()
        self.assertFalse(any(outside.iterdir()))
        self.state.unlink()
        self.app.parent.parent.mkdir(parents=True, exist_ok=True)
        self.app.parent.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.install()

    def test_only_exact_loaded_labels_are_stopped(self):
        def loaded(command, **kwargs):
            self.commands.append((command, kwargs))
            return subprocess.CompletedProcess(command, 0)
        installer.install_prepared(self.source, self.runtime, self.state, self.app,
                                   self.agents, self.node, start=False, runner=loaded)
        commands = [command for command, _ in self.commands if "bootout" in command]
        self.assertEqual(len(commands), 2)
        self.assertTrue(all(command[2].endswith(tuple(installer.LABELS)) for command in commands))
        self.assertFalse(any("*" in argument for command in commands for argument in command))

    def test_dry_run_is_portable_and_changes_nothing(self):
        result = subprocess.run([sys.executable, str(ROOT / "scripts/install_macos.py"),
                                 "--dry-run", "--home", str(self.state),
                                 "--app-destination", str(self.app), "--launch-agents-dir", str(self.agents)],
                                capture_output=True, text=True, check=True)
        document = json.loads(result.stdout)
        self.assertEqual(document["state"], str(self.state))
        self.assertFalse(self.state.exists())
        self.assertFalse(self.app.exists())
        self.assertFalse(self.agents.exists())

    def test_plist_declares_apple_permissions_and_macos_minimum(self):
        document = plistlib.loads((ROOT / "scripts/resources/Info.plist").read_bytes())
        self.assertEqual(document["CFBundleIdentifier"], installer.BUNDLE_ID)
        self.assertEqual(document["LSMinimumSystemVersion"], "14.0")
        self.assertIs(document["LSUIElement"], True)
        for key in ("NSCalendarsFullAccessUsageDescription", "NSRemindersFullAccessUsageDescription", "NSContactsUsageDescription"):
            self.assertTrue(document[key])


if __name__ == "__main__":
    unittest.main()
