# iBridge plugin for Hermes Agent

Run this plugin on the machine hosting Hermes. It calls your Mac's authenticated
iBridge API. It does not need your Apple Account credentials.

**Status:** client implementation only. The iBridge macOS host/server is not yet
implemented. Tests use a contract fixture, not Apple services.

## Install

Requires Python 3.10+ and a Hermes version supporting native directory plugins.
From the repository checkout, copy the plugin to your Hermes profile:

```sh
mkdir -p ~/.hermes/plugins
cp -R plugins/hermes-ibridge ~/.hermes/plugins/ibridge
```

For a named/custom Hermes profile, use that profile's plugins directory. Configure
`IBRIDGE_URL` and `IBRIDGE_TOKEN` in your Hermes environment/secret settings, then:

```sh
hermes plugins enable ibridge
hermes plugins doctor ~/.hermes/plugins/ibridge --ci
```

Restart Hermes (including its gateway if used) after installation/configuration.
For updates, replace the existing plugin directory rather than nesting a copy
inside it. Keep runtime credentials in Hermes settings, never in this directory.

## Configuration

| Setting | Purpose |
| --- | --- |
| `IBRIDGE_URL` | HTTPS origin, e.g. `https://mac.example.ts.net`, without `/api/v1` |
| `IBRIDGE_TOKEN` | Client-specific token issued by the bridge |
| `IBRIDGE_TIMEOUT_SECONDS` | Optional request timeout, default 20, maximum 120 |
| `IBRIDGE_ALLOW_LOCAL_HTTP` | Set to `1` only for loopback HTTP development |

Use private HTTPS over Tailscale for remote access. Certificate validation stays
enabled. Plain HTTP tailnet/LAN IPs are not accepted. Redirects are not followed.
The plugin uses Hermes' scoped `agent.secret_scope.get_secret` when available;
standalone tests/older installations fall back to process environment variables
only when that module is absent. It never reads credential files.

## Tools

`ibridge_capabilities` reports the server's caller-specific available operations.
Registration is offline; networking happens only when a tool is called.

## Development

From the repository root:

```sh
python3 -m unittest discover -s tests -v
```

The plugin follows the official [Hermes plugin interface](https://hermes-agent.nousresearch.com/docs/developer-guide/plugins/).
