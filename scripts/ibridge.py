#!/usr/bin/env python3
"""Run the installed gateway's administrative CLI with its saved Node runtime."""

import argparse
import json
import os
from pathlib import Path
import sys

from install_macos import absolute, default_state


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, add_help=False)
    parser.add_argument("--home", type=Path, default=default_state())
    args, command = parser.parse_known_args(argv)
    state = absolute(args.home)
    try:
        receipt = json.loads((state / "installation.json").read_text())
        node = absolute(receipt["node"])
        cli = absolute(receipt["runtime"]) / "gateway/dist/cli.js"
        if receipt.get("schema") != 1 or receipt.get("state") != str(state) or not cli.is_file():
            raise ValueError("Invalid installation receipt; rerun the installer")
        os.execve(str(node), [str(node), str(cli), *command], dict(os.environ, IBRIDGE_HOME=str(state)))
    except (OSError, ValueError, KeyError) as exc:
        print(f"Cannot run installed iBridge: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
