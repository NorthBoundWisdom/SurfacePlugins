"""Loopback E2E checks using TEST DOUBLE ONLY; no physical device or qualification evidence."""
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from surface_control import Client, EventCursor, SurfaceError
from surface_control_testing import TestOnlyHardwareHost


class TestDoubleE2ETests(unittest.TestCase):
    def client(self, host, **kwargs):
        client = Client(host.url, "test-only-token", host.instance_id, **kwargs)
        client.discover()
        return client

    def test_http_hardware_lifecycle_feedback_and_rejections(self):
        with TestOnlyHardwareHost("test-only-token") as host:
            with self.assertRaises(SurfaceError) as error:
                self.client(host)
            self.assertEqual(error.exception.code, "unsupported_contract")
            client = self.client(host, accepted_sources=("hardware",))
            snapshot = client.snapshot()
            self.assertEqual(snapshot["inputs"], {})
            events = EventCursor(client, clock=lambda: 1)
            events.bootstrap(snapshot)
            for ident, value in [("axis", 12), ("delta", -1), ("button", True), ("button", False), ("touch", True)]:
                host.apply_step({"at_s": 1, "operation": "input", "control_id": ident, "value": value})
            observed = events.poll()
            self.assertEqual(len(observed), 5)
            self.assertTrue(all(row["event"]["source"] == row["event"]["origin"] == "hardware" for row in observed))
            self.assertEqual(client.feedback("button", "indicator", "blink")["origin"], "remote")
            self.assertEqual(client.snapshot()["inputs"]["axis"], 12)
            for name, args, code in [
                ("input", {"expected": client.expected, "expected_sequence": client.latest_sequence, "control_id": "axis", "encoding": "scalar", "value": 0}, "permission_denied"),
                ("renew", {"expected": client.expected, "control_id": "button", "hold_s": 1}, "unsupported_hold"),
                ("reset", {"expected": client.expected, "expected_sequence": client.latest_sequence}, "unsupported_tool")]:
                before = host.sequence
                with self.assertRaises(SurfaceError) as error:
                    client.call("surface_control_" + name, args)
                self.assertEqual(error.exception.code, code)
                self.assertEqual(host.sequence, before)
            host.apply_step({"at_s": 2, "operation": "disconnect"})
            with self.assertRaises(SurfaceError) as error:
                events.poll()
            self.assertEqual(error.exception.code, "stale_epoch")
            disconnected = self.client(host, accepted_sources=("hardware",))
            self.assertEqual(disconnected.snapshot()["link"]["state"], "disconnected")
            host.apply_step({"at_s": 3, "operation": "reconnect"})
            fresh = self.client(host, accepted_sources=("hardware",))
            self.assertEqual(fresh.snapshot()["inputs"], {})
            self.assertNotEqual(client.expected["epoch"], fresh.expected["epoch"])
            cursor = EventCursor(fresh, clock=lambda: 3)
            cursor.bootstrap(fresh.snapshot())
            host.apply_step({"at_s": 4, "operation": "gap"})
            with self.assertRaises(SurfaceError) as error:
                cursor.poll()
            self.assertEqual(error.exception.code, "event_gap")

    def test_auth_and_feedback_permission(self):
        with TestOnlyHardwareHost("test-only-token", allow_feedback=False) as host:
            wrong = Client(host.url, "incorrect-test-token", host.instance_id, accepted_sources=("hardware",))
            with self.assertRaises(SurfaceError) as error:
                wrong.discover()
            self.assertEqual(error.exception.code, "http_403")
            client = self.client(host, accepted_sources=("hardware",))
            with self.assertRaises(SurfaceError) as error:
                client.feedback("axis", "value", 1)
            self.assertEqual(error.exception.code, "permission_denied")
            self.assertEqual(host.sequence, 0)

    def test_transport_rejection_keeps_snapshot_and_journal_atomic(self):
        with TestOnlyHardwareHost("test-only-token") as host:
            client = self.client(host, accepted_sources=("hardware",))
            client.feedback("axis", "value", 127)
            before = client.snapshot()
            args = {"instance_id": host.instance_id, "epoch": client.expected["epoch"], "after_sequence": "0", "limit": 128}
            before_events = client.call("surface_control_events", args)
            host.reject_next_feedback()
            with self.assertRaises(SurfaceError) as error:
                client.feedback("axis", "value", 0)
            self.assertEqual(error.exception.code, "test_transport_rejected")
            self.assertEqual(client.snapshot(), before)
            self.assertEqual(client.call("surface_control_events", args), before_events)
            self.assertEqual(client.feedback("axis", "value", 0)["sequence"], "2")


if __name__ == "__main__":
    unittest.main()
