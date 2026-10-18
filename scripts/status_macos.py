#!/usr/bin/env python3
"""Inspect installed iBridge services without reading tokens or Apple content."""

import argparse
import json
import os
from pathlib import Path
import platform
import socket
import stat
import subprocess
import sys

from install_macos import LABELS, absolute, default_state


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path, default=default_state())
    args = parser.parse_args(argv)
    state = absolute(args.home)
    if platform.system() != "Darwin":
        print("Status requires macOS.", file=sys.stderr)
        return 1
    results = {"state": str(state), "services": {}}
    for label in LABELS:
        result = subprocess.run(["/bin/launchctl", "print", f"gui/{os.getuid()}/{label}"], capture_output=True, text=True)
        summary = {"loaded": result.returncode == 0}
        if summary["loaded"]:
            for line in result.stdout.splitlines():
                key, separator, value = line.strip().partition(" = ")
                if separator and key in ("state", "pid", "last exit code"):
                    summary[key] = value
        results["services"][label] = summary
    endpoint = state / "host.sock"
    available = False
    try:
        if stat.S_ISSOCK(endpoint.lstat().st_mode):
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(2)
                connection.connect(str(endpoint))
                available = True
    except (OSError, ValueError):
        pass
    results["native_socket_reachable"] = available
    print(json.dumps(results, indent=2))
    return 0 if available and all(item["loaded"] for item in results["services"].values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
