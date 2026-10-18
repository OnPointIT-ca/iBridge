#!/usr/bin/env python3
"""Install the directory plugin without modifying Hermes configuration or secrets."""

import argparse
import os
from pathlib import Path
import shlex
import shutil
import sys
import tempfile


SOURCE = Path(__file__).resolve().parents[1] / "plugins" / "hermes-ibridge"


def default_hermes_home():
    """Honor an explicit profile home; otherwise use Hermes' platform default."""
    configured = os.environ.get("HERMES_HOME", "").strip()
    if configured:
        return Path(os.path.expandvars(configured)).expanduser()
    suffix = os.environ.get("HERMES_DATA_DIR_SUFFIX", "")
    if any(separator in suffix for separator in ("/", "\\")):
        raise ValueError("HERMES_DATA_DIR_SUFFIX must not contain path separators")
    if sys.platform == "win32":
        base = Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData" / "Local")
        return base / ("hermes" + suffix)
    return Path.home() / (".hermes" + suffix)


def install(source, destination):
    """Copy a reviewed set of source files; refuse all existing destinations."""
    source = Path(source)
    destination = Path(destination).expanduser().absolute()
    # Check lexically first so a symlink cannot redirect a replacement.
    if destination.exists() or destination.is_symlink():
        raise FileExistsError(f"Destination already exists: {destination}. Move it aside before updating.")
    required = ("plugin.yaml", "__init__.py", "README.md")
    paths = sorted(set(source.glob("*.py")) | {source / name for name in required})
    for path in paths:
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Plugin source must be a regular file: {path.name}")
    # Explicit source allowlist excludes credentials, caches and repository metadata.
    # Prepare the complete copy before claiming the destination. copytree's mkdir
    # refuses a concurrently created directory instead of overwriting it.
    with tempfile.TemporaryDirectory(prefix="ibridge-install-") as temporary:
        staged = Path(temporary) / "ibridge"
        staged.mkdir(mode=0o700)
        for path in paths:
            shutil.copyfile(path, staged / path.name)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(staged, destination)
    return destination


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    location = parser.add_mutually_exclusive_group()
    location.add_argument("--hermes-home", type=Path, help="Exact Hermes profile home; installs under plugins/ibridge")
    location.add_argument("--destination", type=Path, help="Exact new plugin directory (not its parent)")
    args = parser.parse_args(argv)
    try:
        profile_home = args.hermes_home or (default_hermes_home() if args.destination is None else None)
        destination = args.destination if args.destination is not None else profile_home / "plugins" / "ibridge"
        installed = install(SOURCE, destination)
    except (OSError, ValueError) as exc:
        print(f"Installation failed: {exc}", file=sys.stderr)
        return 1
    print(f"Installed iBridge at {installed}")
    print("No Hermes configuration or credentials were changed. Enablement settings were left unchanged.")
    print(f"Check the package: hermes plugins doctor {shlex.quote(str(installed))} --ci")
    if args.destination is None:
        print(f"Profile home: {profile_home.expanduser().absolute()}")
    print("Set IBRIDGE_URL and IBRIDGE_TOKEN in that profile, then run hermes plugins enable ibridge there.")
    print("Restart the Hermes processes using that profile after enabling or updating.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
