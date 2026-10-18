"""Hermes handlers return JSON strings, including failures."""

import json

from .client import BridgeClient, BridgeError, Config


def capabilities(args: dict, **kwargs) -> str:
    try:
        if not isinstance(args, dict) or args:
            raise BridgeError("invalid_arguments", "This tool takes an empty argument object.")
        client = BridgeClient(Config.from_env())
        return client.render(client.capabilities())
    except BridgeError as exc:
        return json.dumps(exc.result())
    except Exception:
        # Never leak secret-bearing exception text to the model or logs.
        return json.dumps({"error": {"code": "client_error", "message": "iBridge client failed; check plugin configuration and compatibility."}})
