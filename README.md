# iBridge

A personal macOS gateway for Apple services, used by an AI agent on another
computer or server. The planned host uses Swift for Apple APIs and a TypeScript
gateway for authenticated REST and MCP access over a private network.

## Implementation status

This repository currently implements the **Hermes Agent client plugin**.
The macOS host and REST server are planned, not implemented. The plugin is tested
against an HTTP contract fixture; it cannot access Apple data until a compatible
bridge is running on your Mac.

- [Hermes plugin](plugins/hermes-ibridge/README.md)
- [Bridge HTTP contract](docs/bridge-api.md)
- [Implementation roadmap](docs/roadmap.md)

Run the client tests with Python 3.10 or newer:

```sh
python3 -m unittest discover -s tests -v
```

No third-party Python packages are required by the plugin or its tests.
