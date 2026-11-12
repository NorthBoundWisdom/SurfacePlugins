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
    accepts_input,
    validate_input_declarations,
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
            "mapping_revision": mapping_revision(prof) if contract in ("1.1", "1.2") else "map",
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
        self.assertEqual(__version__, "1.3.0")

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
            Fixture("1.4").discover()
        with self.assertRaises(SurfaceError):
            Fixture().discover(versions=("1.4",))

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


class V12Tests(unittest.TestCase):
    def client(self, *, unsequenced=True):
        prof = profile(version="1.2")
        prof["capabilities"].append("controls.input_declared")
        if unsequenced:
            prof["capabilities"].append("feedback.unsequenced")
        for control in prof["controls"]:
            control["accepts_input"] = control["id"] != "cancel"
        client = Fixture("1.2", prof)
        client.discover()
        return client

    def reply(self, client, suffix="feedback", sequence="1"):
        return {"expected": client.expected, "source": "simulation", "sequence": sequence,
                "time": 1, "origin": "remote", "kind": suffix, "disposition": "accepted",
                "control_id": "arm", "encoding": "indicator" if suffix == "feedback" else "scalar",
                "value": "on" if suffix == "feedback" else 127}

    def test_same_swift_v12_hash_and_absent_field_preserves_legacy_hash(self):
        prof = {"controls": [{"id": "button", "input_kind": "button", "encoding": "boolean",
                             "feedback_kinds": ["indicator"], "hold": {"rest_value": False, "max_hold_s": 2},
                             "accepts_input": True}]}
        self.assertEqual(mapping_revision(prof), "d7291a4e96e8aba4")
        prof["controls"][0]["accepts_input"] = False
        self.assertNotEqual(mapping_revision(prof), "d7291a4e96e8aba4")
        # The unchanged v1.1 example hash remains pinned by MappingRevisionTests.

    def test_discovery_and_input_declaration_helpers_reject_half_declarations(self):
        client = self.client()
        self.assertIs(client.accepts_input("arm"), True)
        self.assertIs(client.accepts_input("cancel"), False)
        self.assertIsNone(accepts_input({"id": "legacy"}))
        for mutate in (
            lambda p: p["controls"][0].pop("accepts_input"),
            lambda p: p["controls"][0].__setitem__("accepts_input", 1),
            lambda p: p["capabilities"].remove("controls.input_declared"),
        ):
            bad = copy.deepcopy(client.prof)
            mutate(bad)
            with self.assertRaises(SurfaceError) as error:
                validate_input_declarations(bad)
            self.assertEqual(error.exception.code, "invalid_profile")
            with self.assertRaises(SurfaceError):
                Fixture("1.2", bad).discover()

    def test_v12_discovery_still_pins_mapping(self):
        client = self.client()
        value = client.disc()
        value["expected"]["mapping_revision"] = "0000000000000000"
        client.response_override = value
        with self.assertRaises(SurfaceError) as error:
            client.discover()
        self.assertEqual(error.exception.code, "invalid_identity")

    def test_feedback_default_unsequenced_accepts_concurrent_sequence_jump(self):
        client = self.client()
        sent = []
        client.call = lambda name, arguments=None: (sent.append((name, arguments)), self.reply(client, sequence="3"))[1]
        self.assertEqual(client.feedback("arm", "indicator", "on")["sequence"], "3")
        self.assertEqual(client.latest_sequence, "3")
        self.assertNotIn("expected_sequence", sent[0][1])
        self.assertEqual(len(sent), 1)

    def test_unsequenced_jump_updates_input_cas_without_skipping_unread_events(self):
        client = self.client()
        events = EventCursor(client, clock=lambda: 1)
        events.bootstrap(client.snapshot())
        # Other writers commit after this reader bootstraps, before its feedback.
        client.event("start", 127)
        client.event("pause", 127)
        original = client.call
        writes = []

        def call(name, arguments=None):
            if name.endswith("feedback"):
                self.assertNotIn("expected_sequence", arguments)
                writes.append(name)
                client.event("arm", "on", kind="feedback", encoding="indicator")
                return copy.deepcopy(client.rows[-1])
            if name.endswith("input"):
                self.assertEqual(arguments["expected_sequence"], str(client.head))
                writes.append(name)
                client.event("arm", 127)
                return copy.deepcopy(client.rows[-1])
            return original(name, arguments)

        client.call = call
        self.assertEqual(client.feedback("arm", "indicator", "on")["sequence"], "3")
        self.assertEqual(client.latest_sequence, "3")
        self.assertEqual(events.sequence, 0)
        self.assertEqual(client.input("arm", "scalar", 127)["sequence"], "4")
        self.assertEqual(client.latest_sequence, "4")
        self.assertEqual(events.sequence, 0)
        entries = events.poll()
        self.assertEqual([entry["event"]["sequence"] for entry in entries], ["1", "2", "3", "4"])
        self.assertEqual([entry["event"]["control_id"] for entry in entries[:2]], ["start", "pause"])
        self.assertEqual(client.calls[-1][1]["after_sequence"], "0")
        self.assertEqual(events.sequence, 4)
        self.assertEqual(client.latest_sequence, "4")
        self.assertFalse(events.invalidated)
        self.assertEqual(writes, ["surface_control_feedback", "surface_control_input"])

    def test_feedback_legacy_or_explicit_cas_keeps_exact_successor(self):
        for contract in ("1.0", "1.1", "1.2"):
            client = self.client(unsequenced=False) if contract == "1.2" else Fixture(contract)
            if contract != "1.2":
                client.discover()
            sent = []
            client.call = lambda name, arguments=None: (sent.append(arguments), self.reply(client))[1]
            client.feedback("arm", "indicator", "on")
            self.assertEqual(sent[0]["expected_sequence"], "0")
            with self.assertRaises(SurfaceError):
                client.feedback("arm", "indicator", "on", sequenced=False)
        client = self.client()
        sent = []
        client.call = lambda name, arguments=None: (sent.append(arguments), self.reply(client, sequence="3"))[1]
        with self.assertRaises(SurfaceError) as error:
            client.feedback("arm", "indicator", "on", sequenced=True)
        self.assertEqual(error.exception.code, "invalid_response")
        self.assertEqual(sent[0]["expected_sequence"], "0")
        self.assertEqual(client.latest_sequence, "0")

    def test_unsequenced_feedback_rejects_bad_identity_sequence_and_origin(self):
        for mutate in (lambda r: r.__setitem__("sequence", "0"),
                       lambda r: r.__setitem__("expected", {}),
                       lambda r: r.__setitem__("origin", "hardware")):
            client = self.client()
            reply = self.reply(client)
            mutate(reply)
            client.call = lambda *_: reply
            with self.assertRaises(SurfaceError):
                client.feedback("arm", "indicator", "on")
            self.assertEqual(client.latest_sequence, "0")

    def test_stale_input_refresh_reads_once_and_only_caller_resubmits(self):
        client = self.client()
        original = client.call
        calls = []
        def call(name, arguments=None):
            calls.append((name, arguments))
            if name.endswith("input"):
                if arguments["expected_sequence"] == "0":
                    raise SurfaceError("stale_sequence")
                return self.reply(client, "input", "3")
            return original(name, arguments)
        client.call = call
        with self.assertRaises(SurfaceError) as error:
            client.input("arm", "scalar", 127)
        self.assertEqual(error.exception.code, "stale_sequence")
        self.assertEqual(client.latest_sequence, "0")
        client.head = 2
        self.assertEqual(client.refresh_sequence(), "2")
        self.assertEqual([name for name, _ in calls], ["surface_control_input", "surface_control_snapshot"])
        self.assertEqual(client.input("arm", "scalar", 127)["sequence"], "3")
        self.assertEqual(len(calls), 3)

    def test_refresh_preserves_identity_time_and_sequence_fences(self):
        for mutate in (lambda r: r["discovery"].__setitem__("expected", {}),
                       lambda r: r.__setitem__("latest_sequence", "0"),
                       lambda r: r.__setitem__("server_time", 0)):
            client = self.client()
            client.latest_sequence = "1"
            client.server_time = 1
            client.head = 1
            reply = client.call("surface_control_snapshot")
            mutate(reply)
            sent = []
            client.call = lambda name, arguments=None: (sent.append(name), reply)[1]
            with self.assertRaises(SurfaceError):
                client.refresh_sequence()
            self.assertEqual(sent, ["surface_control_snapshot"])
            self.assertEqual(client.latest_sequence, "1")

    def test_transport_unknown_feedback_never_retries(self):
        client = self.client()
        calls = []
        def fail(name, arguments=None):
            calls.append(name)
            raise SurfaceError("transport_unknown")
        client.call = fail
        with self.assertRaises(SurfaceError) as error:
            client.feedback("arm", "indicator", "on")
        self.assertEqual(error.exception.code, "transport_unknown")
        self.assertEqual(calls, ["surface_control_feedback"])

    def test_event_cursor_reads_current_holds_without_creating_events_or_fresh_intents(self):
        client = self.client()
        events = EventCursor(client, clock=lambda: 1)
        events.bootstrap(client.snapshot())
        for holds in ({"arm": 2}, {"arm": 3}, {}):
            client.response_override = {"expected": client.expected, "latest_sequence": "0", "server_time": 1,
                                        "events": [], **({"holds": holds} if holds else {})}
            self.assertEqual(events.poll(), [])
            self.assertEqual(events.sequence, 0)
            self.assertEqual(events.holds, holds)
            self.assertEqual(events.holds_server_time, 1)
            self.assertEqual(events.holds_request_started_monotonic, 1)
            self.assertEqual(events.holds_received_monotonic, 1)
        for bad in ([1], {"arm": float("nan")}, {"arm": "tomorrow"}):
            client = self.client()
            events = EventCursor(client, clock=lambda: 1)
            events.bootstrap(client.snapshot())
            client.response_override = {"expected": client.expected, "latest_sequence": "0", "server_time": 1,
                                        "events": [], "holds": bad}
            with self.assertRaises(SurfaceError) as error:
                events.poll()
            self.assertEqual(error.exception.code, "invalid_events")
            self.assertTrue(events.invalidated)

    def test_v12_hold_input_and_renew_remain_supported(self):
        client = self.client()
        reply = self.reply(client, "input")
        reply["hold_deadline"] = 2
        client.call = lambda *_: reply
        self.assertEqual(client.input("arm", "scalar", 127, hold_s=1)["hold_deadline"], 2)
        client.call = lambda *_: {"control_id": "arm", "hold_deadline": 3, "server_time": 2}
        self.assertEqual(client.renew("arm", 1)["hold_deadline"], 3)


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



class QFixture(Fixture):
    """Deterministic contract-1.3 server; state is independent of the SDK's highwaters."""
    def __init__(self, *, independent=True, writers=True, limits=True):
        prof = profile(version="1.3")
        prof["capabilities"] += ["feedback.unsequenced"]
        if independent:
            prof["capabilities"].append("input.independent_sequence")
        if writers:
            prof["capabilities"].append("events.writer_id")
        if limits:
            prof["capabilities"].append("writes.independent_limits")
        super().__init__("1.3", prof)
        self.input_head = 0
        self.epoch = "epoch"

    def disc(self):
        result = discovery(self.contract, self.prof)
        result["expected"]["mapping_revision"] = mapping_revision(self.prof)
        result["expected"]["epoch"] = self.epoch
        result["latest_sequence"] = str(self.head)
        if "input.independent_sequence" in self.prof["capabilities"]:
            result["latest_input_sequence"] = str(self.input_head)
        if "writes.independent_limits" in self.prof["capabilities"]:
            result["write_limits"] = {"window_s": 1, "input_per_window": 60, "feedback_per_window": 20,
                                      "renew_per_window": 60, "admin_per_window": 5}
        return result

    def event(self, control, value, **fields):
        if fields.get("kind", "input") == "input":
            self.input_head += 1
        super().event(control, value, **fields)
        if "input.independent_sequence" in self.prof["capabilities"]:
            self.rows[-1]["input_sequence"] = str(self.input_head)
        if "events.writer_id" in self.prof["capabilities"]:
            self.rows[-1]["writer_id"] = "principal.system" if fields.get("reason") == "hold_expired" else "principal.remote"

    def call(self, name, arguments=None):
        if self.response_override is not None:
            return super().call(name, arguments)
        if name.endswith(("input", "feedback", "reset")):
            self.calls.append((name, arguments))
            if "expected_sequence" in arguments and arguments["expected_sequence"] != str(self.head):
                raise SurfaceError("stale_sequence")
            if "expected_input_sequence" in arguments and arguments["expected_input_sequence"] != str(self.input_head):
                raise SurfaceError("stale_input_sequence")
            if name.endswith("reset"):
                self.head = self.input_head = 0
                self.rows.clear()
                self.epoch += "-reset"
                return self.disc()
            feedback = name.endswith("feedback")
            self.event(arguments["control_id"], arguments["value"], kind="feedback" if feedback else "input",
                       encoding=arguments["kind"] if feedback else arguments["encoding"])
            return copy.deepcopy(self.rows[-1])
        result = super().call(name, arguments)
        if name.endswith(("snapshot", "events")) and "input.independent_sequence" in self.prof["capabilities"]:
            result["latest_input_sequence"] = str(self.input_head)
        if name.endswith("events"):
            result["events"] = [row for row in result["events"] if int(row["sequence"]) > int(arguments["after_sequence"])][:arguments["limit"]]
        return result


class V13Tests(unittest.TestCase):
    def client(self, **options):
        client = QFixture(**options)
        client.discover()
        return client

    def test_auto_input_cas_survives_feedback_and_explicit_global_keeps_conflict(self):
        client = self.client()
        client.event("arm", "on", kind="feedback", encoding="indicator")
        with self.assertRaises(SurfaceError) as error:
            client.input("arm", "scalar", 127, cas="global")
        self.assertEqual(error.exception.code, "stale_sequence")
        self.assertEqual(client.latest_sequence, "0")
        result = client.input("arm", "scalar", 127)
        self.assertEqual((result["sequence"], result["input_sequence"]), ("2", "1"))
        self.assertEqual(client.calls[-1][1]["expected_input_sequence"], "0")
        self.assertNotIn("expected_sequence", client.calls[-1][1])
        self.assertEqual(client.latest_input_sequence, "1")
        self.assertEqual(client.refresh_input_sequence(), "1")
        self.assertEqual(client.refresh_sequence(), "2")

    def test_input_conflict_is_definitely_not_executed_and_not_retried(self):
        client = self.client()
        client.event("pause", 127, reason="hold_expired")
        before = len(client.calls)
        with self.assertRaises(SurfaceError) as error:
            client.input("arm", "scalar", 127)
        self.assertEqual(error.exception.code, "stale_input_sequence")
        self.assertEqual(len(client.calls), before + 1)
        self.assertEqual(client.latest_input_sequence, "0")
        self.assertEqual(client.refresh_input_sequence(), "1")
        self.assertEqual(client.input("arm", "scalar", 127, cas="input")["input_sequence"], "2")

    def test_legacy_host_fallback_and_invalid_explicit_modes(self):
        client = self.client(independent=False)
        client.input("arm", "scalar", 127)
        self.assertEqual(client.calls[-1][1]["expected_sequence"], "0")
        for mode in ("input", "bogus"):
            with self.assertRaises(SurfaceError):
                client.input("arm", "scalar", 127, cas=mode)
        with self.assertRaises(SurfaceError):
            client.refresh_input_sequence()

    def test_paginated_cursor_does_not_regress_client_input_highwater_or_skip_events(self):
        client = self.client()
        events = EventCursor(client, clock=lambda: 1, limit=1)
        events.bootstrap(client.snapshot())
        client.event("start", 127)
        client.event("arm", "on", kind="feedback", encoding="indicator")
        client.event("pause", 127)
        # Feedback response observes intervening inputs, without moving the read cursor.
        self.assertEqual(client.feedback("arm", "indicator", "on")["sequence"], "4")
        self.assertEqual(client.latest_input_sequence, "2")
        self.assertEqual(events.sequence, 0)
        seen = []
        for _ in range(4):
            seen.extend(entry["event"]["sequence"] for entry in events.poll())
            self.assertEqual(client.latest_input_sequence, "2")
        self.assertEqual(seen, ["1", "2", "3", "4"])
        self.assertEqual(events.input_sequence, 2)
        self.assertEqual(events.sequence, 4)

    def test_event_input_highwater_and_writer_are_checked_and_failure_invalidates(self):
        for mutate in (lambda row: row.pop("writer_id"),
                       lambda row: row.__setitem__("writer_id", "bad id"),
                       lambda row: row.pop("input_sequence"),
                       lambda row: row.__setitem__("input_sequence", "0"),
                       lambda row: row.__setitem__("input_sequence", "2")):
            client = self.client()
            events = EventCursor(client, clock=lambda: 1)
            events.bootstrap(client.snapshot())
            client.event("start", 127)
            mutate(client.rows[0])
            with self.assertRaises(SurfaceError):
                events.poll()
            self.assertTrue(events.invalidated)
        client = self.client()
        events = EventCursor(client, clock=lambda: 1)
        events.bootstrap(client.snapshot())
        client.event("arm", "on", kind="feedback", encoding="indicator")
        client.rows[0]["input_sequence"] = "1"
        with self.assertRaises(SurfaceError):
            events.poll()

    def test_discovery_extensions_are_capability_consistent_and_limits_strict(self):
        for mutate in (lambda d: d.pop("latest_input_sequence"),
                       lambda d: d.__setitem__("latest_input_sequence", "1"),
                       lambda d: d["write_limits"].__setitem__("input_per_window", True),
                       lambda d: d["write_limits"].__setitem__("window_s", 2),
                       lambda d: d["write_limits"].__setitem__("extra", 1),
                       lambda d: d.pop("write_limits")):
            client = QFixture()
            value = client.disc()
            mutate(value)
            client.response_override = value
            with self.assertRaises(SurfaceError):
                client.discover()
        client = QFixture(independent=False, limits=False)
        value = client.disc()
        value["latest_input_sequence"] = "0"
        client.response_override = value
        with self.assertRaises(SurfaceError):
            client.discover()

    def test_mutation_metadata_is_checked_before_highwaters_change(self):
        for mutate in (lambda row: row.pop("writer_id"),
                       lambda row: row.__setitem__("input_sequence", "0"),
                       lambda row: row.__setitem__("input_sequence", "2")):
            client = self.client()
            row = {"expected": client.expected, "source": "simulation", "sequence": "1", "input_sequence": "1",
                   "writer_id": "principal.remote", "time": 1, "origin": "remote", "kind": "input",
                   "disposition": "accepted", "control_id": "arm", "encoding": "scalar", "value": 127}
            mutate(row)
            client.response_override = row
            with self.assertRaises(SurfaceError):
                client.input("arm", "scalar", 127)
            self.assertEqual(client.latest_sequence, "0")
            self.assertEqual(client.latest_input_sequence, "0")

    def test_reset_clears_both_counters_and_keeps_global_request(self):
        client = self.client()
        client.input("arm", "scalar", 127)
        client.reset()
        self.assertEqual((client.latest_sequence, client.latest_input_sequence), ("0", "0"))
        self.assertEqual(client.calls[-1][1]["expected_sequence"], "1")
        self.assertNotIn("expected_input_sequence", client.calls[-1][1])


if __name__ == "__main__":
    unittest.main()
