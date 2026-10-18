#!/usr/bin/env python3
"""Run official Hermes plugin checks from an existing, pinned upstream checkout."""

import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile


HERMES_REVISION = "ccc695635094d7615373db267b77f894d978b1a0"
REPOSITORY = Path(__file__).resolve().parents[1]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hermes-checkout", required=True, type=Path)
    parser.add_argument("--plugin", default=REPOSITORY / "plugins" / "hermes-ibridge", type=Path)
    args = parser.parse_args(argv)
    checkout = args.hermes_checkout.expanduser().resolve()
    plugin = args.plugin.expanduser().resolve()
    try:
        revision = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        parser.error("--hermes-checkout must be an existing official Hermes git checkout")
    if revision != HERMES_REVISION:
        parser.error(f"expected Hermes commit {HERMES_REVISION}, found {revision}")
    if not (plugin / "plugin.yaml").is_file():
        parser.error("--plugin must contain plugin.yaml")
    # Keep proxy/CA settings, but never inherit this operator's iBridge credentials.
    with tempfile.TemporaryDirectory(prefix="ibridge-hermes-check-") as temporary:
        env = {key: value for key, value in os.environ.items() if not key.startswith(("IBRIDGE_", "HERMES_"))}
        env.update({
            "HERMES_HOME": temporary,
            "HERMES_ENABLE_PROJECT_PLUGINS": "0",
            "HERMES_BUNDLED_PLUGINS": str(Path(temporary) / "no-bundled-plugins"),
            "PYTHONPATH": str(checkout),
            "IBRIDGE_URL": "https://ibridge.invalid",
            "IBRIDGE_TOKEN": "compatibility-fixture-not-a-secret",
        })
        print(f"Official Hermes revision: {revision}", flush=True)
        for arguments in (("doctor", str(plugin), "--ci"), ("validate", str(plugin), "--json")):
            result = subprocess.run([sys.executable, "-m", "hermes_cli.main", "plugins", *arguments], cwd=temporary, env=env)
            if result.returncode:
                return result.returncode
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
