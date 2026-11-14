"""TEST DOUBLE ONLY — not a physical device; never evidence for any acceptance or qualification.

This separate package is not the runtime SDK. Scripts are trusted test setup, never remote tools.
"""
from __future__ import annotations
import copy
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from surface_control import SurfaceError, admits, cursor, mapping_revision, validate_hardware_profile

TEST_DOUBLE_ID = "surface-control-test-only-hardware-double"
WARNING = "TEST DOUBLE ONLY: not a physical device; cannot be acceptance evidence"


def example_profile():
    controls = [
        {"id": "axis", "input_kind": "absolute", "encoding": "scalar", "range": {"minimum": 0, "maximum": 127, "step": 1}, "feedback_kinds": ["value"], "accepts_input": False},
        {"id": "delta", "input_kind": "relative", "encoding": "signedDelta", "range": {"minimum": -8, "maximum": 8, "step": 1}, "feedback_kinds": [], "accepts_input": False},
        {"id": "button", "input_kind": "button", "encoding": "boolean", "feedback_kinds": ["indicator"], "accepts_input": False},
        {"id": "touch", "input_kind": "button", "encoding": "boolean", "feedback_kinds": [], "accepts_input": False}]
    return {"id": "test-only.hardware", "version": "1", "capabilities": ["hardware", "controls.input_declared", "input.absolute", "input.relative", "input.button", "feedback.value", "feedback.indicator", "feedback.unsequenced", "input.independent_sequence", "events.writer_id", "writes.independent_limits"], "controls": controls}


class TestOnlyHardwareHost:
    """TEST DOUBLE, not hardware. Trusted apply_step drives observations and lifecycle in tests.

    Script steps: {at_s, operation: input|disconnect|reconnect|endpoint|gap,
    control_id, value, disposition?, reason?}. Input encoding comes from the test profile.
    No network request can execute a script or inject input.
    """
    __test__ = False

    def __init__(self, token, *, instance_id="test-double-instance", profile=None, capacity=1024, allow_feedback=True):
        self.token, self.instance_id = token, instance_id
        self.profile = copy.deepcopy(profile or example_profile())
        validate_hardware_profile(self.profile)
        if type(capacity) is not int or not 1 <= capacity <= 65536:
            raise ValueError("invalid test journal capacity")
        self.capacity, self.allow_feedback = capacity, allow_feedback
        self.lock = threading.RLock()
        self.generation, self.time, self.connected = 1, 0, True
        self.records, self.inputs, self.feedback_values = [], {}, {}
        self.sequence = self.input_sequence = 0
        self.requests = []
        self.server = None

    @property
    def expected(self):
        return {"instance_id": self.instance_id, "epoch": "test-epoch-" + str(self.generation), "mapping_revision": mapping_revision(self.profile), "profile_id": self.profile["id"], "profile_version": self.profile["version"]}

    def discover(self):
        result = {"schema_version": 1, "contract_version": "1.4", "source": "hardware", "expected": self.expected, "profile": copy.deepcopy(self.profile), "latest_sequence": str(self.sequence)}
        capabilities = self.profile["capabilities"]
        if "input.independent_sequence" in capabilities:
            result["latest_input_sequence"] = str(self.input_sequence)
        if "writes.independent_limits" in capabilities:
            result["write_limits"] = {"window_s": 1, "input_per_window": 60, "feedback_per_window": 20, "renew_per_window": 60, "admin_per_window": 5}
        return result

    def _control(self, ident):
        rows = [row for row in self.profile["controls"] if row["id"] == ident]
        if not rows:
            raise SurfaceError("unsupported_control")
        return rows[0]

    def _append(self, kind, row, encoding, value, disposition="accepted", reason=None):
        if disposition not in ("accepted", "ignored") or (disposition == "ignored" and not reason):
            raise ValueError("test result needs ignored reason")
        self.sequence += 1
        self.input_sequence += kind == "input"
        event = {"expected": self.expected, "sequence": str(self.sequence), "source": "hardware", "origin": "hardware" if kind == "input" else "remote", "kind": kind, "control_id": row["id"], "encoding": encoding, "value": value, "disposition": disposition, "time": self.time}
        if "input.independent_sequence" in self.profile["capabilities"]:
            event["input_sequence"] = str(self.input_sequence)
        if "events.writer_id" in self.profile["capabilities"]:
            event["writer_id"] = "test.hardware" if kind == "input" else "test.remote"
        if reason is not None:
            event["reason"] = reason
        self.records.append(event)
        self.records = self.records[-self.capacity:]
        return copy.deepcopy(event)

    def apply_step(self, step):
        """Trusted test setup only; never bound to an HTTP method or tool."""
        with self.lock:
            at = step.get("at_s", self.time)
            if type(at) not in (int, float) or not self.time <= at < float("inf"):
                raise ValueError("nonmonotonic test time")
            operation = step["operation"]
            if operation == "input":
                if not self.connected:
                    raise SurfaceError("invalid_transition")
                row = self._control(step["control_id"])
                if not admits(row, step["value"]):
                    raise SurfaceError("invalid_value")
                disposition = step.get("disposition", "accepted")
                reason = step.get("reason")
                if disposition not in ("accepted", "ignored") or disposition == "ignored" and not reason:
                    raise ValueError("invalid test disposition")
                self.time = at
                event = self._append("input", row, row["encoding"], step["value"], disposition, reason)
                if disposition == "accepted":
                    self.inputs[row["id"]] = step["value"]
                return event
            if operation in ("disconnect", "reconnect", "endpoint"):
                self.time = at
                self.generation += 1
                self.connected = operation != "disconnect"
                self.sequence = self.input_sequence = 0
                self.records, self.inputs, self.feedback_values = [], {}, {}
            elif operation == "gap":
                self.time = at
                # Deliberately discard retained history; this models a real bounded journal gap.
                self.records = []
                self.sequence += 2
                self.input_sequence += 2
            else:
                raise ValueError("unsupported trusted test operation")

    def tool(self, name, arguments):
        with self.lock:
            self.requests.append(name)
            if name == "surface_control_discover":
                if arguments:
                    raise SurfaceError("invalid_argument")
                return self.discover()
            if name == "surface_control_snapshot":
                if arguments != {"instance_id": self.instance_id}:
                    raise SurfaceError("instance_mismatch")
                result = {"discovery": self.discover(), "server_time": self.time, "latest_sequence": str(self.sequence), "inputs": dict(self.inputs), "feedback": copy.deepcopy(self.feedback_values), "link": {"state": "connected" if self.connected else "disconnected"}}
                if "input.independent_sequence" in self.profile["capabilities"]:
                    result["latest_input_sequence"] = str(self.input_sequence)
                return result
            if name == "surface_control_events":
                if arguments.get("instance_id") != self.instance_id:
                    raise SurfaceError("instance_mismatch")
                if arguments.get("epoch") != self.expected["epoch"]:
                    raise SurfaceError("stale_epoch")
                after, limit = cursor(arguments.get("after_sequence")), arguments.get("limit")
                if type(limit) is not int or not 1 <= limit <= 1024:
                    raise SurfaceError("invalid_argument")
                first = int(self.records[0]["sequence"]) if self.records else self.sequence + 1
                if after > self.sequence or after + 1 < first:
                    raise SurfaceError("event_gap")
                result = {"server_time": self.time, "expected": self.expected, "latest_sequence": str(self.sequence), "events": copy.deepcopy([e for e in self.records if int(e["sequence"]) > after][:limit]), "link": {"state": "connected" if self.connected else "disconnected"}}
                if "input.independent_sequence" in self.profile["capabilities"]:
                    result["latest_input_sequence"] = str(self.input_sequence)
                return result
            expected = arguments.get("expected", {})
            for field, code in (("instance_id", "instance_mismatch"), ("profile_id", "unsupported_profile"), ("profile_version", "unsupported_profile"), ("mapping_revision", "stale_mapping"), ("epoch", "stale_epoch")):
                if expected.get(field) != self.expected[field]:
                    raise SurfaceError(code)
            rejected = {"surface_control_input": "permission_denied", "surface_control_renew": "unsupported_hold", "surface_control_reset": "unsupported_tool"}
            if name in rejected:
                raise SurfaceError(rejected[name])
            if name != "surface_control_feedback":
                raise SurfaceError("unsupported_tool")
            if not self.allow_feedback:
                raise SurfaceError("permission_denied")
            if "expected_sequence" in arguments:
                if cursor(arguments["expected_sequence"]) != self.sequence:
                    raise SurfaceError("stale_sequence")
            elif "feedback.unsequenced" not in self.profile["capabilities"]:
                raise SurfaceError("invalid_argument")
            row = self._control(arguments.get("control_id"))
            kind, value = arguments.get("kind"), arguments.get("value")
            if kind not in row["feedback_kinds"]:
                raise SurfaceError("unsupported_feedback")
            descriptor = {**row, "range": row.get("feedback_range", row.get("range"))}
            if kind == "indicator":
                valid = value in ("off", "on", "blink")
            else:
                valid = admits(descriptor, value)
            if not valid:
                raise SurfaceError("invalid_value")
            event = self._append("feedback", row, kind, value)
            self.feedback_values.setdefault(row["id"], {})[kind] = value
            return event

    def start(self, port=0):
        host = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                if self.path != "/mcp" or self.headers.get("Authorization") != "Bearer " + host.token:
                    self.send_error(403)
                    return
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                    if not 0 < length <= 8 * 1024 * 1024:
                        raise ValueError("length")
                    request = json.loads(self.rfile.read(length))
                    method, ident = request["method"], request.get("id")
                    if method == "notifications/initialized":
                        self.send_response(202)
                        self.end_headers()
                        return
                    if method == "initialize":
                        result = {"protocolVersion": request["params"]["protocolVersion"], "capabilities": {"tools": {}}, "serverInfo": {"name": TEST_DOUBLE_ID, "version": "1"}}
                    elif method == "tools/call":
                        params = request["params"]
                        try:
                            value = host.tool(params["name"], params.get("arguments", {}))
                            failed = False
                        except SurfaceError as error:
                            value, failed = {"code": error.code}, True
                        result = {"structuredContent": value, "isError": failed, "content": [{"type": "text", "text": json.dumps(value)}]}
                    else:
                        raise ValueError("method")
                    body = json.dumps({"jsonrpc": "2.0", "id": ident, "result": result}, allow_nan=False).encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.send_header("Mcp-Session-Id", "test-only-session")
                    self.end_headers()
                    self.wfile.write(body)
                except (ValueError, KeyError, TypeError):
                    self.send_error(400)

        self.server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = "http://127.0.0.1:" + str(self.server.server_address[1]) + "/mcp"
        return self

    def close(self):
        if self.server is not None:
            self.server.shutdown()
            self.server.server_close()
            self.thread.join()
            self.server = None

    def __enter__(self):
        return self.start()

    def __exit__(self, *_):
        self.close()
