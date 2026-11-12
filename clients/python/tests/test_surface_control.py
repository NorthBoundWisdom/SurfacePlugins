import copy
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from surface_control import (  # noqa: E402
    BinaryRoleCursor,
    Client,
    CommandCursor,
    EventCursor,
    SurfaceError,
    __version__,
    admits,
    mapping_document,
    mapping_revision,
)

ROLES = ("arm", "start", "pause", "cancel")


def profile(controls=None, *, version="1.0", ident="fixture.profile"):
    if controls is None:
        controls = [
            {
                "id": name,
                "input_kind": "absolute",
                "encoding": "scalar",
                "range": {"minimum": 0, "maximum": 127, "step": 1},
                "feedback_kinds": [],
                "mapping": {"kind": "parameter", "id": "simulation." + name},
            }
            for name in ROLES
        ]
    return {"id": ident, "version": version, "capabilities": ["simulation", "input.absolute"], "controls": controls}


def discovery(contract="1.0", prof=None):
    prof = prof or profile()
    return {
        "schema_version": 1,
        "contract_version": contract,
        "source": "simulation",
        "latest_sequence": "0",
        "expected": {
            "instance_id": "A",
            "epoch": "epoch",
            "mapping_revision": mapping_revision(prof) if contract == "1.1" else "map",
            "profile_id": prof["id"],
            "profile_version": prof["version"],
        },
        "profile": prof,
    }


class Fixture(Client):
    def __init__(self, contract="1.0", prof=None, values=None):
        super().__init__("http://127.0.0.1:8787/mcp", "token", "A")
        self.contract, self.prof = contract, prof or profile()
        self.head = 0
        self.rows = []
        self.values = dict(values) if values is not None else {name: 0 for name in ROLES}
        self.response_override = None
        self.response_time = 1
        self.calls = []

    def disc(self):
        return discovery(self.contract, self.prof)

    def call(self, name, arguments=None):
        self.calls.append((name, arguments))
        if self.response_override is not None:
            return self.response_override
        if name.endswith("discover"):
            value = self.disc()
            value["latest_sequence"] = str(self.head)
            return value
        if name.endswith("snapshot"):
            return {
                "discovery": self.disc(),
                "latest_sequence": str(self.head),
                "server_time": self.response_time,
                "inputs": dict(self.values),
                "feedback": {},
            }
        if name.endswith("events"):
            return {
                "expected": self.disc()["expected"],
                "latest_sequence": str(self.head),
                "server_time": self.response_time,
                "events": copy.deepcopy(self.rows),
            }
        raise AssertionError(name)

    def event(self, control, value, **fields):
        self.head += 1
        encoding = next((c["encoding"] for c in self.prof["controls"] if c["id"] == control), "scalar")
        row = {
            "expected": self.disc()["expected"],
            "sequence": str(self.head),
            "source": "simulation",
            "kind": "input",
            "origin": "remote",
            "disposition": "accepted",
            "control_id": control,
            "encoding": encoding,
            "value": value,
            "time": self.response_time,
            **fields,
        }
        self.rows.append(row)
        if row["kind"] == "input" and row["disposition"] == "accepted":
            self.values[control] = value


class MappingRevisionTests(unittest.TestCase):
    def test_matches_swift_pinned_document_and_hash(self):
        # Same profile and expected strings as ControlV11Tests.testCanonicalDocumentAndHashArePinned.
        prof = {
            "controls": [
                {"id": "b", "input_kind": "button", "encoding": "boolean", "feedback_kinds": ["indicator", "value"]},
                {
                    "id": "a",
                    "input_kind": "absolute",
                    "encoding": "scalar",
                    "range": {"minimum": 0, "maximum": 1.5, "step": 0.5},
                    "feedback_kinds": [],
                    "mapping": {"kind": "parameter", "id": 'p"q'},
                },
            ]
        }
        self.assertEqual(
            mapping_document(prof),
            '[{"encoding":"scalar","feedback_kinds":[],"id":"a","input_kind":"absolute",'
            '"mapping":{"id":"p\\"q","kind":"parameter"},"range":{"maximum":1.5,"minimum":0,"step":0.5}},'
            '{"encoding":"boolean","feedback_kinds":["indicator","value"],"id":"b","input_kind":"button"}]',
        )

    def test_matches_swift_generated_example_revision(self):
        # Output of `swift run surface-control-schema --examples` (discover result profile).
        prof = json.loads(
            '{"capabilities":["simulation","controls.stable_ids","input.absolute","input.button","input.hold",'
            '"feedback.value","feedback.indicator"],"controls":[{"encoding":"scalar","feedback_kinds":["value",'
            '"indicator"],"id":"dial.1","input_kind":"absolute","mapping":{"id":"example.input","kind":"parameter"},'
            '"range":{"maximum":100,"minimum":0,"step":1}},{"encoding":"boolean","feedback_kinds":["indicator"],'
            '"hold":{"max_hold_s":2,"rest_value":false},"id":"button.1","input_kind":"button"}],'
            '"id":"example.scalar","version":"1"}'
        )
        self.assertEqual(mapping_revision(prof), "99b95ecb012073e4")
        reordered = dict(prof, controls=list(reversed(prof["controls"])), capabilities=[])
        self.assertEqual(mapping_revision(reordered), "99b95ecb012073e4")
        changed = copy.deepcopy(prof)
        changed["controls"][1]["hold"]["max_hold_s"] = 3
        self.assertNotEqual(mapping_revision(changed), "99b95ecb012073e4")
        floats = copy.deepcopy(prof)
        floats["controls"][0]["range"] = {"maximum": 100.0, "minimum": 0.0, "step": 1.0}
        self.assertEqual(mapping_revision(floats), "99b95ecb012073e4")


class ClientTests(unittest.TestCase):
    def test_version(self):
        self.assertEqual(__version__, "1.1.0")

    def test_profile_allowlist_is_caller_owned(self):
        client = Fixture()
        client.discover()  # None accepts any well-formed profile
        client = Fixture()
        with self.assertRaises(SurfaceError) as error:
            client.discover(profiles=("other.profile",))
        self.assertEqual(error.exception.code, "unsupported_profile")
        Fixture().discover(profiles=("fixture.profile",), profile_versions=("1.0",))
        with self.assertRaises(SurfaceError):
            Fixture().discover(profile_versions=("2.0",))

    def test_contract_versions(self):
        Fixture("1.0").discover()
        client = Fixture("1.1")
        client.discover()
        self.assertEqual(client.contract_version, "1.1")
        with self.assertRaises(SurfaceError):
            Fixture("1.1").discover(versions=("1.0",))
        with self.assertRaises(SurfaceError):
            Fixture("1.2").discover()
        with self.assertRaises(SurfaceError):
            Fixture().discover(versions=("1.2",))

    def test_contract_1_1_requires_derived_mapping_revision(self):
        client = Fixture("1.1")
        bad = discovery("1.1")
        bad["expected"]["mapping_revision"] = "0000000000000000"
        client.response_override = bad
        with self.assertRaises(SurfaceError) as error:
            client.discover()
        self.assertEqual(error.exception.code, "invalid_identity")

    def test_context_source_and_instance_are_pinned(self):
        for mutate in (
            lambda d: d.__setitem__("source", "hardware"),
            lambda d: d["expected"].__setitem__("instance_id", "B"),
            lambda d: d["expected"].__setitem__("profile_version", "2.0"),
        ):
            client = Fixture()
            bad = discovery()
            mutate(bad)
            client.response_override = bad
            with self.assertRaises(SurfaceError):
                client.discover()

    def test_raw_failure_code_and_mutation_are_never_retried(self):
        client = Client("http://127.0.0.1:8787/mcp", "token", "A")
        calls = []

        def rpc(*args):
            calls.append(args)
            return {"isError": True, "structuredContent": {"code": "stale_sequence"}}

        client.rpc = rpc
        with self.assertRaises(SurfaceError) as error:
            client.call("surface_control_input", {})
        self.assertEqual(error.exception.code, "stale_sequence")
        self.assertEqual(len(calls), 1)

    def test_snapshot_rejects_observed_highwater_and_time_rollback(self):
        client = Client("http://127.0.0.1:8787/mcp", "token", "A")
        client.expected = discovery()["expected"]
        client.latest_sequence = "2"
        client.server_time = 2
        value = {"discovery": discovery(), "latest_sequence": "1", "server_time": 3, "inputs": {}, "feedback": {}}
        client.call = lambda *_: value
        with self.assertRaises(SurfaceError):
            client.snapshot()
        value["latest_sequence"] = "2"
        value["server_time"] = 1
        with self.assertRaises(SurfaceError):
            client.snapshot()

    def test_provider_identity_header_is_caller_named(self):
        with self.assertRaises(SurfaceError):
            Client("http://127.0.0.1:8787/mcp", "token", "A", provider_id="p")
        with self.assertRaises(SurfaceError):
            Client("http://127.0.0.1:8787/mcp", "token", "A", provider_id="p", provider_header="Bad Header")
        client = Client("http://127.0.0.1:8787/mcp", "token", "A", provider_id="p", provider_header="X-Host-Id")
        self.assertEqual(client._headers("tools/call")["X-Host-Id"], "p")

    def test_hold_requires_contract_1_1_and_renew_is_validated_without_retry(self):
        client = Fixture("1.0")
        client.discover()
        with self.assertRaises(SurfaceError) as error:
            client.input("arm", "scalar", 1, hold_s=1)
        self.assertEqual(error.exception.code, "unsupported_hold")
        with self.assertRaises(SurfaceError):
            client.renew("arm", 1)
        client = Fixture("1.1")
        client.discover()
        client.server_time = 1
        responses = [{"control_id": "arm", "hold_deadline": 3, "server_time": 2}]
        client.call = lambda name, arguments=None: (client.calls.append((name, arguments)), responses.pop(0))[1]
        self.assertEqual(client.renew("arm", 1)["hold_deadline"], 3)
        name, arguments = client.calls[-1]
        self.assertEqual(name, "surface_control_renew")
        self.assertEqual(set(arguments), {"expected", "control_id", "hold_s"})
        self.assertEqual(client.latest_sequence, "0")  # renew consumes no sequence
        for bad in (
            {"control_id": "other", "hold_deadline": 4, "server_time": 3},
            {"control_id": "arm", "hold_deadline": 3, "server_time": 3},
            {"control_id": "arm", "hold_deadline": 5, "server_time": 1},  # time rollback
            {"control_id": "arm", "hold_deadline": 5, "server_time": 3, "extra": 1},
        ):
            responses.append(bad)
            with self.assertRaises(SurfaceError):
                client.renew("arm", 1)
        client.call = lambda *_: (_ for _ in ()).throw(SurfaceError("hold_expired"))
        with self.assertRaises(SurfaceError) as error:
            client.renew("arm", 1)
        self.assertEqual(error.exception.code, "hold_expired")
        with self.assertRaises(SurfaceError):
            client.renew("arm", 0)

    def test_input_hold_is_sent_and_deadline_checked(self):
        client = Fixture("1.1")
        client.discover()
        sent = []

        def call(name, arguments=None):
            sent.append(arguments)
            return {
                "expected": client.expected,
                "source": "simulation",
                "sequence": "1",
                "time": 1,
                "origin": "remote",
                "kind": "input",
                "disposition": "accepted",
                "control_id": "arm",
                "encoding": "scalar",
                "value": 127,
                "hold_deadline": 2,
            }

        client.call = call
        self.assertEqual(client.input("arm", "scalar", 127, hold_s=1)["hold_deadline"], 2)
        self.assertEqual(sent[0]["hold_s"], 1)
        self.assertEqual(client.latest_sequence, "1")

    def test_admits_uses_declared_grid(self):
        control = {"encoding": "scalar", "range": {"minimum": -1, "maximum": 1, "step": 0.5}}
        self.assertTrue(admits(control, 0.5))
        self.assertFalse(admits(control, 0.25))
        self.assertFalse(admits(control, True))
        self.assertTrue(admits({"encoding": "boolean"}, False))
        self.assertFalse(admits({"encoding": "boolean"}, 0))


class CursorTests(unittest.TestCase):
    def cursor(self):
        client = Fixture()
        clock = [1]
        cursor = CommandCursor(client, {name: "simulation." + name for name in ROLES}, clock=lambda: clock[0])
        cursor.bootstrap()
        return client, cursor, clock

    def test_snapshot_is_state_not_an_action_and_feedback_is_not_input(self):
        client, cursor, _ = self.cursor()
        self.assertEqual(cursor.values, {"arm": 0, "start": 0, "pause": 0, "cancel": 0})
        client.event("arm", 127, kind="feedback")
        self.assertEqual(cursor.poll(), [])
        self.assertEqual(cursor.values["arm"], 0)

    def test_same_side_ticks_cannot_renew_intent(self):
        client, cursor, clock = self.cursor()
        client.event("arm", 100)
        sample = cursor.poll()[0]
        original = sample["expires_monotonic"]
        client.rows.clear()
        client.response_time = 1.5
        clock[0] = 1.5
        client.event("arm", 110)
        self.assertEqual(cursor.poll(), [])
        self.assertEqual(sample["expires_monotonic"], original)
        with self.assertRaises(SurfaceError):
            cursor.verify(sample)

    def test_old_state_and_gap_invalidate_without_recovery(self):
        client, cursor, _ = self.cursor()
        client.event("arm", 127)
        client.rows[0]["sequence"] = "2"
        with self.assertRaises(SurfaceError) as error:
            cursor.poll()
        self.assertEqual(error.exception.code, "event_gap")
        with self.assertRaises(SurfaceError):
            cursor.poll()

    def test_stale_event_cannot_gain_new_deadline_on_receipt(self):
        client, cursor, _ = self.cursor()
        client.event("arm", 127, time=0)
        client.response_time = 3
        with self.assertRaises(SurfaceError) as error:
            cursor.poll()
        self.assertEqual(error.exception.code, "input_stale")

    def test_invalid_encodings_do_not_bootstrap(self):
        client = Fixture()
        bad = discovery()
        bad["profile"]["controls"][0]["encoding"] = "relative"
        client.response_override = bad
        cursor = CommandCursor(client, {name: "simulation." + name for name in ROLES})
        with self.assertRaises(SurfaceError):
            cursor.bootstrap()

    def test_verify_clock_rollback_permanently_revokes_cursor(self):
        client, cursor, clock = self.cursor()
        client.event("arm", 127)
        sample = cursor.poll()[0]
        clock[0] = 0.5
        with self.assertRaises(SurfaceError):
            cursor.verify(sample)
        clock[0] = 1.5
        with self.assertRaises(SurfaceError) as error:
            cursor.verify(sample)
        self.assertEqual(error.exception.code, "recovery_required")

    def test_unknown_event_readback_and_ignored_without_reason_cannot_preserve_arm(self):
        for fields in (
            {"kind": "future"},
            {"kind": "readback"},  # removed from the SDK: not a contract event kind
            {"disposition": "future"},
            {"disposition": "ignored"},
            {"time": float("nan")},
            {"origin": "hardware"},
            {"hold_deadline": "soon"},
        ):
            client, cursor, _ = self.cursor()
            client.event("arm", 127, **fields)
            with self.assertRaises(SurfaceError):
                cursor.poll()
            self.assertTrue(cursor.invalidated)

    def test_poll_rejects_server_time_and_sequence_rollback(self):
        client, cursor, _ = self.cursor()
        client.response_time = 0.5
        with self.assertRaises(SurfaceError):
            cursor.poll()
        client, cursor, _ = self.cursor()
        client.latest_sequence = "2"
        with self.assertRaises(SurfaceError):
            cursor.poll()

    def test_command_cursor_requires_exactly_four_roles(self):
        with self.assertRaises(SurfaceError):
            CommandCursor(Fixture(), {"arm": "simulation.arm"})

    def test_binary_roles_are_arbitrary_and_use_range_midpoint(self):
        prof = profile(
            [
                {
                    "id": "axis",
                    "input_kind": "absolute",
                    "encoding": "scalar",
                    "range": {"minimum": -100, "maximum": 100, "step": 1},
                    "feedback_kinds": [],
                    "mapping": {"kind": "parameter", "id": "drive.enable"},
                },
                {
                    "id": "unit",
                    "input_kind": "absolute",
                    "encoding": "scalar",
                    "range": {"minimum": 0, "maximum": 1},
                    "feedback_kinds": [],
                    "mapping": {"kind": "parameter", "id": "drive.mode"},
                },
                {
                    "id": "deadman",
                    "input_kind": "button",
                    "encoding": "boolean",
                    "feedback_kinds": [],
                    "mapping": {"kind": "parameter", "id": "drive.deadman"},
                    "hold": {"rest_value": False, "max_hold_s": 2},
                },
            ],
            version="1.1",
        )
        client = Fixture("1.1", prof, values={"axis": -100, "unit": 0.25, "deadman": False})
        clock = [1]
        cursor = BinaryRoleCursor(
            client,
            {"enable": "drive.enable", "mode": "drive.mode", "deadman": "drive.deadman"},
            clock=lambda: clock[0],
        )
        self.assertEqual(cursor.bootstrap(), {"enable": 0, "mode": 0, "deadman": 0})
        client.event("axis", -1)
        self.assertEqual(cursor.poll(), [])  # below midpoint 0
        client.rows.clear()
        client.event("axis", 0)
        client.event("unit", 0.5)
        client.event("deadman", True)
        samples = cursor.poll()
        self.assertEqual([s["values"] for s in samples][-1], {"enable": 1, "mode": 1, "deadman": 1})
        self.assertEqual([s["superseded"] for s in samples], [True, True, False])
        client.rows.clear()
        client.event("deadman", False, reason="hold_expired")
        released = cursor.poll()
        self.assertEqual(released[0]["values"]["deadman"], 0)
        self.assertEqual(released[0]["reason"], "hold_expired")
        cursor.verify(released[0])

    def test_event_cursor_is_neutral(self):
        client = Fixture()
        client.discover()
        clock = [1]
        events = EventCursor(client, clock=lambda: clock[0])
        events.bootstrap(client.snapshot())
        client.event("anything", 5, kind="feedback", encoding="value")
        entries = events.poll()
        self.assertEqual(len(entries), 1)
        self.assertTrue(events.fresh(entries[0], now=1))
        self.assertFalse(events.fresh(entries[0], now=10))
        self.assertEqual(events.sequence, 1)


if __name__ == "__main__":
    unittest.main()
