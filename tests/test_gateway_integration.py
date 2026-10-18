"""Hermes plugin -> real Node gateway -> local native IPC fixture."""

import json
import os
from pathlib import Path
import selectors
import shutil
import sqlite3
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

from support import plugin
from native_fixture import NativeFixture

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "gateway" / "dist" / "cli.js"
READY = CLI.exists() and shutil.which("node") is not None and hasattr(__import__("socket"), "AF_UNIX")
if os.environ.get("IBRIDGE_REQUIRE_GATEWAY_TESTS") == "1" and not READY:
    raise RuntimeError("Gateway integration tests are required: build gateway first and use Node.js 24+ on a Unix host.")


@unittest.skipUnless(READY, "Build gateway first to run real gateway/native-fixture integration tests")
class GatewayIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ib-e2e-")
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        self.env = {**os.environ, "IBRIDGE_HOME": str(self.home)}
        self.run_cli("init")
        self.native = NativeFixture(self.home).start()
        self.addCleanup(self.native.close)
        self.identity = self.run_cli(
            "client", "create", "--name", "Hermes integration fixture",
            "--operations", "calendar.list,calendar.events.list,reminders.lists,reminders.list,reminders.create,drive.roots,drive.search,notes.folders,notes.search,notes.read,notes.create,messages.chats,messages.search,messages.read",
            "--calendar-ids", "calendar-1", "--reminder-list-ids", "list-1", "--drive-root-ids", "root-1",
            "--note-folder-ids", "folder-1", "--message-chat-ids", "chat-1",
        )
        self.process = None
        self.addCleanup(self.stop_gateway)
        self.start_gateway()

    def run_cli(self, *arguments):
        result = subprocess.run(["node", str(CLI), *arguments], cwd=ROOT, env=self.env, capture_output=True, text=True, timeout=15)
        if result.returncode:
            self.fail("Gateway administration failed: " + result.stderr[-2000:])
        return json.loads(result.stdout)

    def start_gateway(self):
        self.errors = tempfile.TemporaryFile(mode="w+t")
        self.process = subprocess.Popen(["node", str(CLI), "serve", "--port", "0"], cwd=ROOT, env=self.env, stdout=subprocess.PIPE, stderr=self.errors, text=True, bufsize=1)
        deadline = time.monotonic() + 15
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdout, selectors.EVENT_READ)
            while time.monotonic() < deadline:
                if self.process.poll() is not None:
                    break
                if not selector.select(timeout=0.1):
                    continue
                line = self.process.stdout.readline()
                if not line:
                    break
                event = json.loads(line)
                if event.get("event") == "listening":
                    self.url = event["address"]
                    return
        self.errors.seek(0)
        self.fail("Gateway did not start: " + self.errors.read()[-2000:])

    def stop_gateway(self):
        if self.process is not None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
            self.process.stdout.close()
            self.errors.close()
            self.process = None

    def invoke(self, name, arguments):
        handler = plugin.tools.capabilities if name == "ibridge_capabilities" else plugin.tools.make_handler(next(op for op in plugin.OPERATIONS if op.name == name))
        with patch.dict(os.environ, {"IBRIDGE_URL": self.url, "IBRIDGE_TOKEN": self.identity["token"], "IBRIDGE_ALLOW_LOCAL_HTTP": "1"}):
            return json.loads(handler(arguments))

    def test_calendar_document_reminder_workflow(self):
        capabilities = self.invoke("ibridge_capabilities", {})
        self.assertEqual(capabilities["data"]["api_version"], "1")
        self.assertTrue(capabilities["data"]["operations"]["reminders.create"]["available"])
        events = self.invoke("ibridge_calendar_list_events", {"calendar_id": "calendar-1", "start": "2026-10-20T09:00:00-07:00", "end": "2026-10-20T17:00:00-07:00"})
        self.assertEqual(events["data"]["items"][0]["title"], "Project review")
        files = self.invoke("ibridge_drive_search", {"root_id": "root-1", "query": "plan"})
        path = files["data"]["items"][0]["path"]
        saved = self.invoke("ibridge_reminders_create", {"list_id": "list-1", "title": "Review project plan", "notes": "Authorized Drive file: " + path, "request_id": "workflow-fixture-001"})
        self.assertEqual(saved["data"]["state"], "saved")
        self.assertEqual(saved["data"]["request_id"], "workflow-fixture-001")
        self.assertEqual(saved["meta"]["sync_state"], "local")
        self.assertEqual(len(self.native.saved_reminders), 1)

    def test_completed_replay_survives_gateway_restart(self):
        args = {"list_id": "list-1", "title": "One reminder", "request_id": "restart-replay-001"}
        first = self.invoke("ibridge_reminders_create", args)
        self.stop_gateway()
        self.start_gateway()
        second = self.invoke("ibridge_reminders_create", args)
        self.assertEqual(first["data"], second["data"])
        self.assertEqual(self.native.count("reminders.create"), 1)
        conflict = self.invoke("ibridge_reminders_create", {**args, "title": "Changed content"})
        self.assertEqual(conflict["error"]["code"], "conflict")
        self.assertEqual(self.native.count("reminders.create"), 1)

    def test_lost_native_response_is_not_redispatched_after_restart(self):
        self.native.drop_next_write_response = True
        args = {"list_id": "list-1", "title": "Potentially saved", "request_id": "unknown-replay-001"}
        first = self.invoke("ibridge_reminders_create", args)
        self.assertEqual(first["error"]["outcome"], "unknown")
        self.stop_gateway()
        self.start_gateway()
        second = self.invoke("ibridge_reminders_create", args)
        self.assertEqual(second["error"]["outcome"], "unknown")
        self.assertEqual(second["error"]["request_id"], args["request_id"])
        self.assertEqual(self.native.count("reminders.create"), 1)

    def test_resource_policy_rejects_before_native_service_call(self):
        denied = self.invoke("ibridge_calendar_list_events", {"calendar_id": "another-calendar", "start": "2026-10-20T00:00:00Z", "end": "2026-10-21T00:00:00Z"})
        self.assertEqual(denied["error"]["code"], "permission_denied")
        self.assertEqual(self.native.count("calendar.events.list"), 0)
        denied = self.invoke("ibridge_reminders_create", {"list_id": "another-list", "title": "Forbidden", "request_id": "denied-resource-001"})
        self.assertEqual(denied["error"]["code"], "permission_denied")
        self.assertEqual(self.native.count("reminders.create"), 0)

    def test_client_revocation_blocks_existing_token(self):
        self.run_cli("client", "revoke", self.identity["client_id"])
        result = self.invoke("ibridge_capabilities", {})
        self.assertEqual(result["error"]["code"], "authentication_failed")

    def test_notes_and_messages_discovery_search_and_reads(self):
        capabilities = self.invoke("ibridge_capabilities", {})
        for operation in ("notes.folders", "notes.search", "notes.read", "notes.create",
                          "messages.chats", "messages.search", "messages.read"):
            self.assertTrue(capabilities["data"]["operations"][operation]["available"], operation)
        folders = self.invoke("ibridge_notes_folders", {})
        self.assertEqual([item["id"] for item in folders["data"]["items"]], ["folder-1"])
        chats = self.invoke("ibridge_messages_chats", {})
        self.assertEqual([item["id"] for item in chats["data"]["items"]], ["chat-1"])
        for optional_folder in ({}, {"folder_id": "folder-1"}):
            notes = self.invoke("ibridge_notes_search", {"query": "plan", **optional_folder})
            self.assertEqual([item["id"] for item in notes["data"]["items"]], ["note-1"])
        note = self.invoke("ibridge_notes_read", {"note_id": "note-1"})
        self.assertEqual(note["data"]["body"], "Review the project plan.")
        for optional_chat in ({}, {"chat_id": "chat-1"}):
            messages = self.invoke("ibridge_messages_search", {"query": "plan", **optional_chat})
            self.assertEqual([item["id"] for item in messages["data"]["items"]], ["message-1"])
        messages = self.invoke("ibridge_messages_read", {"chat_id": "chat-1"})
        self.assertEqual([item["id"] for item in messages["data"]["items"]], ["message-1"])
        self.assertEqual(messages["meta"]["sync_state"], "local")
        for call in self.native.calls:
            self.assertEqual(call["resources"]["note_folder_ids"], ["folder-1"])
            self.assertEqual(call["resources"]["message_chat_ids"], ["chat-1"])

    def test_notes_and_messages_cross_container_denial(self):
        for name, arguments, operation in (
            ("ibridge_notes_search", {"query": "plan", "folder_id": "private-folder"}, "notes.search"),
            ("ibridge_notes_create", {"folder_id": "private-folder", "title": "Denied", "body": "Text", "request_id": "denied-note-001"}, "notes.create"),
            ("ibridge_messages_search", {"query": "plan", "chat_id": "private-chat"}, "messages.search"),
            ("ibridge_messages_read", {"chat_id": "private-chat"}, "messages.read"),
        ):
            denied = self.invoke(name, arguments)
            self.assertEqual(denied["error"]["code"], "permission_denied", name)
            self.assertEqual(self.native.count(operation), 0)
        # A note ID has no folder argument: the fixture models native folder checks.
        denied = self.invoke("ibridge_notes_read", {"note_id": "private-note"})
        self.assertEqual(denied["error"]["code"], "permission_denied")
        self.assertEqual(self.native.count("notes.read"), 1)
        self.assertNotIn("Private note fixture", json.dumps(denied))
        self.assertEqual(self.run_cli("journal", "list")["requests"], [])

    def test_notes_creation_replays_after_restart_and_detects_changed_body(self):
        arguments = {"folder_id": "folder-1", "title": "Project note", "body": "One plain-text note.", "request_id": "notes-replay-001"}
        first = self.invoke("ibridge_notes_create", arguments)
        self.assertEqual(first["data"]["state"], "saved")
        self.assertEqual(first["meta"]["sync_state"], "local")
        self.stop_gateway()
        self.start_gateway()
        self.assertEqual(self.invoke("ibridge_notes_create", arguments), first)
        conflict = self.invoke("ibridge_notes_create", {**arguments, "body": "Changed body."})
        self.assertEqual(conflict["error"]["code"], "conflict")
        self.assertEqual(self.native.count("notes.create"), 1)
        self.assertEqual(len(self.native.saved_notes), 1)
        read = self.invoke("ibridge_notes_read", {"note_id": first["data"]["id"]})
        self.assertEqual(read["data"]["body"], arguments["body"])

    def test_notes_lost_response_is_not_redispatched_after_restart(self):
        self.native.drop_next_write_response = True
        arguments = {"folder_id": "folder-1", "title": "Possibly saved note", "body": "Do not retry.", "request_id": "notes-unknown-001"}
        first = self.invoke("ibridge_notes_create", arguments)
        self.assertEqual(first["error"]["outcome"], "unknown")
        self.stop_gateway()
        self.start_gateway()
        second = self.invoke("ibridge_notes_create", arguments)
        self.assertEqual(second["error"]["outcome"], "unknown")
        self.assertEqual(second["error"]["request_id"], arguments["request_id"])
        self.assertEqual(self.native.count("notes.create"), 1)
        self.assertEqual(len(self.native.saved_notes), 1)
        self.assertEqual(self.run_cli("journal", "list")["requests"][0]["state"], "unknown")

    def test_new_and_legacy_wildcard_clients_do_not_gain_notes_or_messages(self):
        ungranted = self.run_cli("client", "create", "--name", "No resource grants", "--operations", "*")
        legacy = self.run_cli("client", "create", "--name", "Pre-adapter policy", "--operations", "*")
        # Simulate resources persisted before the Notes/Messages fields existed.
        with sqlite3.connect(self.home / "gateway.sqlite") as database:
            database.execute("UPDATE clients SET resources=? WHERE id=?", (
                json.dumps({"calendar_ids": ["*"], "reminder_list_ids": ["*"], "drive_root_ids": ["*"]}),
                legacy["client_id"],
            ))
        self.stop_gateway()
        self.start_gateway()
        for identity in (ungranted, legacy):
            self.identity = identity
            capabilities = self.invoke("ibridge_capabilities", {})
            for operation in ("notes.folders", "notes.search", "notes.read", "notes.create",
                              "messages.chats", "messages.search", "messages.read"):
                self.assertEqual(capabilities["data"]["operations"][operation],
                                 {"available": False, "reason": "permission_denied"})
            for name, arguments in (
                ("ibridge_notes_folders", {}),
                ("ibridge_notes_search", {"query": "plan"}),
                ("ibridge_notes_read", {"note_id": "note-1"}),
                ("ibridge_notes_create", {"folder_id": "folder-1", "title": "Denied", "body": "Text", "request_id": "denied-legacy-001"}),
                ("ibridge_messages_chats", {}),
                ("ibridge_messages_search", {"query": "plan"}),
                ("ibridge_messages_read", {"chat_id": "chat-1"}),
            ):
                self.assertEqual(self.invoke(name, arguments)["error"]["code"], "operation_unavailable", name)
        self.assertTrue(all(call["operation"] == "system.capabilities" for call in self.native.calls))
        self.assertEqual(self.run_cli("journal", "list")["requests"], [])


if __name__ == "__main__":
    unittest.main()
