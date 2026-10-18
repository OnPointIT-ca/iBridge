"""A native IPC contract fixture, never a substitute for real macOS validation."""

import json
import os
from pathlib import Path
import socketserver
import threading


class FixtureRejection(Exception):
    def __init__(self, code, status=403):
        self.code = code
        self.status = status


class NativeFixture:
    def __init__(self, home):
        self.socket_path = Path(home) / "host.sock"
        self.calls = []
        self.saved_reminders = []
        self.saved_notes = []
        self.notes = [
            {"id": "note-1", "folder_id": "folder-1", "title": "Project plan", "body": "Review the project plan."},
            {"id": "private-note", "folder_id": "private-folder", "title": "Private plan", "body": "Private note fixture."},
        ]
        self.messages = [
            {"id": "message-1", "chat_id": "chat-1", "text": "Review the project plan."},
            {"id": "private-message", "chat_id": "private-chat", "text": "Private plan fixture."},
        ]
        self.drop_next_write_response = False
        fixture = self

        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                raw = self.rfile.readline(1024 * 1024 + 1)
                request = json.loads(raw)
                fixture.calls.append(request)
                try:
                    result = fixture.dispatch(request)
                except FixtureRejection as error:
                    self.wfile.write(json.dumps({"id": request["id"], "error": {
                        "code": error.code, "status": error.status,
                        "message": "Synthetic fixture rejection.", "outcome": "none",
                    }}).encode() + b"\n")
                    return
                if result is not None:
                    self.wfile.write(json.dumps({"id": request["id"], "result": result}).encode() + b"\n")

        class Server(socketserver.ThreadingUnixStreamServer):
            daemon_threads = True

        self.server = Server(str(self.socket_path), Handler)
        os.chmod(self.socket_path, 0o600)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)

    def start(self):
        self.thread.start()
        return self

    def close(self):
        self.server.shutdown()
        self.thread.join()
        self.server.server_close()
        self.socket_path.unlink(missing_ok=True)

    def count(self, operation):
        return sum(call["operation"] == operation for call in self.calls)

    def dispatch(self, request):
        operation = request["operation"]
        arguments = request["arguments"]
        resources = request["resources"]

        def allows(key, identifier):
            allowed = resources.get(key, [])
            return "*" in allowed or identifier in allowed

        if operation == "system.capabilities":
            return {"operations": {name: {"available": True} for name in (
                "calendar.list", "calendar.events.list", "reminders.lists",
                "reminders.list", "reminders.create", "drive.roots", "drive.search",
                "notes.folders", "notes.search", "notes.read", "notes.create",
                "messages.chats", "messages.search", "messages.read",
            )}}
        if operation.startswith("notes."):
            if not resources.get("note_folder_ids"):
                raise FixtureRejection("permission_denied")
            folder = arguments.get("folder_id")
            if folder is not None and not allows("note_folder_ids", folder):
                raise FixtureRejection("permission_denied")
            if operation == "notes.folders":
                return {"items": [item for item in (
                    {"id": "folder-1", "name": "Project notes"},
                    {"id": "private-folder", "name": "Private notes"},
                ) if allows("note_folder_ids", item["id"])]}
            notes = self.notes + self.saved_notes
            if operation == "notes.search":
                return {"items": [note for note in notes
                    if allows("note_folder_ids", note["folder_id"])
                    and (folder is None or note["folder_id"] == folder)
                    and arguments["query"].casefold() in (note["title"] + " " + note["body"]).casefold()
                ][:arguments.get("limit", 50)]}
            if operation == "notes.read":
                note = next((note for note in notes if note["id"] == arguments["note_id"]), None)
                if note is None:
                    raise FixtureRejection("not_found", 404)
                # The native adapter, not the gateway, resolves a note's actual folder.
                if not allows("note_folder_ids", note["folder_id"]):
                    raise FixtureRejection("permission_denied")
                return note
            if operation == "notes.create":
                resource_id = "saved-note-" + str(len(self.saved_notes) + 1)
                self.saved_notes.append({"id": resource_id, **arguments})
                if self.drop_next_write_response:
                    self.drop_next_write_response = False
                    return None
                return {"id": resource_id, "state": "saved"}
        if operation.startswith("messages."):
            if not resources.get("message_chat_ids"):
                raise FixtureRejection("permission_denied")
            chat = arguments.get("chat_id")
            if chat is not None and not allows("message_chat_ids", chat):
                raise FixtureRejection("permission_denied")
            if operation == "messages.chats":
                return {"items": [item for item in (
                    {"id": "chat-1", "name": "Project chat"},
                    {"id": "private-chat", "name": "Private chat"},
                ) if allows("message_chat_ids", item["id"])]}
            if operation in ("messages.search", "messages.read"):
                return {"items": [message for message in self.messages
                    if allows("message_chat_ids", message["chat_id"])
                    and (chat is None or message["chat_id"] == chat)
                    and (operation == "messages.read" or arguments["query"].casefold() in message["text"].casefold())
                ][:arguments.get("limit", 50)]}
        if operation == "calendar.list":
            return {"items": [{"id": "calendar-1", "name": "Personal"}]}
        if operation == "calendar.events.list":
            return {"items": [{"id": "event-1", "title": "Project review", "start": arguments["start"], "end": arguments["end"]}]}
        if operation == "reminders.lists":
            return {"items": [{"id": "list-1", "name": "Tasks"}]}
        if operation == "reminders.list":
            return {"items": list(self.saved_reminders)}
        if operation == "drive.roots":
            return {"items": [{"id": "root-1", "name": "Project files"}]}
        if operation == "drive.search":
            return {"items": [{"id": "file-1", "name": "plan.pdf", "path": "plan.pdf", "root_id": "root-1"}]}
        if operation == "reminders.create":
            resource_id = "reminder-" + str(len(self.saved_reminders) + 1)
            self.saved_reminders.append({"id": resource_id, **arguments})
            if self.drop_next_write_response:
                self.drop_next_write_response = False
                return None
            return {"id": resource_id, "state": "saved"}
        raise AssertionError(f"Fixture received unexpected operation: {operation}")
