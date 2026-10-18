#!/usr/bin/env python3
"""Install iBridge into the current macOS user session without root access."""

import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys
import tempfile
import uuid

REPO = Path(__file__).resolve().parents[1]
BUNDLE_ID = "ca.onpointit.ibridge"
LABELS = (BUNDLE_ID + ".host", BUNDLE_ID + ".gateway")


def absolute(path):
    return Path(os.path.abspath(Path(path).expanduser()))


def default_state():
    return absolute(os.environ.get("IBRIDGE_HOME") or Path.home() / "Library/Application Support/iBridge")


def reject_symlink(path):
    # Include existing ancestors: redirecting a destination through a link would
    # make an otherwise narrowly scoped app/LaunchAgent replacement ambiguous.
    for item in (path, *path.parents):
        if item.is_symlink():
            raise ValueError(f"Installation destination must not use symlinks: {item}")


def private_directory(path):
    reject_symlink(path)
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not path.is_dir() or path.stat().st_uid != os.getuid():
        raise ValueError(f"Directory must belong to the current user: {path}")
    path.chmod(0o700)


def app_identity(path):
    if path.is_symlink() or not path.is_dir():
        raise ValueError(f"Expected an application directory: {path}")
    metadata = path / "Contents/Info.plist"
    if metadata.is_symlink():
        raise ValueError("Application metadata must not be a symlink")
    with metadata.open("rb") as handle:
        identifier = plistlib.load(handle).get("CFBundleIdentifier")
    if identifier != BUNDLE_ID:
        raise ValueError(f"Application is not iBridge: {path}")
    executable = path / "Contents/MacOS/iBridgeHost"
    if not executable.is_file() or executable.is_symlink():
        raise ValueError("iBridge application executable is missing or symlinked")


def launch_agents(state, app, runtime, node, gateway_environment=None):
    common = {
        "EnvironmentVariables": {"IBRIDGE_HOME": str(state)},
        "RunAtLoad": True,
        "KeepAlive": True,
        "ThrottleInterval": 10,
        "Umask": 0o077,
    }
    result = {
        LABELS[0]: dict(common, Label=LABELS[0],
                       ProgramArguments=[str(app / "Contents/MacOS/iBridgeHost"), "--serve"],
                       ProcessType="Interactive", LimitLoadToSessionType="Aqua",
                       StandardOutPath=str(state / "logs/host.stdout.log"),
                       StandardErrorPath=str(state / "logs/host.stderr.log")),
        LABELS[1]: dict(common, Label=LABELS[1],
                       ProgramArguments=[str(node), str(runtime / "gateway/dist/cli.js"), "serve"],
                       WorkingDirectory=str(runtime / "gateway"), ProcessType="Background",
                       StandardOutPath=str(state / "logs/gateway.stdout.log"),
                       StandardErrorPath=str(state / "logs/gateway.stderr.log")),
    }
    result[LABELS[1]]["EnvironmentVariables"] = dict(common["EnvironmentVariables"], **(gateway_environment or {}))
    return result


def write_atomic(path, payload):
    reject_symlink(path)
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".ibridge-", delete=False) as handle:
        temporary = Path(handle.name)
        try:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    try:
        temporary.chmod(0o600)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def install_prepared(app_source, runtime_source, state, app, agents, node, start=True, runner=subprocess.run, gateway_environment=None):
    """Install prepared assets; never copy over user configuration or Apple data."""
    for destination in (state, app, agents):
        reject_symlink(destination)
    if app.suffix != ".app":
        raise ValueError("--app-destination must end in .app")
    app_identity(app_source)
    if app.exists():
        app_identity(app)
    retained_environment = {}
    for label in LABELS:
        existing = agents / (label + ".plist")
        reject_symlink(existing)
        if existing.exists():
            with existing.open("rb") as handle:
                document = plistlib.load(handle)
            if document.get("Label") != label or document.get("EnvironmentVariables", {}).get("IBRIDGE_HOME") != str(state):
                raise ValueError(f"Refusing to replace another installation's LaunchAgent: {existing}")
            if label == LABELS[1]:
                retained_environment = {key: value for key, value in document.get("EnvironmentVariables", {}).items()
                                        if key in ("IBRIDGE_ALLOWED_HOSTS", "IBRIDGE_PORT")}
    retained_environment.update(gateway_environment or {})
    private_directory(state)
    for child in (state / "runtime", state / "runtime/releases", state / "logs"):
        private_directory(child)
    agents.mkdir(mode=0o700, parents=True, exist_ok=True)
    app.parent.mkdir(parents=True, exist_ok=True)
    runtime = state / "runtime/releases" / uuid.uuid4().hex
    shutil.copytree(runtime_source, runtime)
    staged_app = app.parent / (".ibridge-install-" + uuid.uuid4().hex + ".app")
    backup = app.parent / (".ibridge-backup-" + uuid.uuid4().hex + ".app")
    shutil.copytree(app_source, staged_app, symlinks=True)
    env = dict(os.environ, IBRIDGE_HOME=str(state))
    try:
        # init is idempotent and retains the existing clients and write journal.
        runner([str(node), str(runtime / "gateway/dist/cli.js"), "init"], env=env, check=True)
        for label in LABELS:
            target = f"gui/{os.getuid()}/{label}"
            result = runner(["/bin/launchctl", "print", target], capture_output=True, check=False)
            if result.returncode == 0:
                runner(["/bin/launchctl", "bootout", target], check=True)
        if app.exists():
            app.rename(backup)
        staged_app.rename(app)
        for label, document in launch_agents(state, app, runtime, node, retained_environment).items():
            write_atomic(agents / (label + ".plist"), plistlib.dumps(document))
        receipt = {"schema": 1, "state": str(state), "app": str(app),
                   "runtime": str(runtime), "node": str(node), "launch_agents": str(agents),
                   "gateway_environment": retained_environment}
        write_atomic(state / "installation.json", (json.dumps(receipt, indent=2) + "\n").encode())
        if start:
            for label in LABELS:
                runner(["/bin/launchctl", "bootstrap", f"gui/{os.getuid()}", str(agents / (label + ".plist"))], check=True)
        if backup.exists():
            shutil.rmtree(backup)
    except BaseException:
        # Restore the old app if replacement failed before it became active.
        # Retain the new runtime/receipt for diagnosis; never remove user state.
        if backup.exists() and not app.exists():
            backup.rename(app)
        raise
    finally:
        if staged_app.exists():
            shutil.rmtree(staged_app)
    return receipt


def check_prerequisites():
    if platform.system() != "Darwin" or int(platform.mac_ver()[0].split(".")[0]) < 14:
        raise ValueError("Installation requires macOS 14 or newer")
    if os.getuid() == 0:
        raise ValueError("Run as your logged-in user, without sudo")
    node = shutil.which("node")
    npm = shutil.which("npm")
    if not node or not npm:
        raise ValueError("Install Node.js 24+ (including npm) before installing iBridge")
    # Resolve Node now: launchd has a different PATH from the interactive shell.
    node = Path(node).resolve()
    result = subprocess.run([str(node), "--version"], check=True, capture_output=True, text=True)
    if int(result.stdout.strip().lstrip("v").split(".")[0]) < 24:
        raise ValueError("Node.js 24 or newer is required")
    return node, npm


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path, default=default_state(), help="Shared native/gateway state; also honors IBRIDGE_HOME")
    parser.add_argument("--app-destination", type=Path, default=Path.home() / "Applications/iBridge.app")
    parser.add_argument("--launch-agents-dir", type=Path, default=Path.home() / "Library/LaunchAgents")
    parser.add_argument("--app-source", type=Path, help="Use a prebuilt iBridge.app instead of building Swift")
    parser.add_argument("--arch", choices=("arm64", "x86_64", "universal"), default=platform.machine())
    parser.add_argument("--allowed-hosts", help="Comma-separated HTTP Host allowlist, including local and private HTTPS hostnames; preserved on upgrades")
    parser.add_argument("--port", type=int, help="Loopback gateway port (default 21420); preserved on upgrades")
    parser.add_argument("--no-start", action="store_true", help="Install login agents but leave services stopped until next login")
    parser.add_argument("--dry-run", action="store_true", help="Print paths and LaunchAgents without changes or macOS requirements")
    args = parser.parse_args(argv)
    state, app, agents = map(absolute, (args.home, args.app_destination, args.launch_agents_dir))
    gateway_environment = {}
    if args.allowed_hosts is not None:
        gateway_environment["IBRIDGE_ALLOWED_HOSTS"] = args.allowed_hosts
    if args.port is not None:
        if not 1 <= args.port <= 65535:
            parser.error("--port must be between 1 and 65535")
        gateway_environment["IBRIDGE_PORT"] = str(args.port)
    if args.dry_run:
        node = absolute(shutil.which("node") or "/path/to/node24")
        plan = {"state": str(state), "app": str(app), "launch_agents_directory": str(agents),
                "start": not args.no_start, "agents": launch_agents(state, app, state / "runtime/releases/NEW", node, gateway_environment)}
        print(json.dumps(plan, indent=2))
        return 0
    try:
        for destination in (state, app, agents):
            reject_symlink(destination)
        node, npm = check_prerequisites()
        # Build from the locked repository before stopping an existing install.
        build_env = dict(os.environ, PATH=str(node.parent) + os.pathsep + os.environ.get("PATH", ""))
        subprocess.run([npm, "ci", "--ignore-scripts"], cwd=REPO / "gateway", env=build_env, check=True)
        subprocess.run([npm, "run", "build"], cwd=REPO / "gateway", env=build_env, check=True)
        with tempfile.TemporaryDirectory(prefix="ibridge-install-") as directory:
            temporary = Path(directory)
            app_source = absolute(args.app_source) if args.app_source else temporary / "native/iBridge.app"
            if not args.app_source:
                subprocess.run([str(REPO / "scripts/build_macos_app.sh"), "--arch", args.arch,
                                "--output", str(temporary / "native")], check=True)
            subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app_source)], check=True)
            subprocess.run(["/usr/bin/lipo", "-verify_arch", platform.machine(),
                            str(app_source / "Contents/MacOS/iBridgeHost")], check=True)
            runtime = temporary / "runtime"
            gateway = runtime / "gateway"
            gateway.mkdir(parents=True)
            for filename in ("package.json", "package-lock.json"):
                shutil.copyfile(REPO / "gateway" / filename, gateway / filename)
            shutil.copytree(REPO / "gateway/dist", gateway / "dist")
            (runtime / "shared").mkdir()
            shutil.copyfile(REPO / "shared/operations.json", runtime / "shared/operations.json")
            subprocess.run([npm, "ci", "--omit=dev", "--ignore-scripts"], cwd=gateway, env=build_env, check=True)
            receipt = install_prepared(app_source, runtime, state, app, agents, node, start=not args.no_start, gateway_environment=gateway_environment)
        print(f"Installed {receipt['app']}")
        print(f"State preserved at {state}")
        print("Use the iBridge menu bar to grant Apple service permissions and select Drive folders.")
        print("Create a scoped client token with the installed gateway CLI; see docs/macos-setup.md.")
        return 0
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f"Installation failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
