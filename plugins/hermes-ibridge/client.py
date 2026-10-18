"""Bounded, authenticated HTTP client using only Python's standard library."""

from __future__ import annotations

import json
import math
import os
import re
import time
from dataclasses import dataclass, field
from http.client import HTTPException
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

MAX_RESPONSE_BYTES = 2 * 1024 * 1024
REQUEST_ID_PATTERN = r"[A-Za-z0-9][A-Za-z0-9._:-]{7,127}"


class BridgeError(Exception):
    def __init__(self, code: str, message: str, **details):
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details

    def result(self):
        return {"error": {"code": self.code, "message": self.message, **self.details}}


def unknown_write_error(error, request_id):
    return BridgeError(
        error.code,
        error.message + (
            " The write may have completed on the Mac. Inspect the resource or reconcile"
            " with the bridge before retrying. If retrying, reuse this exact request_id"
            " with the exact same arguments; never use a new key for this operation."
            " No automatic retry was performed."
        ),
        **{**error.details, "request_id": request_id, "outcome": "unknown"},
    )


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

    def request(self, method: str, path: str, body=None, request_id=None):
        if method not in {"GET", "POST"} or not path.startswith("/api/v1/"):
            raise BridgeError("invalid_request", "Unsupported bridge request.")
        writing = method == "POST"
        if writing:
            if not isinstance(body, dict) or not isinstance(request_id, str) or not re.fullmatch(REQUEST_ID_PATTERN, request_id):
                raise BridgeError("invalid_request", "Writes require a JSON object and a stable 8–128 character request_id.")
        elif body is not None or request_id is not None:
            raise BridgeError("invalid_request", "Read requests cannot contain a body or request_id.")
        headers = {"Authorization": "Bearer " + self.config.token, "Accept": "application/json"}
        payload = None
        if writing:
            try:
                payload = json.dumps(body, ensure_ascii=False, allow_nan=False).encode("utf-8")
            except (TypeError, ValueError, UnicodeError):
                raise BridgeError("invalid_request", "Write body is not valid JSON.") from None
            headers.update({"Content-Type": "application/json", "Idempotency-Key": request_id})
        req = Request(self.config.url.rstrip("/") + path, method=method, headers=headers, data=payload)

        def failure(code, message, *, ambiguous=False, **details):
            error = BridgeError(code, message, **details)
            if writing and ambiguous:
                return unknown_write_error(error, request_id)
            return error

        deadline = time.monotonic() + self.config.timeout
        try:
            with self._opener.open(req, timeout=self.config.timeout) as response:
                if writing and response.status not in {200, 201}:
                    raise BridgeError("invalid_response", "Bridge did not confirm a completed write.")
                if response.headers.get_content_type() != "application/json":
                    raise BridgeError("invalid_response", "Bridge response must be JSON.")
                chunks = []
                size = 0
                while size <= MAX_RESPONSE_BYTES:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise TimeoutError()
                    # CPython's HTTPResponse exposes its socket here. Keep the
                    # fallback bounded by the configured inactivity timeout on
                    # other implementations; deadline checks still stop drips.
                    sock = getattr(getattr(getattr(response, "fp", None), "raw", None), "_sock", None)
                    if sock is not None:
                        sock.settimeout(remaining)
                    chunk = response.read1(min(65536, MAX_RESPONSE_BYTES + 1 - size))
                    if time.monotonic() > deadline:
                        raise TimeoutError()
                    if not chunk:
                        break
                    chunks.append(chunk)
                    size += len(chunk)
                raw = b"".join(chunks)
                if len(raw) > MAX_RESPONSE_BYTES:
                    raise BridgeError("response_too_large", "Bridge response exceeds the client limit; narrow the request.")
                try:
                    result = json.loads(raw.decode("utf-8"))
                except (ValueError, UnicodeError):
                    raise BridgeError("invalid_response", "Bridge returned invalid JSON.") from None
                if not isinstance(result, dict) or "data" not in result or "error" in result:
                    raise BridgeError("invalid_response", "Bridge response does not match the v1 envelope.")
                if writing:
                    data = result["data"]
                    if (
                        not isinstance(data, dict)
                        or data.get("request_id") != request_id
                        or data.get("state") != "saved"
                        or not isinstance(data.get("id"), str)
                        or not data["id"]
                    ):
                        raise BridgeError("invalid_response", "Bridge did not confirm this request_id, a saved state, and a resource ID.")
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
            # Only these contract statuses definitively reject a write before effects.
            definitive_rejections = {400, 401, 403, 404, 409, 413, 422, 429}
            raise failure(code, message, ambiguous=status not in definitive_rejections, http_status=status) from None
        except TimeoutError:
            raise failure("timeout", "Bridge request timed out.", ambiguous=True) from None
        except (URLError, OSError, HTTPException):
            raise failure("connection_failed", "Could not establish a verified connection to the bridge.", ambiguous=True) from None
        except BridgeError as exc:
            raise failure(exc.code, exc.message, ambiguous=True, **exc.details) from None
        except Exception:
            # Unexpected response/parser failures after dispatch also cannot
            # prove a write did not run. Never include arbitrary exception text.
            raise failure("client_error", "Could not verify the bridge response.", ambiguous=True) from None

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
        # Redact values before encoding so a token such as "true" or "1" cannot
        # replace JSON literals and turn a valid result into malformed JSON.
        def redact(value):
            if isinstance(value, str):
                return value.replace(self.config.token, "[REDACTED]")
            if isinstance(value, list):
                return [redact(item) for item in value]
            if isinstance(value, dict):
                return {redact(key): redact(item) for key, item in value.items()}
            return value
        return json.dumps(redact(result), ensure_ascii=False)
