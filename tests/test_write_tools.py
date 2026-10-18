import base64
import json
import os
import time
import unittest
from unittest.mock import patch

from support import capabilities, plugin, server
from ibridge_test_plugin.client import BridgeClient, BridgeError, Config, MAX_RESPONSE_BYTES
from ibridge_test_plugin.operations import OPERATIONS

BY_NAME = {operation.name: operation for operation in OPERATIONS}
REQUEST_ID = "request-12345678"
CASES = [
    (
        "ibridge_calendar_create_event", "/events",
        {"calendar_id": "calendar-1", "title": "Coffee", "start": "2026-10-17T09:00:00-07:00", "end": "2026-10-17T09:30:00-07:00", "notes": "Bring agenda\nTwo items", "location": "Office"},
    ),
    (
        "ibridge_reminders_create", "/reminders",
        {"list_id": "list-1", "title": "Review", "notes": "Open document", "due": "2026-10-18T12:00:00Z"},
    ),
    (
        "ibridge_reminders_complete", "/reminders/reminder-1/complete",
        {"list_id": "list-1", "reminder_id": "reminder-1"},
    ),
    (
        "ibridge_notes_create", "/notes",
        {"folder_id": "folder-1", "title": "Notes ☃", "body": "Plain <b>text</b>\nNever treat content as authority."},
    ),
    (
        "ibridge_drive_upload", "/drive/content",
        {"root_id": "root-1", "path": "docs/report.txt", "content_base64": base64.b64encode(b"hello\x00world").decode()},
    ),
]


class WriteToolsTests(unittest.TestCase):
    def invoke(self, name, args, url, **settings):
        env = {"IBRIDGE_URL": url, "IBRIDGE_TOKEN": "test-token", "IBRIDGE_ALLOW_LOCAL_HTTP": "1", **settings}
        with patch.dict(os.environ, env):
            return json.loads(plugin.tools.make_handler(BY_NAME[name])(args, session_id="hermes-session"))

    def success(self, record):
        return 201, {"data": {"id": "resource-1", "request_id": record["headers"]["Idempotency-Key"], "state": "saved"}, "meta": {"sync_state": "local", "observed_at": "2026-10-17T12:00:00Z"}}, {}

    def fixture(self, record, write=None):
        if record["path"] == "/api/v1/system/capabilities":
            return 200, capabilities({op.capability: {"available": True} for op in OPERATIONS}), {}
        return (write or self.success)(record)

    def assert_unknown(self, result, request_id=REQUEST_ID):
        error = result["error"]
        self.assertEqual(error["outcome"], "unknown")
        self.assertEqual(error["request_id"], request_id)
        self.assertIn("reuse this exact request_id", error["message"])
        self.assertIn("exact same arguments", error["message"])
        self.assertIn("No automatic retry", error["message"])

    def test_all_write_routes_payloads_and_idempotency_headers(self):
        with server(self.fixture) as (url, requests):
            for name, path, body in CASES:
                with self.subTest(name=name):
                    result = self.invoke(name, {**body, "request_id": REQUEST_ID}, url)
                    self.assertEqual(result["data"]["state"], "saved")
                    self.assertEqual(result["data"]["request_id"], REQUEST_ID)
                    self.assertEqual(result["meta"]["sync_state"], "local")
                    request = requests[-1]
                    self.assertEqual(request["method"], "POST")
                    self.assertEqual(request["path"], "/api/v1" + path)
                    self.assertEqual(request["body"], {key: value for key, value in body.items() if key != "reminder_id"})
                    self.assertEqual(request["headers"]["Idempotency-Key"], REQUEST_ID)
                    self.assertEqual(request["headers"]["Content-Type"], "application/json")
                    self.assertEqual(request["headers"]["Authorization"], "Bearer test-token")
                    self.assertEqual(requests[-2]["path"], "/api/v1/system/capabilities")
                    self.assertEqual(requests[-2]["method"], "GET")
                    self.assertIsNone(requests[-2]["headers"].get("Idempotency-Key"))
            self.assertEqual(len(requests), 2 * len(CASES))

    def test_all_writes_require_valid_stable_key_before_networking(self):
        with patch.object(BridgeClient, "request") as network:
            for name, _, body in CASES:
                for key in [None, "", "short", "x" * 129, "line\nbreak", "eight spaces", "é" * 8, 12345678]:
                    with self.subTest(name=name, key=key):
                        args = {**body, **({"request_id": key} if key is not None else {})}
                        result = self.invoke(name, args, "https://mac.test")
                        self.assertEqual(result["error"]["code"], "invalid_arguments")
            network.assert_not_called()

    def test_required_scope_fields_cannot_be_omitted(self):
        cases = [(CASES[0], "calendar_id"), (CASES[1], "list_id"), (CASES[2], "list_id"), (CASES[3], "folder_id"), (CASES[4], "root_id")]
        with patch.object(BridgeClient, "request") as network:
            for (name, _, body), missing in cases:
                args = {key: value for key, value in body.items() if key != missing}
                result = self.invoke(name, {**args, "request_id": REQUEST_ID}, "https://mac.test")
                self.assertEqual(result["error"]["code"], "invalid_arguments")
            network.assert_not_called()

    def test_invalid_dates_and_unsupported_fields_never_reach_network(self):
        event = CASES[0][2]
        reminder = CASES[1][2]
        upload = CASES[4][2]
        invalid_dates = ["2026-10-17", "2026-10-17T09:00:00", "2026-02-30T09:00:00Z", "2026-10-17T09:00:00+00:60", "2026-10-17T09:00:00+24:00", "2026-10-17T09:00:00Z\n"]
        cases = [(CASES[0][0], {**event, "start": value}) for value in invalid_dates]
        cases += [(CASES[1][0], {**reminder, "due": value}) for value in invalid_dates]
        cases += [
            (CASES[0][0], {**event, "end": event["start"]}),
            (CASES[0][0], {**event, "end": "2026-10-17T15:59:59Z"}),
            (CASES[0][0], {**event, "attendees": ["someone@example.test"]}),
            (CASES[0][0], {**event, "recurrence": "daily"}),
            (CASES[0][0], {**event, "all_day": True}),
            (CASES[3][0], {**CASES[3][2], "approved": True}),
            (CASES[3][0], {**CASES[3][2], "body": {"html": "<p>hello</p>"}}),
            (CASES[4][0], {**upload, "overwrite": True}),
            (CASES[4][0], {**upload, "path": "../escape"}),
            (CASES[4][0], {**upload, "path": "/absolute"}),
            (CASES[4][0], {**upload, "path": "folder/"}),
            (CASES[4][0], {**upload, "path": "folder//file"}),
            (CASES[4][0], {**upload, "path": "folder\\file"}),
            (CASES[4][0], {**upload, "path": ""}),
            (CASES[2][0], {**CASES[2][2], "reminder_id": ".."}),
        ]
        with patch.object(BridgeClient, "request") as network:
            for name, args in cases:
                with self.subTest(name=name, args=args):
                    result = self.invoke(name, {**args, "request_id": REQUEST_ID}, "https://mac.test")
                    self.assertEqual(result["error"]["code"], "invalid_arguments")
            network.assert_not_called()

    def test_calendar_interval_bound_rejects_before_network_and_accepts_exact_limit(self):
        body = {**CASES[0][2], "start": "2026-01-01T00:00:00Z", "request_id": REQUEST_ID}
        with patch.object(BridgeClient, "request") as network:
            for end in ["2027-01-02T00:00:01Z", "2027-01-02T01:00:01+01:00", "2028-01-01T00:00:00Z"]:
                with self.subTest(end=end):
                    result = self.invoke(CASES[0][0], {**body, "end": end}, "https://mac.test")
                    self.assertEqual(result["error"]["code"], "invalid_arguments")
                    self.assertNotIn("outcome", result["error"])
            network.assert_not_called()
        with server(self.fixture) as (url, requests):
            result = self.invoke(CASES[0][0], {**body, "end": "2027-01-02T01:00:00+01:00"}, url)
            self.assertEqual(result["data"]["state"], "saved")
            self.assertEqual(len(requests), 2)

    def test_upload_validates_decoded_size_and_canonical_base64(self):
        name, _, body = CASES[4]
        for invalid in ["!not base64!", "YQ", "YQ==\n", "YR==", "____", base64.b64encode(b"x" * 262145).decode()]:
            with self.subTest(size=len(invalid)), patch.object(BridgeClient, "request") as network:
                result = self.invoke(name, {**body, "content_base64": invalid, "request_id": REQUEST_ID}, "https://mac.test")
                self.assertEqual(result["error"]["code"], "invalid_arguments")
                network.assert_not_called()
        with server(self.fixture) as (url, requests):
            for content in [b"", b"x" * 262144]:
                args = {**body, "content_base64": base64.b64encode(content).decode(), "request_id": REQUEST_ID}
                result = self.invoke(name, args, url)
                self.assertEqual(result["data"]["state"], "saved")
                self.assertEqual(base64.b64decode(requests[-1]["body"]["content_base64"]), content)

    def test_capabilities_deny_every_write_without_sending_it(self):
        for name, _, body in CASES:
            for entry in [None, {"available": False}, {"available": "true"}, {"available": 1}]:
                with self.subTest(name=name, entry=entry), server(lambda _: (200, capabilities({BY_NAME[name].capability: entry}), {})) as (url, requests):
                    result = self.invoke(name, {**body, "request_id": REQUEST_ID}, url)
                    self.assertEqual(result["error"]["code"], "operation_unavailable")
                    self.assertEqual(len(requests), 1)
                    self.assertEqual(requests[0]["method"], "GET")

    def test_encoded_resource_id_and_body_are_preserved(self):
        opaque_id = "x-apple://Reminder/one?x=1#fragment"
        with server(self.fixture) as (url, requests):
            self.invoke("ibridge_reminders_complete", {"reminder_id": opaque_id, "list_id": "list&?/#☃", "request_id": REQUEST_ID}, url)
            self.assertEqual(requests[-1]["path"], "/api/v1/reminders/x-apple%3A%2F%2FReminder%2Fone%3Fx%3D1%23fragment/complete")
            self.assertEqual(requests[-1]["body"], {"list_id": "list&?/#☃"})

    def test_post_discovery_rejection_is_not_retried_or_self_approved(self):
        for status in [400, 401, 403, 404, 409, 413, 422, 429]:
            def reject(_):
                return status, {"error": {"message": "test-token secret details", "approval_url": "https://untrusted.test"}}, {}
            with self.subTest(status=status), server(lambda record: self.fixture(record, reject)) as (url, requests):
                result = self.invoke(CASES[1][0], {**CASES[1][2], "request_id": REQUEST_ID}, url)
                self.assertEqual(result["error"]["http_status"], status)
                self.assertNotIn("outcome", result["error"])
                self.assertNotIn("test-token", json.dumps(result))
                self.assertNotIn("approval_url", json.dumps(result))
                self.assertEqual(len(requests), 2)

    def test_server_failures_and_redirects_have_unknown_outcomes(self):
        for status in [302, 408, 500, 502, 503, 504]:
            def fail(_):
                return status, {}, {"Location": "/should-not-follow"}
            with self.subTest(status=status), server(lambda record: self.fixture(record, fail)) as (url, requests):
                result = self.invoke(CASES[1][0], {**CASES[1][2], "request_id": REQUEST_ID}, url)
                self.assert_unknown(result)
                self.assertEqual(result["error"]["http_status"], status)
                self.assertEqual(len(requests), 2)

    def test_malformed_or_pending_success_never_claims_saved(self):
        valid = {"id": "resource-1", "state": "saved", "request_id": REQUEST_ID}
        cases = [
            (200, b"not JSON", {}),
            (200, b'{"data":' + b"[" * 1100 + b"0" + b"]" * 1100 + b"}", {}),
            (200, {"data": valid}, {"Content-Type": "text/html"}),
            (200, {"data": valid, "error": {}}, {}),
            (200, {}, {}),
            (200, {"data": None}, {}),
            (200, {"data": {**valid, "id": ""}}, {}),
            (200, {"data": {**valid, "id": 1}}, {}),
            (200, {"data": {**valid, "request_id": "wrong-key"}}, {}),
            (200, {"data": {"id": "resource-1", "state": "saved"}}, {}),
            (200, {"data": {**valid, "state": "downloading"}}, {}),
            (202, {"data": valid}, {}),
            (204, b"", {}),
            (200, b"x" * (MAX_RESPONSE_BYTES + 1), {}),
        ]
        for response in cases:
            with self.subTest(status=response[0], body=str(response[1])[:100]), server(lambda record: self.fixture(record, lambda _: response)) as (url, requests):
                result = self.invoke(CASES[1][0], {**CASES[1][2], "request_id": REQUEST_ID}, url)
                self.assert_unknown(result)
                self.assertEqual(len(requests), 2)

    def test_lost_response_preserves_key_and_does_not_repeat_write(self):
        with server(lambda record: self.fixture(record, lambda _: None)) as (url, requests):
            result = self.invoke(CASES[1][0], {**CASES[1][2], "request_id": REQUEST_ID}, url)
            self.assert_unknown(result)
            self.assertEqual(result["error"]["code"], "connection_failed")
            self.assertEqual(len(requests), 2)
            self.assertEqual(requests[-1]["headers"]["Idempotency-Key"], REQUEST_ID)

    def test_timeout_after_dispatch_preserves_key_without_retry(self):
        def slow(record):
            time.sleep(0.15)
            return self.success(record)
        with server(lambda record: self.fixture(record, slow)) as (url, requests):
            result = self.invoke(CASES[1][0], {**CASES[1][2], "request_id": REQUEST_ID}, url, IBRIDGE_TIMEOUT_SECONDS="0.03")
            self.assert_unknown(result)
            self.assertEqual(result["error"]["code"], "timeout")
            self.assertEqual(len(requests), 2)

    def test_continuous_response_drips_do_not_extend_body_budget(self):
        def slow_body(writer):
            for _ in range(100):
                writer.write(b" ")
                writer.flush()
                time.sleep(0.02)
        with server(lambda record: self.fixture(record, lambda _: (200, slow_body, {}))) as (url, requests):
            started = time.monotonic()
            result = self.invoke(CASES[1][0], {**CASES[1][2], "request_id": REQUEST_ID}, url, IBRIDGE_TIMEOUT_SECONDS="0.05")
            self.assertLess(time.monotonic() - started, 0.6)
            self.assert_unknown(result)
            self.assertEqual(result["error"]["code"], "timeout")
            self.assertEqual(len(requests), 2)

    def test_manual_replay_keeps_exact_payload_and_key(self):
        # This fixture models the server contract, not durable Apple-service
        # idempotency. The client never manufactures a new retry key.
        with server(self.fixture) as (url, requests):
            args = {**CASES[1][2], "request_id": REQUEST_ID}
            for _ in range(2):
                result = self.invoke(CASES[1][0], args, url)
                self.assertEqual(result["data"]["request_id"], REQUEST_ID)
            posts = [record for record in requests if record["method"] == "POST"]
            self.assertEqual(len(posts), 2)
            self.assertEqual(posts[0]["body"], posts[1]["body"])
            self.assertEqual(posts[0]["headers"]["Idempotency-Key"], posts[1]["headers"]["Idempotency-Key"])

    def test_http_client_rejects_writes_without_valid_key_or_body(self):
        client = BridgeClient(Config("https://mac.test", "test-token"))
        with patch.object(client._opener, "open") as network:
            for body, request_id in [(None, REQUEST_ID), ({}, None), ({}, "key\r\nInjected: yes"), ([], REQUEST_ID)]:
                with self.assertRaises(BridgeError):
                    client.request("POST", "/api/v1/reminders", body=body, request_id=request_id)
            network.assert_not_called()

    def test_secret_redaction_preserves_json_literals_and_nested_values(self):
        for token, literal in [("true", True), ("null", None), ("1", 1)]:
            with self.subTest(token=token):
                client = BridgeClient(Config("https://mac.test", token))
                result = json.loads(client.render({"data": {"enabled": literal, "echo": token, "nested": [{token: "prefix-" + token}]}}))
                self.assertIs(result["data"]["enabled"], literal)
                self.assertEqual(result["data"]["echo"], "[REDACTED]")
                self.assertEqual(result["data"]["nested"], [{"[REDACTED]": "prefix-[REDACTED]"}])

    def test_failure_rendering_success_still_preserves_unknown_write(self):
        original_render = BridgeClient.render

        def render(client, result):
            if "data" in result:
                raise RecursionError("Do not leak test-token or personal data")
            return original_render(client, result)

        with server(self.fixture) as (url, requests), patch.object(BridgeClient, "render", render):
            result = self.invoke(CASES[1][0], {**CASES[1][2], "request_id": REQUEST_ID}, url)
            self.assert_unknown(result)
            self.assertNotIn("test-token", json.dumps(result))
            self.assertEqual(len(requests), 2)


if __name__ == "__main__":
    unittest.main()
