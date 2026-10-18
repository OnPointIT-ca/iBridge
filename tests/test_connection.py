import json
import os
import time
import unittest
from unittest.mock import patch

from support import capabilities, plugin, server
from ibridge_test_plugin.client import BridgeClient, BridgeError, Config, MAX_RESPONSE_BYTES


class ConfigTests(unittest.TestCase):
    def test_rejects_unsafe_origins_and_tokens(self):
        for url in ["", "http://mac.example", "file:///tmp/api", "https://user:pass@mac.test", "https://mac.test/api", "https://mac.test?x=1", "https://mac.test#x", "https://mac.test:bad", "https://mac.test\\@evil.test", "https://mac.test\n"]:
            with self.subTest(url=url), self.assertRaises(BridgeError):
                Config(url, "secret")
        for token in ["", "two words", "secret\nheader:value"]:
            with self.subTest(token=token), self.assertRaises(BridgeError):
                Config("https://mac.test", token)

    def test_loopback_http_requires_explicit_opt_in(self):
        with self.assertRaises(BridgeError):
            Config("http://127.0.0.1:1234", "secret")
        Config("http://127.0.0.1:1234", "secret", allow_local_http=True)
        with self.assertRaises(BridgeError):
            Config("http://100.64.0.1", "secret", allow_local_http=True)

    def test_timeout_and_repr(self):
        for timeout in [0, -1, 121, float("nan"), float("inf")]:
            with self.assertRaises(BridgeError):
                Config("https://mac.test", "secret", timeout)
        self.assertNotIn("secret", repr(Config("https://mac.test", "secret")))


class ConnectionTests(unittest.TestCase):
    def client(self, url, **kwargs):
        return BridgeClient(Config(url, "test-token", allow_local_http=True, **kwargs))

    def test_authenticated_discovery_and_handler_contract(self):
        with server(lambda _: (200, capabilities(), {})) as (url, requests):
            with patch.dict(os.environ, {"IBRIDGE_URL": url, "IBRIDGE_TOKEN": "test-token", "IBRIDGE_ALLOW_LOCAL_HTTP": "1"}):
                result = json.loads(plugin.tools.capabilities({}, task_id="hermes-context"))
            self.assertEqual(result["data"]["api_version"], "1")
            self.assertEqual(requests[0]["path"], "/api/v1/system/capabilities")
            self.assertEqual(requests[0]["headers"]["Authorization"], "Bearer test-token")

    def test_redirect_is_not_followed(self):
        with server(lambda _: (302, {}, {"Location": "/stolen"})) as (url, requests):
            with self.assertRaises(BridgeError) as caught:
                self.client(url).capabilities()
            self.assertEqual(caught.exception.code, "redirect_refused")
            self.assertEqual(len(requests), 1)

    def test_auth_error_is_sanitized(self):
        with server(lambda _: (401, {"error": {"message": "test-token private content"}}, {})) as (url, _):
            with self.assertRaises(BridgeError) as caught:
                self.client(url).capabilities()
            self.assertEqual(caught.exception.code, "authentication_failed")
            self.assertNotIn("test-token", json.dumps(caught.exception.result()))

    def test_invalid_responses(self):
        cases = [
            (200, b"not json", {}, "invalid_response"),
            (200, {}, {}, "invalid_response"),
            (200, {"data": {}, "error": {}}, {}, "invalid_response"),
            (200, capabilities(), {"Content-Type": "text/html"}, "invalid_response"),
            (200, {"data": {"api_version": "2", "operations": {}}}, {}, "incompatible_bridge"),
            (200, {"data": {"api_version": "1", "operations": []}}, {}, "invalid_response"),
            (200, b"x" * (MAX_RESPONSE_BYTES + 1), {}, "response_too_large"),
        ]
        for status, body, headers, expected in cases:
            with self.subTest(expected=expected), server(lambda _: (status, body, headers)) as (url, _):
                with self.assertRaises(BridgeError) as caught:
                    self.client(url).capabilities()
                self.assertEqual(caught.exception.code, expected)

    def test_timeout_is_bounded(self):
        def slow(_):
            time.sleep(0.15)
            return 200, capabilities(), {}
        with server(slow) as (url, requests):
            with self.assertRaises(BridgeError) as caught:
                self.client(url, timeout=0.03).capabilities()
            self.assertEqual(caught.exception.code, "timeout")
            self.assertEqual(len(requests), 1)

    def test_registration_is_offline_and_handler_errors_are_json(self):
        class Context:
            def __init__(self):
                self.tools = {}

            def register_tool(self, **kwargs):
                self.tools[kwargs["name"]] = kwargs
        context = Context()
        with patch.object(BridgeClient, "request", side_effect=AssertionError("network during registration")):
            plugin.register(context)
        self.assertIn("ibridge_capabilities", context.tools)
        self.assertEqual(json.loads(context.tools["ibridge_capabilities"]["handler"]({"url": "https://evil.test"}))["error"]["code"], "invalid_arguments")


if __name__ == "__main__":
    unittest.main()
