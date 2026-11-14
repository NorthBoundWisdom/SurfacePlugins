"""Explicit hardware opt-in and fail-closed validation without a device."""
import copy
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from surface_control import Client, EventCursor, SurfaceError, mapping_revision


def hardware_profile():
    return {"id": "test.hardware", "version": "1", "capabilities": ["hardware", "controls.input_declared", "input.absolute", "input.button", "feedback.value"], "controls": [
        {"id": "axis", "input_kind": "absolute", "encoding": "scalar", "range": {"minimum": 0, "maximum": 127, "step": 1}, "feedback_kinds": ["value"], "accepts_input": False},
        {"id": "touch", "input_kind": "button", "encoding": "boolean", "feedback_kinds": [], "accepts_input": False}]}


class HardwareClient(Client):
    def __init__(self, **kwargs):
        super().__init__("http://127.0.0.1:8787/mcp", "test-only", "test", **kwargs)
        self.calls = []
        self.prof = hardware_profile()
        self.identity = {"instance_id": "test", "epoch": "one", "profile_id": self.prof["id"], "profile_version": self.prof["version"], "mapping_revision": mapping_revision(self.prof)}
        self.events = []
        self.link_state = "connected"

    def discovery(self):
        return {"schema_version": 1, "contract_version": "1.4", "source": "hardware", "expected": self.identity, "profile": self.prof, "latest_sequence": str(len(self.events))}

    def call(self, name, arguments=None):
        self.calls.append((name, arguments))
        if name.endswith("discover"):
            return copy.deepcopy(self.discovery())
        if name.endswith("snapshot"):
            return {"discovery": copy.deepcopy(self.discovery()), "latest_sequence": str(len(self.events)), "inputs": {}, "feedback": {}, "server_time": 1, "link": {"state": self.link_state}}
        if name.endswith("events"):
            return {"expected": copy.deepcopy(self.identity), "latest_sequence": str(len(self.events)), "events": copy.deepcopy(self.events[int(arguments["after_sequence"]):]), "server_time": 1, "link": {"state": self.link_state}}
        if name.endswith("feedback"):
            event = {"expected": copy.deepcopy(self.identity), "sequence": str(len(self.events)+1), "source": "hardware", "origin": "remote", "kind": "feedback", "control_id": arguments["control_id"], "encoding": arguments["kind"], "value": arguments["value"], "disposition": "accepted", "time": 1}
            self.events.append(event)
            return copy.deepcopy(event)
        raise AssertionError("forbidden method reached transport")


class HardwareSDKTests(unittest.TestCase):
    def test_legacy_call_style_rejects_hardware(self):
        with self.assertRaises(SurfaceError) as error:
            HardwareClient().discover()
        self.assertEqual(error.exception.code, "unsupported_contract")

    def test_opt_in_unknown_snapshot_feedback_and_local_rejections(self):
        client = HardwareClient(accepted_sources=("hardware",))
        client.discover()
        self.assertEqual(client.snapshot()["inputs"], {})
        self.assertEqual(client.link, {"state": "connected"})
        events = EventCursor(client, clock=lambda: 1)
        events.bootstrap(client.snapshot())
        client.feedback("axis", "value", 3)
        self.assertEqual(events.poll()[0]["event"]["source"], "hardware")
        before = len(client.calls)
        for action, expected in [(lambda: client.input("axis", "scalar", 1), "permission_denied"), (lambda: client.renew("touch", 1), "unsupported_hold"), (client.reset, "unsupported_tool")]:
            with self.assertRaises(SurfaceError) as error:
                action()
            self.assertEqual(error.exception.code, expected)
        self.assertEqual(len(client.calls), before)

    def test_profile_and_link_fail_closed(self):
        for change in [lambda p: p["capabilities"].append("simulation"), lambda p: p["controls"][0].update(accepts_input=True), lambda p: p["capabilities"].append("input.hold")]:
            client = HardwareClient(accepted_sources=("hardware",))
            change(client.prof)
            client.identity["mapping_revision"] = mapping_revision(client.prof)
            with self.assertRaises(SurfaceError):
                client.discover()
        client = HardwareClient(accepted_sources=("hardware",))
        client.discover()
        events = EventCursor(client, clock=lambda: 1)
        events.bootstrap(client.snapshot())
        client.link_state = "disconnected"
        with self.assertRaises(SurfaceError) as error:
            events.poll()
        self.assertEqual(error.exception.code, "link_disconnected")
        self.assertTrue(events.invalidated)

    def test_hardware_input_origin_is_required(self):
        for origin in ("remote", "hardware"):
            client = HardwareClient(accepted_sources=("hardware",))
            client.discover()
            events = EventCursor(client, clock=lambda: 1)
            events.bootstrap(client.snapshot())
            client.events.append({"expected": client.identity, "sequence": "1", "source": "hardware", "origin": origin, "kind": "input", "control_id": "axis", "encoding": "scalar", "value": 12, "disposition": "accepted", "time": 1})
            if origin == "hardware":
                self.assertEqual(len(events.poll()), 1)
            else:
                with self.assertRaises(SurfaceError):
                    events.poll()


if __name__ == "__main__":
    unittest.main()
