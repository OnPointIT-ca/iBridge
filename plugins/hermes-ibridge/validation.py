"""Validate the small JSON Schema subset used by this plugin, before networking."""

import re
from datetime import datetime

from .client import BridgeError


def timestamp(value):
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})", value):
        raise ValueError("Timestamp requires an explicit offset")
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def validate(operation, args):
    if not isinstance(args, dict) or set(args) - set(operation.properties):
        raise BridgeError("invalid_arguments", "Arguments must be an object containing only the tool's declared fields.")
    if any(key not in args for key in operation.required):
        raise BridgeError("invalid_arguments", "A required tool argument is missing.")
    values = dict(args)
    for key, rule in operation.properties.items():
        if key not in values:
            if "default" not in rule:
                continue
            values[key] = rule["default"]
        value = values[key]
        kind = rule["type"]
        valid = (
            (kind == "string" and isinstance(value, str))
            or (kind == "integer" and type(value) is int)
            or (kind == "boolean" and type(value) is bool)
        )
        if not valid:
            raise BridgeError("invalid_arguments", f"{key} has the wrong type.")
        if kind == "integer" and not rule.get("minimum", value) <= value <= rule.get("maximum", value):
            raise BridgeError("invalid_arguments", f"{key} is outside the allowed range.")
        if kind == "string":
            if not rule.get("minLength", 0) <= len(value) <= rule.get("maxLength", len(value)):
                raise BridgeError("invalid_arguments", f"{key} has an invalid length.")
            if any(ord(char) < 32 and char not in "\n\t" for char in value):
                raise BridgeError("invalid_arguments", f"{key} contains unsupported control characters.")
            if rule.get("format") == "relative-path":
                if value.startswith("/") or "\\" in value or any(part in {".", ".."} for part in value.split("/")):
                    raise BridgeError("invalid_arguments", "Drive paths must remain relative to an authorized root.")
            if rule.get("format") == "date-time":
                try:
                    timestamp(value)
                except ValueError:
                    raise BridgeError("invalid_arguments", f"{key} must be a valid RFC 3339 timestamp with a timezone.") from None
    if "start" in values and "end" in values and timestamp(values["end"]) <= timestamp(values["start"]):
        raise BridgeError("invalid_arguments", "end must be later than start.")
    for key in operation.path_keys:
        if values[key] in {".", ".."}:
            raise BridgeError("invalid_arguments", "Resource IDs cannot be dot path segments.")
    return values
