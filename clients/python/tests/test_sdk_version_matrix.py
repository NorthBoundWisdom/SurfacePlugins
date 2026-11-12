"""SDK 1.3.0 against explicitly versioned host behaviors; no version rewriting."""
from test_surface_control import QFixture
from surface_control import EventCursor, SurfaceError
import unittest


class VersionHost(QFixture):
    def __init__(self, version):
        modern = version == "1.3"
        super().__init__(independent=modern, writers=modern, limits=modern)
        self.contract = version
        self.prof["version"] = version
        self.prof["controls"][0]["feedback_kinds"] = ["indicator"]
        if version in ("1.0", "1.1"):
            self.prof["capabilities"].remove("feedback.unsequenced")
        if version != "1.0":
            self.prof["capabilities"].append("input.hold")
            self.prof["controls"][0]["hold"] = {"rest_value": 0, "max_hold_s": 2}

    def call(self, name, arguments=None):
        arguments = arguments or {}
        # The fake server really rejects unsupported requests. The SDK rejection tests
        # additionally prove these calls never reach this public boundary.
        if self.contract == "1.0" and (name.endswith("renew") or "hold_s" in arguments):
            self.calls.append((name, arguments))
            raise SurfaceError("unsupported_tool")
        if self.contract in ("1.0", "1.1") and name.endswith("feedback") and "expected_sequence" not in arguments:
            self.calls.append((name, arguments))
            raise SurfaceError("invalid_argument")
        if self.contract != "1.3" and "expected_input_sequence" in arguments:
            self.calls.append((name, arguments))
            raise SurfaceError("invalid_argument")
        if name.endswith("renew"):
            self.calls.append((name, arguments))
            return {"control_id": arguments["control_id"], "hold_deadline": 1 + arguments["hold_s"], "server_time": 1}
        result = super().call(name, arguments)
        if name.endswith("input") and "hold_s" in arguments:
            result["hold_deadline"] = 1 + arguments["hold_s"]
        return result


class VersionMatrixCases:
    version = None

    def client(self):
        client = VersionHost(self.version)
        discovered = client.discover(versions=(self.version,))
        self.assertEqual(discovered["contract_version"], self.version)
        return client

    def test_discovery_snapshot_input_feedback_events_reset_round_trip(self):
        client = self.client()
        before = client.snapshot()
        events = EventCursor(client, clock=lambda: 1)
        events.bootstrap(before)
        input_event = client.input("arm", "scalar", 127)
        self.assertEqual(input_event["disposition"], "accepted")
        input_arguments = client.calls[-1][1]
        field = "expected_input_sequence" if self.version == "1.3" else "expected_sequence"
        self.assertEqual(input_arguments[field], "0")
        self.assertNotIn("expected_sequence" if field == "expected_input_sequence" else "expected_input_sequence", input_arguments)
        feedback_event = client.feedback("arm", "indicator", "on")
        self.assertEqual(feedback_event["kind"], "feedback")
        self.assertEqual("expected_sequence" in client.calls[-1][1], self.version in ("1.0", "1.1"))
        self.assertEqual(client.snapshot()["inputs"]["arm"], 127)
        self.assertEqual([row["event"]["kind"] for row in events.poll()], ["input", "feedback"])
        if self.version == "1.3":
            self.assertEqual([input_event["input_sequence"], feedback_event["input_sequence"]], ["1", "1"])
            self.assertEqual(input_event["writer_id"], "principal.remote")
        else:
            self.assertNotIn("writer_id", input_event)
            self.assertNotIn("input_sequence", input_event)
        epoch = client.expected["epoch"]
        client.reset()
        self.assertNotEqual(client.expected["epoch"], epoch)
        self.assertEqual(client.latest_sequence, "0")
        self.assertEqual(client.calls[-1][1]["expected_sequence"], "2")
        self.assertNotIn("expected_input_sequence", client.calls[-1][1])

    def test_renew_and_held_input_are_supported_only_since_v11(self):
        client = self.client()
        if self.version == "1.0":
            for operation in (lambda: client.input("arm", "scalar", 127, hold_s=1), lambda: client.renew("arm", 1)):
                before = len(client.calls)
                with self.assertRaises(SurfaceError) as error:
                    operation()
                self.assertEqual(error.exception.code, "unsupported_hold")
                self.assertEqual(len(client.calls), before)
        else:
            self.assertEqual(client.input("arm", "scalar", 127, hold_s=1)["hold_deadline"], 2)
            sequence = client.latest_sequence
            self.assertEqual(client.renew("arm", 1)["hold_deadline"], 2)
            self.assertEqual(client.latest_sequence, sequence)
            self.assertNotIn("expected_sequence", client.calls[-1][1])

    def test_unsequenced_feedback_is_supported_only_since_v12(self):
        client = self.client()
        if self.version in ("1.0", "1.1"):
            before = len(client.calls)
            with self.assertRaises(SurfaceError) as error:
                client.feedback("arm", "indicator", "on", sequenced=False)
            self.assertEqual(error.exception.code, "unsupported_feedback")
            self.assertEqual(len(client.calls), before)
        else:
            client.feedback("arm", "indicator", "on", sequenced=False)
            self.assertNotIn("expected_sequence", client.calls[-1][1])
        # Explicit legacy feedback CAS retains its meaning on every version.
        client.feedback("arm", "indicator", "on", sequenced=True)
        self.assertIn("expected_sequence", client.calls[-1][1])

    def test_independent_input_sequence_is_supported_only_since_v13(self):
        client = self.client()
        if self.version != "1.3":
            for operation in (lambda: client.input("arm", "scalar", 127, cas="input"), client.refresh_input_sequence):
                before = len(client.calls)
                with self.assertRaises(SurfaceError) as error:
                    operation()
                self.assertEqual(error.exception.code, "unsupported_input_sequence")
                self.assertEqual(len(client.calls), before)
        else:
            client.input("arm", "scalar", 127, cas="input")
            self.assertEqual(client.refresh_input_sequence(), "1")
        self.assertEqual(client.refresh_sequence(), client.latest_sequence)


class ContractV10HostTests(VersionMatrixCases, unittest.TestCase):
    version = "1.0"


class ContractV11HostTests(VersionMatrixCases, unittest.TestCase):
    version = "1.1"


class ContractV12HostTests(VersionMatrixCases, unittest.TestCase):
    version = "1.2"


class ContractV13HostTests(VersionMatrixCases, unittest.TestCase):
    version = "1.3"


if __name__ == "__main__":
    unittest.main()
