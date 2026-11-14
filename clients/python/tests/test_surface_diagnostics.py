"""Read-only diagnostics exercise real loopback HTTP; never physical device evidence."""
import contextlib
import copy
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from surface_control import SurfaceError
from surface_control_testing import TestOnlyHardwareHost
from surface_control_diagnostics import ReadOnlyClient, capture, verify, load_capture, READ_TOOLS
from surface_control_diagnostics.__main__ import main

TOKEN = "test-diagnostic-token-no-secret"


class DiagnosticTests(unittest.TestCase):
    def collect(self, host, *, hook=None, required=None, polls=2, event_limit=1024):
        client = ReadOnlyClient(host.url, TOKEN, host.instance_id, accepted_sources=("hardware",))
        ticks = [1000.0]
        def advance(_):
            ticks[0] += 0.01
            if hook:
                hook(host)
        result = capture(client, host.profile["id"], host.profile["version"], required_controls=required,
                         limits={"max_polls": polls, "interval_s": 0, "max_events": event_limit},
                         clock=lambda: ticks[0], sleep=advance)
        self.assertTrue(set(host.requests) <= READ_TOOLS)
        self.assertNotIn(TOKEN, json.dumps(result))
        return result

    def test_unknown_initial_is_preserved_and_is_not_complete(self):
        with TestOnlyHardwareHost(TOKEN) as host:
            result = self.collect(host, polls=1)
            self.assertEqual(result["snapshot"]["inputs"], {})
            self.assertEqual(result["end"]["reason"], "unknown_inputs")
            report = verify(result)
            self.assertEqual(report["exit_code"], 1)
            self.assertEqual(report["capture_integrity"], "verified_recorded_invariants")
            self.assertIn("new_events_not_observed", report["unavailable"])

    def test_accepted_and_ignored_followed_read_only_and_offline_replay(self):
        with TestOnlyHardwareHost(TOKEN) as host:
            def events(host):
                host.apply_step({"operation": "input", "control_id": "axis", "value": 63})
                host.apply_step({"operation": "input", "control_id": "button", "value": True, "disposition": "ignored", "reason": "no_binding"})
            result = self.collect(host, hook=events, required=["axis"])
            events = result["pages"][1]["page"]["events"]
            self.assertEqual([row["disposition"] for row in events], ["accepted", "ignored"])
            self.assertEqual(result["end"]["event_count"], 2)
            with patch("urllib.request.OpenerDirector.open", side_effect=AssertionError("offline opened network")):
                report = verify(result)
            self.assertEqual(report["exit_code"], 0)
            self.assertEqual(report["required_control_scope"], "explicit_subset")
            self.assertFalse(report["physical_qualification"])

    def test_initial_disconnected_capture_is_structurally_valid_but_nonzero(self):
        with TestOnlyHardwareHost(TOKEN) as host:
            host.connected = False
            result = self.collect(host, polls=1)
            self.assertEqual(result["snapshot"]["link"], {"state": "disconnected"})
            self.assertEqual(result["pages"], [])
            self.assertEqual(result["end"]["reason"], "link_disconnected")
            self.assertEqual(verify(result)["exit_code"], 1)

    def test_epoch_gap_and_same_epoch_disconnect_end_without_recovery(self):
        for operation, reason in (("disconnect", "stale_epoch"), ("gap", "event_gap"), ("link-only", "link_disconnected")):
            with self.subTest(operation=operation), TestOnlyHardwareHost(TOKEN) as host:
                def change(host):
                    if operation == "link-only":
                        host.connected = False
                    else:
                        host.apply_step({"operation": operation})
                result = self.collect(host, hook=change)
                self.assertEqual(result["end"]["reason"], reason)
                self.assertEqual(verify(result)["exit_code"], 1)
                self.assertEqual(host.requests.count("surface_control_discover"), 1)
                self.assertEqual(host.requests.count("surface_control_snapshot"), 1)

    def test_event_limit_does_not_lose_backlog_or_claim_complete(self):
        with TestOnlyHardwareHost(TOKEN) as host:
            def events(host):
                for value in (1, 2, 3):
                    host.apply_step({"operation": "input", "control_id": "axis", "value": value})
            result = self.collect(host, hook=events, required=["axis"], polls=3, event_limit=1)
            self.assertEqual(result["end"]["event_count"], 1)
            self.assertTrue(result["end"]["pending_events"])
            self.assertEqual(result["end"]["reason"], "pending_events")
            self.assertEqual(verify(result)["exit_code"], 1)

    def test_credential_reflection_in_data_and_error_is_never_saved(self):
        for mode in ("data", "error"):
            class Reflector(TestOnlyHardwareHost):
                def tool(self, name, arguments):
                    if mode == "error":
                        raise SurfaceError(TOKEN)
                    result = super().tool(name, arguments)
                    result["profile"]["id"] = TOKEN
                    return result
            with Reflector(TOKEN) as host:
                result = self.collect(host, polls=1)
                self.assertEqual(result["end"]["reason"], "credential_reflection")
                self.assertIsNone(result["discovery"])
                self.assertEqual(verify(result)["exit_code"], 1)

    def test_corrupt_capture_fields_sequences_and_status_are_rejected(self):
        with TestOnlyHardwareHost(TOKEN) as host:
            def events(host):
                host.apply_step({"operation": "input", "control_id": "axis", "value": 12})
            original = self.collect(host, hook=events, required=["axis"])
        mutations = [lambda d: d.update(headers={"Authorization": "secret"}),
                     lambda d: d["pages"][1]["page"]["events"][0].update(sequence="99"),
                     lambda d: d["pages"][1]["page"]["events"][0].update(origin="remote"),
                     lambda d: d["pages"][1]["page"]["events"][0]["expected"].update(epoch="old"),
                     lambda d: d["snapshot"]["inputs"].update(axis=999),
                     lambda d: d["end"].update(event_count=999),
                     lambda d: d["end"].update(unknown_controls=["axis"]),
                     lambda d: d["pages"][1].update(result="error", error_code="invalid_capture")]
        for change in mutations:
            malformed = copy.deepcopy(original)
            change(malformed)
            with self.subTest(mutation=mutations.index(change)), self.assertRaises(SurfaceError):
                verify(malformed)
        with self.assertRaises(SurfaceError):
            load_capture(b'{"a":1,"a":2}')

    def test_cli_capture_verify_exit_codes_private_artifacts_and_no_writes(self):
        with tempfile.TemporaryDirectory() as temporary, TestOnlyHardwareHost(TOKEN) as host:
            root = Path(temporary)
            (root / "token").write_text(TOKEN)
            args = ["capture", "--url", host.url, "--token-file", str(root / "token"), "--instance-id", host.instance_id,
                    "--profile-id", host.profile["id"], "--profile-version", host.profile["version"], "--accept-hardware",
                    "--max-polls", "1", "--output", str(root / "capture.json")]
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                self.assertEqual(main(args), 1)
                self.assertEqual(main(["verify", "--capture", str(root / "capture.json"), "--report", str(root / "report.json")]), 1)
                (root / "corrupt.json").write_text('{"schema_version": 1}')
                self.assertEqual(main(["verify", "--capture", str(root / "corrupt.json")]), 2)
                self.assertEqual(main(["capture", "--unexpected-secret-value", TOKEN]), 2)
            self.assertTrue(set(host.requests) <= READ_TOOLS)
            self.assertEqual((root / "capture.json").stat().st_mode & 0o777, 0o600)
            for text in (stdout.getvalue(), stderr.getvalue(), (root / "capture.json").read_text(), (root / "report.json").read_text()):
                self.assertNotIn(TOKEN, text)
            self.assertNotIn("Authorization", (root / "capture.json").read_text())

    def test_readonly_fence_and_invalid_scope_fail_before_network(self):
        with TestOnlyHardwareHost(TOKEN) as host:
            client = ReadOnlyClient(host.url, TOKEN, host.instance_id, accepted_sources=("hardware",))
            for tool in ("surface_control_input", "surface_control_feedback", "surface_control_renew", "surface_control_reset"):
                with self.assertRaises(SurfaceError):
                    client.call(tool)
            self.assertEqual(host.requests, [])

    def test_duration_and_byte_budgets_preserve_a_bounded_prefix(self):
        with TestOnlyHardwareHost(TOKEN) as host:
            client = ReadOnlyClient(host.url, TOKEN, host.instance_id, accepted_sources=("hardware",))
            now = [1000.0]
            def advance(_):
                now[0] += 2
            result = capture(client, host.profile["id"], host.profile["version"], limits={"duration_s": 1}, clock=lambda: now[0], sleep=advance)
            self.assertEqual(result["end"]["trigger"], "duration_limit")
            self.assertEqual(len(result["pages"]), 1)
            self.assertEqual(verify(result)["exit_code"], 1)
        with TestOnlyHardwareHost(TOKEN) as host:
            host.profile["controls"] *= 1
            # A large legal profile exhausts a deliberately small artifact budget.
            base = host.profile["controls"][0]
            for index in range(80):
                host.profile["controls"].append({**base, "id": "extra." + str(index)})
            client = ReadOnlyClient(host.url, TOKEN, host.instance_id, accepted_sources=("hardware",))
            result = capture(client, host.profile["id"], host.profile["version"], limits={"max_bytes": 4096, "max_polls": 1})
            self.assertEqual(result["end"]["reason"], "byte_limit")
            self.assertLessEqual(len(json.dumps(result).encode()), 4096)
            self.assertEqual(verify(result)["exit_code"], 1)

    def test_transport_failure_and_missing_hardware_opt_in_are_incomplete(self):
        class BrokenTransport(TestOnlyHardwareHost):
            def tool(self, name, arguments):
                if name == "surface_control_events":
                    self.requests.append(name)
                    raise SurfaceError("transport_unknown")
                return super().tool(name, arguments)
        with BrokenTransport(TOKEN) as host:
            result = self.collect(host, polls=1)
            report = verify(result)
            self.assertEqual(result["end"]["reason"], "transport_unknown")
            self.assertEqual(report["exit_code"], 1)
            self.assertIn("terminal_error_without_response_evidence", report["unavailable"])
        with TestOnlyHardwareHost(TOKEN) as host:
            client = ReadOnlyClient(host.url, TOKEN, host.instance_id)
            result = capture(client, host.profile["id"], host.profile["version"], limits={"max_polls": 1})
            self.assertEqual(result["end"]["reason"], "unsupported_contract")
            self.assertEqual(verify(result)["exit_code"], 1)

    def test_stale_event_age_is_rejected_using_sdk_freshness(self):
        with TestOnlyHardwareHost(TOKEN) as host:
            def old_event(host):
                host.apply_step({"operation": "input", "control_id": "axis", "value": 12})
                host.time = 10
            result = self.collect(host, hook=old_event, required=["axis"])
            self.assertEqual(result["end"]["reason"], "input_stale")
            self.assertEqual(result["end"]["event_count"], 0)
            report = verify(result)
            self.assertEqual(report["exit_code"], 1)
            self.assertEqual(report["rejected_page_count"], 1)
