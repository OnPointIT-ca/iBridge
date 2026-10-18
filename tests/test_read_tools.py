import json
import os
import sys
import types
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

from support import capabilities, plugin, server
from ibridge_test_plugin.client import BridgeClient, Config
from ibridge_test_plugin.operations import OPERATIONS

BY_NAME = {operation.name: operation for operation in OPERATIONS}


class ReadToolsTests(unittest.TestCase):
    def invoke(self, name, args, url):
        with patch.dict(os.environ, {"IBRIDGE_URL": url, "IBRIDGE_TOKEN": "test-token", "IBRIDGE_ALLOW_LOCAL_HTTP": "1"}):
            return json.loads(plugin.tools.make_handler(BY_NAME[name])(args, session_id="hermes-session"))

    def fixture(self, record):
        if record["path"] == "/api/v1/system/capabilities":
            return 200, capabilities({op.capability: {"available": True} for op in OPERATIONS}), {}
        return 200, {"data": {"items": [], "next_cursor": "next-page"}, "meta": {"sync_state": "local", "observed_at": "2026-10-17T12:00:00Z"}}, {}

    def test_each_read_tool_reaches_its_contract_route(self):
        cases = [
            ("ibridge_calendar_list", {}, "/calendars"),
            ("ibridge_calendar_list_events", {"calendar_id": "cal", "start": "2026-10-17T00:00:00Z", "end": "2026-10-18T00:00:00Z"}, "/events"),
            ("ibridge_reminders_lists", {}, "/reminders/lists"),
            ("ibridge_reminders_list", {"list_id": "list"}, "/reminders"),
            ("ibridge_contacts_search", {"query": "Ada"}, "/contacts"),
            ("ibridge_drive_roots", {}, "/drive/roots"),
            ("ibridge_drive_list", {"root_id": "root"}, "/drive/files"),
            ("ibridge_drive_search", {"root_id": "root", "query": "pdf"}, "/drive/search"),
            ("ibridge_drive_read", {"root_id": "root", "path": "report.pdf"}, "/drive/content"),
            ("ibridge_notes_folders", {}, "/notes/folders"),
            ("ibridge_notes_search", {"query": "meeting"}, "/notes"),
            ("ibridge_notes_read", {"note_id": "note-1"}, "/notes/note-1"),
            ("ibridge_messages_chats", {}, "/messages/chats"),
            ("ibridge_messages_search", {"query": "hello"}, "/messages/search"),
            ("ibridge_messages_read", {"chat_id": "chat-1"}, "/messages/chats/chat-1/messages"),
        ]
        with server(self.fixture) as (url, requests):
            for name, args, path in cases:
                with self.subTest(name=name):
                    result = self.invoke(name, args, url)
                    self.assertEqual(result["meta"]["sync_state"], "local")
                    self.assertEqual(urlsplit(requests[-1]["path"]).path, "/api/v1" + path)
                    self.assertEqual(requests[-1]["headers"]["Authorization"], "Bearer test-token")
                    self.assertEqual(requests[-2]["path"], "/api/v1/system/capabilities")

    def test_capability_denial_prevents_service_call(self):
        for entry in [None, {"available": False}, {"available": "true"}, {"available": 1}]:
            with self.subTest(entry=entry), server(lambda _: (200, capabilities({"contacts.search": entry}), {})) as (url, requests):
                result = self.invoke("ibridge_contacts_search", {"query": "Ada"}, url)
                self.assertEqual(result["error"]["code"], "operation_unavailable")
                self.assertEqual(len(requests), 1)

    def test_permission_revocation_after_discovery(self):
        def revoked(record):
            if record["path"] == "/api/v1/system/capabilities":
                return self.fixture(record)
            return 403, {"error": {"message": "revoked"}}, {}
        with server(revoked) as (url, _):
            result = self.invoke("ibridge_contacts_search", {"query": "Ada"}, url)
            self.assertEqual(result["error"]["code"], "permission_denied")

    def test_arguments_are_encoded_not_interpreted_as_routes(self):
        with server(self.fixture) as (url, requests):
            text = "Ada & limit=100 # /? snowman ☃"
            self.invoke("ibridge_contacts_search", {"query": text, "cursor": "abc+/="}, url)
            query = parse_qs(urlsplit(requests[-1]["path"]).query)
            self.assertEqual(query, {"query": [text], "cursor": ["abc+/="], "limit": ["50"]})
            self.invoke("ibridge_notes_read", {"note_id": "x-coredata://note/a?b#c"}, url)
            self.assertEqual(requests[-1]["path"], "/api/v1/notes/x-coredata%3A%2F%2Fnote%2Fa%3Fb%23c")
            self.invoke("ibridge_reminders_list", {"list_id": "list", "completed": False}, url)
            self.assertEqual(parse_qs(urlsplit(requests[-1]["path"]).query)["completed"], ["false"])

    def test_invalid_inputs_never_reach_network(self):
        cases = [
            ("ibridge_contacts_search", {}),
            ("ibridge_contacts_search", {"query": "Ada", "url": "https://evil.test"}),
            ("ibridge_contacts_search", {"query": "Ada", "limit": True}),
            ("ibridge_contacts_search", {"query": "Ada", "limit": 101}),
            ("ibridge_contacts_search", {"query": "x" * 1001}),
            ("ibridge_notes_read", {"note_id": ".."}),
            ("ibridge_reminders_list", {"list_id": "list", "completed": "false"}),
            ("ibridge_drive_read", {"root_id": "root", "path": ""}),
            ("ibridge_drive_read", {"root_id": "root", "path": "../../secret"}),
            ("ibridge_drive_read", {"root_id": "root", "path": "/etc/passwd"}),
            ("ibridge_drive_read", {"root_id": "root", "path": "a\\b"}),
            ("ibridge_calendar_list_events", {"calendar_id": "cal", "start": "tomorrow", "end": "2026-10-18T00:00:00Z"}),
            ("ibridge_calendar_list_events", {"calendar_id": "cal", "start": "2026-10-18T00:00:00", "end": "2026-10-19T00:00:00Z"}),
            ("ibridge_calendar_list_events", {"calendar_id": "cal", "start": "2026-10-18T00:00:00Z", "end": "2026-10-17T00:00:00Z"}),
            ("ibridge_calendar_list_events", {"calendar_id": "cal", "start": "2026-01-01T00:00:00Z", "end": "2027-01-02T00:00:01Z"}),
        ]
        with patch.object(BridgeClient, "request") as network:
            for name, args in cases:
                with self.subTest(name=name, args=args):
                    result = self.invoke(name, args, "https://mac.example")
                    self.assertEqual(result["error"]["code"], "invalid_arguments")
            network.assert_not_called()

    def test_scoped_secret_is_used_and_denial_does_not_fall_back(self):
        scope = types.ModuleType("agent.secret_scope")
        scope.get_secret = lambda name: {"IBRIDGE_URL": "https://scoped.example", "IBRIDGE_TOKEN": "scoped-token"}.get(name)
        with patch.dict(sys.modules, {"agent.secret_scope": scope}), patch.dict(os.environ, {"IBRIDGE_TOKEN": "unscoped-token"}):
            self.assertEqual(Config.from_env().token, "scoped-token")
            scope.get_secret = lambda _: None
            with self.assertRaises(Exception):
                Config.from_env()

    def test_secret_echo_is_redacted_and_metadata_survives(self):
        result = BridgeClient(Config("https://mac.test", "test-token")).render({"data": "echo test-token", "meta": {"sync_state": "local"}})
        self.assertNotIn("test-token", result)
        self.assertEqual(json.loads(result)["meta"]["sync_state"], "local")


if __name__ == "__main__":
    unittest.main()
