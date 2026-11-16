"""SDK1.5 cursors and source fences; deterministic host behavior, no physical devices."""
import copy
import unittest
from unittest.mock import patch
from test_surface_control import QFixture
from test_hardware_sdk import HardwareClient
from surface_control import Client, EventCursor, InputEventCursor, SurfaceError, __version__, mapping_revision
from surface_control_diagnostics import ReadOnlyClient, capture, verify
from surface_control_testing import TestOnlyHardwareHost, example_profile


class RetainedHost(QFixture):
    def __init__(self, capacity=4):
        super().__init__()
        self.contract = "1.5"
        self.prof["version"] = "retained-1.5"
        self.prof["capabilities"].append("events.input_retention")
        self.capacity = capacity
        self.page_mutator = None
        self.failure = None

    def call(self, name, arguments=None):
        if name != "surface_control_input_events":
            return super().call(name, arguments)
        self.calls.append((name, arguments))
        if self.failure:
            raise SurfaceError(self.failure)
        if arguments["expected"] != self.disc()["expected"]:
            raise SurfaceError("stale_epoch")
        after = int(arguments["after_input_sequence"])
        rows = [e for e in self.rows if e["kind"] == "input"][-self.capacity:]
        if after > self.input_head or rows and after < int(rows[0]["input_sequence"]) - 1:
            raise SurfaceError("input_event_gap")
        result = {"expected": self.disc()["expected"], "server_time": self.response_time,
                  "latest_sequence": str(self.head), "latest_input_sequence": str(self.input_head),
                  "input_event_capacity": self.capacity,
                  "events": copy.deepcopy([e for e in rows if int(e["input_sequence"]) > after][:arguments["limit"]])}
        if self.page_mutator:
            self.page_mutator(result)
        return result


class Hardware15(HardwareClient):
    def __init__(self, *, retained=False, rehearsal=False, **kwargs):
        super().__init__(**kwargs)
        self.retained = retained
        self.prof["version"] = "1.5"
        if retained:
            self.prof["capabilities"] += ["input.independent_sequence", "events.input_retention"]
        if rehearsal:
            self.prof["id"] = "test.owned-virtual-rehearsal"
            self.prof["capabilities"].append("session.owned_virtual_rehearsal")
        self.identity.update(profile_id=self.prof["id"], profile_version=self.prof["version"], mapping_revision=mapping_revision(self.prof))

    def discovery(self):
        result = super().discovery()
        result["contract_version"] = "1.5"
        if self.retained:
            result["latest_input_sequence"] = str(sum(e["kind"] == "input" for e in self.events))
        return result

    def call(self, name, arguments=None):
        if name == "surface_control_input_events":
            self.calls.append((name, arguments))
            return {"expected": copy.deepcopy(self.identity), "server_time": 1, "latest_sequence": str(len(self.events)),
                    "latest_input_sequence": str(sum(e["kind"] == "input" for e in self.events)), "input_event_capacity": 4,
                    "events": copy.deepcopy([e for e in self.events if e["kind"] == "input" and int(e["input_sequence"]) > int(arguments["after_input_sequence"])][:arguments["limit"]]),
                    "link": {"state": self.link_state}}
        result = super().call(name, arguments)
        if name.endswith("snapshot") and self.retained:
            result["latest_input_sequence"] = str(sum(e["kind"] == "input" for e in self.events))
        return result


class InputRetentionSDKTests(unittest.TestCase):
    def prepared(self, *, limit=1024, capacity=4):
        client = RetainedHost(capacity)
        client.discover()
        tracker = InputEventCursor(client, clock=lambda: 1, limit=limit)
        tracker.bootstrap(client.snapshot())
        return client, tracker

    def test_current_version_is_deliberately_15_and_old_versions_remain_allowlisted(self):
        self.assertEqual(__version__, "1.5.0")
        self.assertEqual(RetainedHost().discover()["contract_version"], "1.5")
        with self.assertRaises(SurfaceError):
            RetainedHost().discover(versions=("1.3",))

    def test_capability_required_with_no_rpc_or_silent_fallback(self):
        client = QFixture(); client.discover()
        count = len(client.calls)
        with self.assertRaises(SurfaceError) as error:
            InputEventCursor(client)
        self.assertEqual(error.exception.code, "unsupported_input_retention")
        self.assertEqual(len(client.calls), count)
        legacy = EventCursor(client, clock=lambda: 1); legacy.bootstrap(client.snapshot())
        self.assertEqual(legacy.poll(), [])
        self.assertEqual(client.calls[-1][0], "surface_control_events")

    def test_feedback_skips_global_sequence_and_pagination_keeps_newer_cas(self):
        client, tracker = self.prepared(limit=1)
        client.event("start", 127)
        for _ in range(20):
            client.event("arm", "on", kind="feedback", encoding="indicator")
        client.event("pause", 127, disposition="ignored", reason="inactive_layer")
        client.event("cancel", 0, reason="hold_expired")
        client.feedback("arm", "indicator", "off")
        self.assertEqual(client.latest_sequence, "24"); self.assertEqual(client.latest_input_sequence, "3")
        seen = []
        for expected in (1, 2, 3):
            seen += tracker.poll()
            self.assertEqual(tracker.input_sequence, expected)
            self.assertEqual(client.latest_sequence, "24"); self.assertEqual(client.latest_input_sequence, "3")
        self.assertEqual([e["event"]["sequence"] for e in seen], ["1", "22", "23"])
        self.assertEqual([e["event"]["input_sequence"] for e in seen], ["1", "2", "3"])
        self.assertEqual(tracker.poll(), [])
        self.assertEqual(client.calls[-1][1]["after_input_sequence"], "3")
        self.assertTrue(all(tracker.fresh(e, now=1) for e in seen))

    def test_input_overflow_is_terminal_gap_and_is_not_retried(self):
        client, tracker = self.prepared(capacity=1)
        client.event("start", 127); client.event("pause", 127)
        before = len(client.calls)
        with self.assertRaises(SurfaceError) as error:
            tracker.poll()
        self.assertEqual(error.exception.code, "input_event_gap")
        self.assertEqual(len(client.calls), before + 1)
        self.assertEqual(tracker.input_sequence, 0)
        self.assertTrue(tracker.invalidated)
        with self.assertRaises(SurfaceError) as error:
            tracker.poll()
        self.assertEqual(error.exception.code, "recovery_required")
        self.assertEqual(len(client.calls), before + 1)

    def test_bad_second_event_does_not_commit_first_event_or_highwaters(self):
        client, tracker = self.prepared()
        client.event("start", 127); client.event("pause", 127)
        client.rows[-1]["writer_id"] = "bad writer"
        with self.assertRaises(SurfaceError):
            tracker.poll()
        self.assertEqual((tracker.input_sequence, tracker.sequence), (0, 0))
        self.assertEqual((client.latest_input_sequence, client.latest_sequence), ("0", "0"))
        self.assertIsNone(tracker.last_event_time)

    def test_page_and_input_shape_fences_are_strict(self):
        mutations = [lambda p: p["events"][0].__setitem__("kind", "feedback"),
                     lambda p: p["events"][0].__setitem__("input_sequence", "2"),
                     lambda p: p["events"][0].__setitem__("sequence", "0"),
                     lambda p: p["events"][0].__setitem__("encoding", "boolean"),
                     lambda p: p["events"][0].__setitem__("value", 128),
                     lambda p: p["events"][0].__setitem__("origin", []),
                     lambda p: p["events"][0].__setitem__("disposition", []),
                     lambda p: p["events"][0].__setitem__("time", 2),
                     lambda p: p["events"][0].__setitem__("source", "hardware"),
                     lambda p: p["events"].clear(), lambda p: p.__setitem__("input_event_capacity", True),
                     lambda p: p.__setitem__("debug", "unknown"), lambda p: p.__setitem__("link", {"state": "connected"})]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                client, tracker = self.prepared()
                client.event("start", 127); client.page_mutator = mutate
                with self.assertRaises(SurfaceError):
                    tracker.poll()
                self.assertTrue(tracker.invalidated)
                self.assertEqual(tracker.input_sequence, 0)

    def test_context_transport_and_highwater_rollback_cannot_recover_silently(self):
        for mode in ("epoch", "transport", "rollback"):
            with self.subTest(mode=mode):
                client, tracker = self.prepared()
                client.event("start", 127)
                if mode == "epoch": client.epoch = "next"
                elif mode == "transport": client.failure = "transport_unknown"
                else: client.latest_sequence = "2"
                with self.assertRaises(SurfaceError) as error:
                    tracker.poll()
                self.assertEqual(error.exception.code, {"epoch": "stale_epoch", "transport": "transport_unknown", "rollback": "sequence_rollback"}[mode])
                self.assertTrue(tracker.invalidated); self.assertEqual(tracker.input_sequence, 0)

    def test_declared_retention_cannot_be_smuggled_into_old_version_or_without_input_sequence(self):
        for mutate in (lambda c: setattr(c, "contract", "1.3"), lambda c: c.prof["capabilities"].remove("input.independent_sequence")):
            client = RetainedHost(); mutate(client)
            with self.assertRaises(SurfaceError): client.discover()

    def test_hardware15_retained_or_rehearsal_always_reject_remote_inputs(self):
        for retained, rehearsal in ((True, False), (False, True), (True, True)):
            with self.subTest(retained=retained, rehearsal=rehearsal):
                with self.assertRaises(SurfaceError): Hardware15(retained=retained, rehearsal=rehearsal).discover()
                client = Hardware15(retained=retained, rehearsal=rehearsal, accepted_sources=("hardware",))
                client.discover(); self.assertEqual(client.snapshot()["inputs"], {})
                self.assertEqual(client.owned_virtual_rehearsal, rehearsal)
                for operation, code in ((lambda: client.input("axis", "scalar", 1), "permission_denied"),
                                        (lambda: client.renew("touch", 1), "unsupported_hold"), (client.reset, "unsupported_tool")):
                    before = len(client.calls)
                    with self.assertRaises(SurfaceError) as error: operation()
                    self.assertEqual(error.exception.code, code); self.assertEqual(len(client.calls), before)
                if not retained:
                    with self.assertRaises(SurfaceError): InputEventCursor(client)

    def test_rehearsal_on_simulation_is_rejected_and_missing_hardware_link_is_rejected(self):
        client = RetainedHost(); client.prof["capabilities"].append("session.owned_virtual_rehearsal")
        with self.assertRaises(SurfaceError): client.discover()
        client = Hardware15(retained=True, accepted_sources=("hardware",)); client.discover()
        call = client.call
        def missing_link(name, arguments=None):
            result = call(name, arguments)
            if name.endswith("snapshot"): result.pop("link")
            return result
        client.call = missing_link
        with self.assertRaises(SurfaceError) as error: client.snapshot()
        self.assertEqual(error.exception.code, "invalid_link")

    def test_rehearsal_capture_and_offline_verify_keep_explicit_nonphysical_marker(self):
        prof = example_profile(); prof["id"] = "test.owned-virtual-rehearsal"
        prof["capabilities"].append("session.owned_virtual_rehearsal")
        with TestOnlyHardwareHost("rehearsal-test-token", profile=prof) as host:
            original = host.discover
            def discovery15():
                result = original(); result["contract_version"] = "1.5"; return result
            host.discover = discovery15
            client = ReadOnlyClient(host.url, "rehearsal-test-token", host.instance_id, accepted_sources=("hardware",))
            document = capture(client, prof["id"], prof["version"], limits={"max_polls": 1})
            self.assertEqual(document["rehearsal"], {"owned_virtual_rehearsal": True, "physical_evidence": False})
            with patch("urllib.request.OpenerDirector.open", side_effect=AssertionError("offline opened network")):
                report = verify(document)
            self.assertEqual(report["rehearsal"], document["rehearsal"])
            self.assertFalse(report["physical_qualification"])
            for tamper in (lambda d: d.pop("rehearsal"), lambda d: d["rehearsal"].__setitem__("physical_evidence", True)):
                bad = copy.deepcopy(document); tamper(bad)
                with self.assertRaises(SurfaceError): verify(bad)


class AdditionalInputRetentionTests(unittest.TestCase):
    def test_hardware_input_cursor_checks_link_origin_and_keeps_unknown_unknown(self):
        for fault in (None, "remote", "disconnected", "missing-link"):
            with self.subTest(fault=fault):
                client = Hardware15(retained=True, accepted_sources=("hardware",)); client.discover()
                snapshot = client.snapshot(); tracker = InputEventCursor(client, clock=lambda: 1); tracker.bootstrap(snapshot)
                client.events.append({"expected": copy.deepcopy(client.identity), "sequence": "1", "input_sequence": "1", "source": "hardware", "origin": "remote" if fault == "remote" else "hardware",
                                      "kind": "input", "control_id": "axis", "encoding": "scalar", "value": 63, "disposition": "accepted", "time": 1})
                if fault == "disconnected": client.link_state = "disconnected"
                if fault == "missing-link":
                    call = client.call
                    def missing_link(name, arguments=None):
                        result = call(name, arguments)
                        if name == "surface_control_input_events": result.pop("link")
                        return result
                    client.call = missing_link
                if fault is None:
                    self.assertEqual(tracker.poll()[0]["event"]["origin"], "hardware")
                    self.assertEqual(snapshot["inputs"], {})
                else:
                    with self.assertRaises(SurfaceError): tracker.poll()
                    self.assertTrue(tracker.invalidated); self.assertEqual(tracker.input_sequence, 0)

    def test_simulation_15_preserves_held_input_renew_and_global_reset(self):
        # Reuse the unchanged old-version matrix host's actual lease behavior, adding the
        # explicit 1.5 declaration rather than bypassing the SDK's version gates.
        from test_sdk_version_matrix import VersionHost
        class Held15(VersionHost):
            def __init__(self):
                super().__init__("1.3")
                self.contract = "1.5"; self.prof["version"] = "1.5"
                self.prof["capabilities"].append("events.input_retention")
            def call(self, name, arguments=None):
                # VersionHost's 1.3-specific fake wire rejection is obsolete only for this
                # new host; QFixture executes the same explicit 1.5 input CAS behavior.
                if name.endswith("input") and "expected_input_sequence" in (arguments or {}):
                    result = QFixture.call(self, name, arguments)
                    if "hold_s" in arguments: result["hold_deadline"] = 1 + arguments["hold_s"]
                    return result
                return super().call(name, arguments)
        client = Held15(); client.discover()
        self.assertEqual(client.input("arm", "scalar", 127, hold_s=1)["hold_deadline"], 2)
        self.assertEqual(client.renew("arm", 1)["hold_deadline"], 2)
        self.assertEqual(client.latest_input_sequence, "1")
        client.reset(); self.assertEqual((client.latest_sequence, client.latest_input_sequence), ("0", "0"))
        self.assertEqual(client.calls[-1][1]["expected_sequence"], "1")

    def test_failed_bootstrap_invalidates_explicit_cursor(self):
        client = RetainedHost(); client.discover(); tracker = InputEventCursor(client)
        bad = client.snapshot(); bad["discovery"]["source"] = "hardware"
        with self.assertRaises(SurfaceError): tracker.bootstrap(bad)
        self.assertTrue(tracker.invalidated)
