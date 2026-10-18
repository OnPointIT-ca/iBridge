#!/usr/bin/env python3
"""Export the canonical Hermes operation schemas for the server transports."""

import argparse
import importlib.util
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "plugins" / "hermes-ibridge"
OUTPUT = ROOT / "shared" / "operations.json"
NATIVE_OUTPUT = ROOT / "macos" / "Sources" / "IBridgeCore" / "Resources" / "operations.json"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location("ibridge_catalog", PACKAGE / "__init__.py", submodule_search_locations=[str(PACKAGE)])
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    operations = [
        {"name": op.name, "capability": op.capability, "method": op.method,
         "path": op.path, "path_keys": list(op.path_keys), "schema": op.schema}
        for op in module.OPERATIONS
    ]
    rendered = json.dumps({"api_version": "1", "operations": operations}, indent=2, ensure_ascii=False) + "\n"
    outputs = [OUTPUT]
    if NATIVE_OUTPUT.parent.is_dir():
        outputs.append(NATIVE_OUTPUT)
    for output in outputs:
        if args.check:
            if not output.exists() or output.read_text() != rendered:
                parser.exit(1, f"{output.relative_to(ROOT)} is stale; run scripts/export_operations.py\n")
        else:
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(rendered)


if __name__ == "__main__":
    main()
