"""Actual CLI caller sees refused and truly lost cleanup responses over loopback HTTP."""
import http.server
import json
import os
from pathlib import Path
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.request
from test_surface_panel_demo import mapping, TOKEN
from surface_control import SurfaceError
from surface_control_testing import TestOnlyHardwareHost


class PanelCLICleanupTests(unittest.TestCase):
    def test_cli_cleanup_refusal_and_lost_response_are_nonzero_without_replay(self):
        for failure in ("refused", "lost"):
            with self.subTest(failure=failure), TestOnlyHardwareHost(TOKEN) as host, tempfile.TemporaryDirectory() as scratch:
                original = host.tool
                cleanup = []
                def is_cleanup(request):
                    params = request.get("params", {})
                    args = params.get("arguments", {})
                    return request.get("method") == "tools/call" and params.get("name") == "surface_control_feedback" and args.get("control_id") == "button" and args.get("value") == "off"
                def tool(name, arguments):
                    if failure == "refused" and name == "surface_control_feedback" and arguments.get("control_id") == "button" and arguments.get("value") == "off":
                        raise SurfaceError("permission_denied")
                    return original(name, arguments)
                host.tool = tool
                class Handler(http.server.BaseHTTPRequestHandler):
                    def log_message(self, *_): pass
                    def do_POST(self):
                        body = self.rfile.read(int(self.headers["Content-Length"]))
                        request = json.loads(body)
                        upstream = urllib.request.Request(host.url, data=body, headers={key: value for key, value in self.headers.items() if key.lower() not in ("host", "content-length")})
                        with urllib.request.urlopen(upstream, timeout=2) as response:
                            output, status, content_type = response.read(), response.status, response.headers.get("Content-Type", "application/json")
                        if is_cleanup(request):
                            cleanup.append(request)
                            if failure == "lost":
                                self.connection.shutdown(socket.SHUT_RDWR)
                                self.connection.close()
                                return
                        self.send_response(status); self.send_header("Content-Type", content_type)
                        self.send_header("Content-Length", str(len(output))); self.send_header("Mcp-Session-Id", "test-only-session")
                        self.end_headers(); self.wfile.write(output)
                class Server(http.server.ThreadingHTTPServer):
                    # Numeric loopback only: no reverse DNS on the test's critical path.
                    def server_bind(self):
                        socketserver.TCPServer.server_bind(self)
                        self.server_name, self.server_port = self.server_address
                proxy = Server(("127.0.0.1", 0), Handler)
                thread = threading.Thread(target=proxy.serve_forever, daemon=True); thread.start()
                try:
                    map_path = Path(scratch) / "mapping.json"; map_path.write_text(json.dumps(mapping(host.profile)))
                    read, write = os.pipe(); os.write(write, TOKEN.encode()); os.close(write)
                    argv = [sys.executable, "-B", "-m", "surface_panel_demo", "--url", "http://127.0.0.1:" + str(proxy.server_port) + "/mcp",
                            "--instance-id", host.instance_id, "--mapping", str(map_path), "--source", "hardware", "--duration", "0.05", "--hz", "10", "--token-fd", str(read)]
                    try:
                        result = subprocess.run(argv, pass_fds=(read,), capture_output=True, env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1", "PYTHONPATH": str(Path(__file__).resolve().parents[1])}, timeout=5)
                    finally:
                        os.close(read)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    report = json.loads(result.stdout)
                    self.assertEqual(report["cleanup_failed"], 1); self.assertEqual(report["exit_code"], 1)
                    self.assertEqual(len(cleanup), 1)
                    self.assertEqual(host.inputs, {})
                    self.assertEqual(host.feedback_values["button"]["indicator"], "on" if failure == "refused" else "off")
                    self.assertEqual(host.requests.count("surface_control_discover"), 1)
                    self.assertNotIn(TOKEN.encode(), result.stdout + result.stderr)
                finally:
                    proxy.shutdown(); proxy.server_close(); thread.join()
