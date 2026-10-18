# Hermes compatibility and installation checks

iBridge is a native directory plugin for
[NousResearch/Hermes Agent](https://github.com/NousResearch/hermes-agent).
It supplies `plugin.yaml` and `register(ctx)`, registering tools in the `ibridge`
toolset. Relative imports are compatible with Hermes' namespaced plugin loader.
Handlers return JSON strings and accept Hermes' injected keyword arguments.
Registration does not contact the bridge or read Apple data.

The repository contains the plugin, macOS host, gateway, and Android client.
The checks described here validate the **Hermes integration**. They do not
demonstrate live Apple permission grants, iCloud sync, or end-to-end access from
a deployed Hermes agent. See [current development status](../Development.md)
for the complete validation inventory and remaining acceptance work.

## Verified reference

The official Hermes reference is pinned to commit
[`ccc695635094d7615373db267b77f894d978b1a0`](https://github.com/NousResearch/hermes-agent/commit/ccc695635094d7615373db267b77f894d978b1a0).
The checks were executed on Linux with CPython 3.14.8 and an isolated virtual
environment containing the dependencies in `scripts/requirements-compatibility.txt`.
This is an interface compatibility check, not a claim about every Hermes release.
The plugin's Python 3.10 minimum does not override Hermes' interpreter requirements.

The v0.3.0 plugin passed both official checks with **21 registered tools**
and no validation warnings. The repository test suite now also covers the gateway
and installers; current counts and revision-specific evidence are recorded in
[Development.md](../Development.md#validation-evidence-and-its-limits).
Rerun relevant checks whenever tools or host compatibility change.

| Check | What actually runs | Scope |
| --- | --- | --- |
| `hermes plugins doctor PATH --ci` | Official manifest parser, directory discovery, namespaced import, plugin loader and tool registry | Passed real runtime registration with sockets blocked by Doctor |
| `hermes plugins validate PATH --json` | Official catalog admission checks and subprocess capability probe | Passed manifest, tool declarations, collisions and security checks; the probe itself uses Hermes' recording context |
| Repository tests | Installer, registered tool/schema parity, HTTP fixtures, JSON Schema meta-validation | Client contract and installation behavior; fixtures are not Apple services |

Doctor creates a temporary Hermes home and restores runtime registration state.
Validation uses a subprocess probe and must not be described as the full runtime
loader; Doctor provides that separate evidence. Neither command invokes an
iBridge service operation. Compatibility runs use the reserved `.invalid`
hostname and a clearly fake token. No production credentials are required.

## Reproduce the official checks

In a temporary development directory, obtain the upstream source and create a
separate environment. Run these commands from the iBridge repository root:

```sh
git clone https://github.com/NousResearch/hermes-agent.git /tmp/hermes-ibridge-reference
git -C /tmp/hermes-ibridge-reference checkout ccc695635094d7615373db267b77f894d978b1a0
python3.14 -m venv /tmp/ibridge-compat-venv
/tmp/ibridge-compat-venv/bin/python -m pip install -r scripts/requirements-compatibility.txt
/tmp/ibridge-compat-venv/bin/python -m unittest discover -s tests -v
/tmp/ibridge-compat-venv/bin/python scripts/check_hermes_compatibility.py --hermes-checkout /tmp/hermes-ibridge-reference
```

The wrapper verifies the upstream commit, runs both official CLI commands with
the same interpreter, creates a disposable `HERMES_HOME`, and replaces inherited
iBridge credentials with fixture values. It preserves proxy and CA configuration.
It does not install or update Hermes, mutate a user's profile, enable plugins,
or call the bridge. Use `--plugin /path/to/installed/ibridge` to check an installed
copy. Only run plugin checks on code you trust: Doctor is not an OS sandbox.

The GitHub Actions workflow runs the client tests on Python 3.10, 3.12 and 3.14
and the official checks against the pinned Hermes source on Python 3.14. Changing
the reference requires updating both the script constant and workflow revision,
then rerunning the checks before describing the new reference as verified.

## Profile behavior

The installer accepts an exact profile home with `--hermes-home`, or a full
plugin destination with `--destination`. This avoids guessing which sticky
profile a particular Hermes invocation selects. Standard named profiles live at
`~/.hermes/profiles/<name>`; custom `HERMES_HOME` roots may locate them elsewhere.
Create/select profiles using Hermes itself, then pass their existing home paths
to the installer. A directory copied outside a profile's `plugins` directory
will not be discovered automatically.

The installer refuses existing destinations, including broken symlinks. It
stages only Python source, `plugin.yaml`, and the plugin README, then creates a
fresh destination. If a filesystem error interrupts the final copy, inspect
and move aside that partial directory before retrying. There is no automatic
overwrite, credential copying, config editing, or dependency installation.

During an update, keep any old package backup outside the profile's `plugins`
directory, so Hermes cannot discover both copies. Installation and enablement
are separate: configure the URL/token in the intended profile, enable `ibridge`
through Hermes, and restart its processes. Install and configure the existing
Mac host/gateway using the [Mac setup guide](macos-setup.md), then verify the
deployed connection with the intended client token.
