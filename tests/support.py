"""Load a directory plugin as Hermes does, and serve local contract fixtures."""

import importlib.util
import json
import sys
import threading
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PLUGIN_DIR = Path(__file__).resolve().parents[1] / "plugins" / "hermes-ibridge"
spec = importlib.util.spec_from_file_location("ibridge_test_plugin", PLUGIN_DIR / "__init__.py", submodule_search_locations=[str(PLUGIN_DIR)])
plugin = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = plugin
spec.loader.exec_module(plugin)


@contextmanager
def server(responder):
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            raw_body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            record = {"method": self.command, "path": self.path, "headers": self.headers, "body": json.loads(raw_body) if raw_body else None}
            requests.append(record)
            response = responder(record)
            if response is None:
                # Simulate a connection lost after the server receives a write.
                self.close_connection = True
                return
            status, body, headers = response
            self.send_response(status)
            self.send_header("Content-Type", headers.get("Content-Type", "application/json"))
            for key, value in headers.items():
                if key != "Content-Type":
                    self.send_header(key, value)
            self.end_headers()
            try:
                if callable(body):
                    body(self.wfile)
                else:
                    payload = body if isinstance(body, bytes) else json.dumps(body).encode()
                    self.wfile.write(payload)
            except (BrokenPipeError, ConnectionResetError):
                pass

        do_POST = do_GET

        def log_message(self, *args):
            pass

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=httpd.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{httpd.server_port}", requests
    finally:
        httpd.shutdown()
        thread.join()
        httpd.server_close()


def capabilities(operations=None):
    return {"data": {"api_version": "1", "operations": operations or {}}, "meta": {"sync_state": "local"}}
