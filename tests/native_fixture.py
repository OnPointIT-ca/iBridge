"""A native IPC contract fixture, never a substitute for real macOS validation."""

import json
import os
from pathlib import Path
import socketserver
import threading


class NativeFixture:
    def __init__(self, home):
        self.socket_path = Path(home) / "host.sock"
        self.calls = []
        self.saved_reminders = []
        self.drop_next_write_response = False
        fixture = self

        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                raw = self.rfile.readline(1024 * 1024 + 1)
                request = json.loads(raw)
                fixture.calls.append(request)
                result = fixture.dispatch(request)
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
        if operation == "system.capabilities":
            return {"operations": {name: {"available": True} for name in (
                "calendar.list", "calendar.events.list", "reminders.lists",
                "reminders.list", "reminders.create", "drive.roots", "drive.search",
            )}}
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
