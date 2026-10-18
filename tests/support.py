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
            record = {"method": self.command, "path": self.path, "headers": self.headers, "body": None}
            requests.append(record)
            status, body, headers = responder(record)
            self.send_response(status)
            self.send_header("Content-Type", headers.get("Content-Type", "application/json"))
            for key, value in headers.items():
                if key != "Content-Type":
                    self.send_header(key, value)
            self.end_headers()
            payload = body if isinstance(body, bytes) else json.dumps(body).encode()
            try:
                self.wfile.write(payload)
            except (BrokenPipeError, ConnectionResetError):
                pass

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
