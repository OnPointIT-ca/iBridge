"""Validate the small JSON Schema subset used by this plugin, before networking."""

import base64
import binascii
import re
from datetime import datetime, timedelta

from .client import BridgeError


def timestamp(value):
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})", value):
        raise ValueError("Timestamp requires an explicit offset")
    if value[-1] != "Z" and (int(value[-5:-3]) > 23 or int(value[-2:]) > 59):
        raise ValueError("Invalid timezone offset")
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
            if "pattern" in rule and not re.fullmatch(rule["pattern"], value):
                raise BridgeError("invalid_arguments", f"{key} contains unsupported characters or has an invalid format.")
            if rule.get("format") == "relative-path":
                if value.startswith("/") or "\\" in value or any(part in {".", ".."} for part in value.split("/")):
                    raise BridgeError("invalid_arguments", "Drive paths must remain relative to an authorized root.")
            if rule.get("format") == "date-time":
                try:
                    timestamp(value)
                except ValueError:
                    raise BridgeError("invalid_arguments", f"{key} must be a valid RFC 3339 timestamp with a timezone.") from None
            if rule.get("format") == "base64":
                try:
                    decoded = base64.b64decode(value, validate=True)
                    if len(decoded) > 262144 or base64.b64encode(decoded).decode("ascii") != value:
                        raise ValueError("Noncanonical or oversized base64")
                except (ValueError, binascii.Error):
                    raise BridgeError("invalid_arguments", "content_base64 must be canonical base64 for at most 262144 bytes.") from None
    if "start" in values and "end" in values:
        interval = timestamp(values["end"]) - timestamp(values["start"])
        if not timedelta(0) < interval <= timedelta(days=366):
            raise BridgeError("invalid_arguments", "The event interval must be positive and at most 366 days.")
    for key in operation.path_keys:
        if values[key] in {".", ".."}:
            raise BridgeError("invalid_arguments", "Resource IDs cannot be dot path segments.")
    if operation.capability == "drive.upload" and any(not part for part in values["path"].split("/")):
        raise BridgeError("invalid_arguments", "Upload paths must identify a file without empty path segments.")
    return values
