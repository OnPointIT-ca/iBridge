"""Bounded, authenticated HTTP client using only Python's standard library."""

from __future__ import annotations

import json
import math
import os
import re
from dataclasses import dataclass, field
from http.client import HTTPException
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

MAX_RESPONSE_BYTES = 2 * 1024 * 1024


class BridgeError(Exception):
    def __init__(self, code: str, message: str, **details):
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details

    def result(self):
        return {"error": {"code": self.code, "message": self.message, **self.details}}


def _setting(name: str):
    # Do not bypass denied scoped secrets by falling back to the environment.
    try:
        from agent.secret_scope import get_secret
    except ModuleNotFoundError as exc:
        if exc.name not in {"agent", "agent.secret_scope"}:
            raise
        return os.environ.get(name)
    return get_secret(name)


@dataclass(frozen=True)
class Config:
    url: str
    token: str = field(repr=False)
    timeout: float = 20.0
    allow_local_http: bool = False

    def __post_init__(self):
        try:
            parts = urlsplit(self.url)
            valid = (
                bool(parts.hostname)
                and parts.username is None
                and parts.password is None
                and parts.path in {"", "/"}
                and not parts.query
                and not parts.fragment
                and not re.search(r"[\s\\\x00-\x1f\x7f]", self.url)
                and (parts.port is None or 1 <= parts.port <= 65535)
            )
        except (ValueError, TypeError):
            valid = False
        if not valid:
            raise BridgeError("configuration_error", "IBRIDGE_URL must be an HTTPS origin without a path, credentials, query, or fragment.")
        local_http = (
            self.allow_local_http and parts.scheme == "http"
            and parts.hostname in {"127.0.0.1", "::1", "localhost"}
        )
        if parts.scheme != "https" and not local_http:
            raise BridgeError("configuration_error", "HTTPS is required; explicit local HTTP is allowed only for loopback development.")
        if not isinstance(self.token, str) or not re.fullmatch(r"[A-Za-z0-9._~+/-]+=*", self.token):
            raise BridgeError("configuration_error", "IBRIDGE_TOKEN must contain a valid nonempty bearer token.")
        if not isinstance(self.timeout, (float, int)) or not math.isfinite(self.timeout) or not 0 < self.timeout <= 120:
            raise BridgeError("configuration_error", "IBRIDGE_TIMEOUT_SECONDS must be greater than 0 and at most 120.")

    @classmethod
    def from_env(cls):
        try:
            timeout = float(os.environ.get("IBRIDGE_TIMEOUT_SECONDS", "20"))
        except ValueError:
            raise BridgeError("configuration_error", "IBRIDGE_TIMEOUT_SECONDS must be a number.") from None
        return cls(
            url=_setting("IBRIDGE_URL") or "",
            token=_setting("IBRIDGE_TOKEN") or "",
            timeout=timeout,
            allow_local_http=os.environ.get("IBRIDGE_ALLOW_LOCAL_HTTP") == "1",
        )


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class BridgeClient:
    def __init__(self, config: Config):
        self.config = config
        self._opener = build_opener(_NoRedirect())

    def request(self, method: str, path: str):
        if method != "GET" or not path.startswith("/api/v1/"):
            raise BridgeError("invalid_request", "Unsupported bridge request.")
        req = Request(
            self.config.url.rstrip("/") + path,
            method=method,
            headers={"Authorization": "Bearer " + self.config.token, "Accept": "application/json"},
        )
        try:
            with self._opener.open(req, timeout=self.config.timeout) as response:
                if response.headers.get_content_type() != "application/json":
                    raise BridgeError("invalid_response", "Bridge response must be JSON.")
                raw = response.read(MAX_RESPONSE_BYTES + 1)
                if len(raw) > MAX_RESPONSE_BYTES:
                    raise BridgeError("response_too_large", "Bridge response exceeds the client limit; narrow the request.")
                try:
                    result = json.loads(raw.decode("utf-8"))
                except (ValueError, UnicodeError):
                    raise BridgeError("invalid_response", "Bridge returned invalid JSON.") from None
                if not isinstance(result, dict) or "data" not in result or "error" in result:
                    raise BridgeError("invalid_response", "Bridge response does not match the v1 envelope.")
                return result
        except HTTPError as exc:
            status = exc.code
            exc.close()
            code, message = {
                400: ("invalid_request", "Bridge rejected the request."),
                401: ("authentication_failed", "Bridge token is missing, expired, or invalid."),
                403: ("permission_denied", "Bridge denied this operation or resource."),
                404: ("not_found", "Bridge route or resource was not found."),
                409: ("conflict", "Bridge reported a conflict; inspect the resource before retrying."),
                413: ("request_too_large", "Request exceeds the bridge limit."),
                422: ("invalid_request", "Bridge rejected the arguments."),
                429: ("rate_limited", "Bridge rate limit reached; retry later."),
                503: ("unavailable", "Bridge or Apple adapter is temporarily unavailable."),
            }.get(status, ("http_error", "Bridge request failed."))
            if 300 <= status < 400:
                code, message = "redirect_refused", "Bridge redirects are not followed; check the configured origin."
            raise BridgeError(code, message, http_status=status) from None
        except TimeoutError:
            raise BridgeError("timeout", "Bridge request timed out.") from None
        except (URLError, OSError, HTTPException):
            raise BridgeError("connection_failed", "Could not establish a verified connection to the bridge.") from None

    def capabilities(self):
        result = self.request("GET", "/api/v1/system/capabilities")
        data = result["data"]
        if not isinstance(data, dict) or data.get("api_version") != "1":
            raise BridgeError("incompatible_bridge", "This plugin requires iBridge HTTP contract v1.")
        if not isinstance(data.get("operations"), dict):
            raise BridgeError("invalid_response", "Bridge capability map is missing or invalid.")
        return result

    def render(self, result):
        # Defense in depth against accidental credential echoes from a server.
        return json.dumps(result, ensure_ascii=False).replace(self.config.token, "[REDACTED]")
