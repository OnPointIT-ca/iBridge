"""Hermes handlers return JSON strings, including failures."""

import json
from urllib.parse import quote, urlencode

from .client import BridgeClient, BridgeError, Config, unknown_write_error
from .validation import validate


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


def make_handler(operation):
    def handler(args: dict, **kwargs) -> str:
        client = None
        attempted_write_id = None
        try:
            values = validate(operation, args)
            client = BridgeClient(Config.from_env())
            entry = client.capabilities()["data"]["operations"].get(operation.capability)
            if not isinstance(entry, dict) or entry.get("available") is not True:
                raise BridgeError("operation_unavailable", "The bridge does not currently permit this operation.", operation=operation.capability)
            path_values = {key: quote(values.pop(key), safe="") for key in operation.path_keys}
            path = "/api/v1" + operation.path.format(**path_values)
            if operation.method == "POST":
                request_id = values.pop("request_id")
                attempted_write_id = request_id
                return client.render(client.request("POST", path, body=values, request_id=request_id))
            query = {key: str(value).lower() if type(value) is bool else value for key, value in values.items()}
            if query:
                path += "?" + urlencode(query)
            return client.render(client.request("GET", path))
        except BridgeError as exc:
            return client.render(exc.result()) if client else json.dumps(exc.result())
        except Exception:
            error = BridgeError("client_error", "iBridge client failed; check plugin configuration and compatibility.")
            if attempted_write_id is not None:
                error = unknown_write_error(error, attempted_write_id)
            return client.render(error.result()) if client else json.dumps(error.result())
    handler.__name__ = operation.name
    return handler
