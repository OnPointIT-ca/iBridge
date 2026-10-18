"""Installation safety, manifest parity, and provider-facing schema checks."""

import importlib.util
import inspect
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from support import PLUGIN_DIR, plugin

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("ibridge_installer", ROOT / "scripts" / "install_hermes_plugin.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)

try:
    from jsonschema import Draft202012Validator
except ImportError:
    Draft202012Validator = None


class RecordingContext:
    def __init__(self):
        self.tools = []

    def register_tool(self, *, name, toolset, schema, handler, requires_env):
        self.tools.append({"name": name, "toolset": toolset, "schema": schema,
                           "handler": handler, "requires_env": requires_env})


def declared_tools():
    # This deliberately checks this manifest's simple string-list format; full
    # YAML parsing and schema admission are handled by the official CLI check.
    text = (PLUGIN_DIR / "plugin.yaml").read_text(encoding="utf-8")
    block = re.search(r"(?m)^provides_tools:\s*\n((?:^[ \t]+.*\n)+)", text)
    if block is None:
        raise AssertionError("manifest requires an explicit provides_tools list")
    names = []
    for line in block.group(1).splitlines():
        entry = re.fullmatch(r"\s+-\s+([a-zA-Z0-9_]+)\s*", line)
        if entry is None:
            raise AssertionError(f"unsupported provides_tools entry: {line!r}")
        names.append(entry.group(1))
    return names


class RegistrationTests(unittest.TestCase):
    def setUp(self):
        self.ctx = RecordingContext()
        with patch.dict(os.environ, {}, clear=True), patch("socket.socket.connect", side_effect=AssertionError("registration must be offline")):
            plugin.register(self.ctx)

    def test_manifest_matches_registered_tools_without_duplicates(self):
        declared = declared_tools()
        registered = [tool["name"] for tool in self.ctx.tools]
        self.assertTrue(registered)
        self.assertEqual(len(declared), len(set(declared)))
        self.assertEqual(len(registered), len(set(registered)))
        self.assertEqual(set(declared), set(registered))

    def test_registered_schemas_and_handlers_follow_hermes_contract(self):
        for tool in self.ctx.tools:
            with self.subTest(tool=tool["name"]):
                schema = tool["schema"]
                self.assertEqual(tool["toolset"], "ibridge")
                self.assertEqual(schema["name"], tool["name"])
                self.assertTrue(schema["description"])
                self.assertLessEqual(len(tool["name"]), 64)
                self.assertEqual(tool["requires_env"], ["IBRIDGE_URL", "IBRIDGE_TOKEN"])
                parameters = schema["parameters"]
                self.assertEqual(parameters["type"], "object")
                self.assertIs(parameters["additionalProperties"], False)
                self.assertLessEqual(set(parameters.get("required", [])), set(parameters["properties"]))
                json.dumps(schema, allow_nan=False)
                self.assertTrue(any(arg.kind == inspect.Parameter.VAR_KEYWORD for arg in inspect.signature(tool["handler"]).parameters.values()))
                with patch("socket.socket.connect", side_effect=AssertionError("invalid arguments must not use the network")):
                    output = tool["handler"](None, session_id="compatibility-test")
                self.assertIsInstance(output, str)
                self.assertIn("error", json.loads(output))

    @unittest.skipIf(Draft202012Validator is None, "install scripts/requirements-compatibility.txt for JSON Schema validation")
    def test_tool_parameters_are_valid_json_schemas(self):
        for tool in self.ctx.tools:
            with self.subTest(tool=tool["name"]):
                Draft202012Validator.check_schema(tool["schema"]["parameters"])


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_fresh_install_is_loadable_and_excludes_local_secrets_and_caches(self):
        source = self.root / "source"
        installer.install(PLUGIN_DIR, source)
        (source / ".env").write_text("IBRIDGE_TOKEN=not-for-distribution")
        (source / "private.json").write_text("private")
        (source / "__pycache__").mkdir()
        (source / "__pycache__" / "stale.pyc").write_bytes(b"stale")
        destination = self.root / "profile" / "plugins" / "ibridge"
        installer.install(source, destination)
        self.assertFalse((destination / ".env").exists())
        self.assertFalse((destination / "private.json").exists())
        self.assertFalse((destination / "__pycache__").exists())
        for filename in ("plugin.yaml", "__init__.py", "client.py", "operations.py", "README.md"):
            self.assertEqual((destination / filename).read_bytes(), (PLUGIN_DIR / filename).read_bytes())
        package = importlib.util.spec_from_file_location("ibridge_installed_test", destination / "__init__.py", submodule_search_locations=[str(destination)])
        module = importlib.util.module_from_spec(package)
        with patch.dict(sys.modules, {package.name: module}):
            package.loader.exec_module(module)
            ctx = RecordingContext()
            module.register(ctx)
        self.assertEqual({tool["name"] for tool in ctx.tools}, set(declared_tools()))

    def test_existing_destination_is_never_overwritten(self):
        for kind in ("directory", "file", "symlink", "broken_symlink"):
            with self.subTest(kind=kind):
                destination = self.root / kind
                if kind == "directory":
                    destination.mkdir()
                    (destination / "custom.py").write_text("preserve me")
                elif kind == "file":
                    destination.write_text("preserve me")
                else:
                    destination.symlink_to(PLUGIN_DIR if kind == "symlink" else self.root / "missing", target_is_directory=True)
                with self.assertRaises(FileExistsError):
                    installer.install(PLUGIN_DIR, destination)
                if kind == "directory":
                    self.assertEqual((destination / "custom.py").read_text(), "preserve me")
                    self.assertFalse((destination / "plugin.yaml").exists())

    def test_symlinked_source_is_rejected_before_destination_creation(self):
        source = self.root / "source"
        installer.install(PLUGIN_DIR, source)
        (source / "client.py").unlink()
        (source / "client.py").symlink_to(PLUGIN_DIR / "client.py")
        destination = self.root / "destination"
        with self.assertRaises(ValueError):
            installer.install(source, destination)
        self.assertFalse(destination.exists())

    def test_named_profile_configuration_and_credentials_are_preserved(self):
        profile = self.root / "profiles" / "personal"
        profile.mkdir(parents=True)
        (profile / "config.yaml").write_text("existing: configuration\n")
        (profile / ".env").write_text("EXISTING_SECRET=private\n")
        result = subprocess.run([sys.executable, str(ROOT / "scripts" / "install_hermes_plugin.py"), "--hermes-home", str(profile)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((profile / "plugins" / "ibridge" / "plugin.yaml").is_file())
        self.assertEqual((profile / "config.yaml").read_text(), "existing: configuration\n")
        self.assertEqual((profile / ".env").read_text(), "EXISTING_SECRET=private\n")
        self.assertNotIn("EXISTING_SECRET", result.stdout + result.stderr)

    def test_exact_custom_destination_and_repeat_failure(self):
        destination = self.root / "custom plugin"
        command = [sys.executable, str(ROOT / "scripts" / "install_hermes_plugin.py"), "--destination", str(destination)]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((destination / "plugin.yaml").is_file())
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already exists", result.stderr)

    def test_environment_selects_exact_profile_home(self):
        profile = self.root / "profiles" / "personal"
        with patch.dict(os.environ, {"HERMES_HOME": str(profile)}):
            self.assertEqual(installer.default_hermes_home(), profile)
        with patch.dict(os.environ, {}, clear=True), patch.object(Path, "home", return_value=self.root), patch.object(sys, "platform", "linux"):
            self.assertEqual(installer.default_hermes_home(), self.root / ".hermes")


if __name__ == "__main__":
    unittest.main()
