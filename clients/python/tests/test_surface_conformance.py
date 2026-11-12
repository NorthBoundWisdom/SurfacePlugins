"""An independent in-memory public-tool host for live checker tests."""
import contextlib
import copy
import io
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from surface_control import Client, SurfaceError, mapping_revision
from surface_conformance import CheckFailure, run_fixture

ROOT = Path(__file__).resolve().parents[3]


class MemoryHost(Client):
    def __init__(self):
        super().__init__("http://127.0.0.1:9876/mcp", "secret-test-token", "memory")
        fixture = json.loads((ROOT / "fixtures/surface-control-software-v1.3.json").read_bytes())
        self.role_map = {"schema_version": 1, "roles": {name: name for name in fixture["roles"]}, "writer_ids": {"remote": "writer.remote"}}
        controls = []
        for name, role in fixture["roles"].items():
            row = {"id": name, "input_kind": role.get("input_kind", "button"), "encoding": role.get("encoding", "boolean"), "feedback_kinds": [role["feedback_kind"]] if "feedback_kind" in role else [], "accepts_input": role.get("accepts_input", True)}
            if row["encoding"] == "scalar" or role.get("feedback_kind") == "value":
                row["range"] = {"minimum": 0, "maximum": 100, "step": 1}
            if role.get("hold"):
                row["hold"] = {"rest_value": False, "max_hold_s": 2}
            controls.append(row)
        self.prof = {"id": "memory.profile", "version": "1", "controls": controls, "capabilities": ["simulation", "input.independent_sequence", "events.writer_id", "controls.input_declared", "feedback.unsequenced"]}
        self.generation = 0
        self.requests = []
        self.failure = None
        self.bad_expectation = False
        self.reset_state()

    def reset_state(self):
        self.head = self.input_head = 0
        self.events = []
        self.inputs = {row["id"]: False if row["encoding"] == "boolean" else 0 for row in self.prof["controls"]}
        self.feedback_values = {}

    def disc(self):
        return {"schema_version": 1, "contract_version": "1.3", "source": "simulation", "profile": copy.deepcopy(self.prof), "latest_sequence": str(self.head), "latest_input_sequence": str(self.input_head), "expected": {"instance_id": "memory", "epoch": "generation." + str(self.generation), "mapping_revision": mapping_revision(self.prof), "profile_id": "memory.profile", "profile_version": "1"}}

    def call(self, name, arguments=None):
        arguments = arguments or {}
        self.requests.append((name, copy.deepcopy(arguments)))
        if self.failure and name.endswith(self.failure[0]):
            raise SurfaceError(self.failure[1])
        if name.endswith("discover"):
            return self.disc()
        if name.endswith("snapshot"):
            return {"discovery": self.disc(), "latest_sequence": str(self.head), "latest_input_sequence": str(self.input_head), "server_time": 1, "inputs": copy.deepcopy(self.inputs), "feedback": copy.deepcopy(self.feedback_values)}
        if name.endswith("events"):
            return {"expected": self.disc()["expected"], "latest_sequence": str(self.head), "latest_input_sequence": str(self.input_head), "server_time": 1, "events": copy.deepcopy([row for row in self.events if int(row["sequence"]) > int(arguments["after_sequence"])])}
        if arguments["expected"] != self.disc()["expected"]:
            raise SurfaceError("stale_epoch")
        if "expected_sequence" in arguments and arguments["expected_sequence"] != str(self.head):
            raise SurfaceError("stale_sequence")
        if "expected_input_sequence" in arguments and arguments["expected_input_sequence"] != str(self.input_head):
            raise SurfaceError("stale_input_sequence")
        if name.endswith("reset"):
            self.generation += 1
            self.reset_state()
            return self.disc()
        row = next(c for c in self.prof["controls"] if c["id"] == arguments["control_id"])
        feedback = name.endswith("feedback")
        if not feedback and not row["accepts_input"]:
            raise SurfaceError("permission_denied")
        if "hold_s" in arguments and "hold" not in row:
            raise SurfaceError("unsupported_hold")
        if not feedback and row["encoding"] != arguments["encoding"]:
            raise SurfaceError("unsupported_encoding")
        ignored = not feedback and self.inputs[row["id"]] == arguments["value"]
        self.head += 1
        if not feedback:
            self.input_head += 1
        event = {"expected": self.disc()["expected"], "sequence": str(self.head), "input_sequence": str(self.input_head), "source": "simulation", "origin": "remote", "writer_id": "writer.remote", "kind": "feedback" if feedback else "input", "control_id": row["id"], "encoding": arguments.get("kind", arguments.get("encoding")), "value": arguments["value"], "disposition": "ignored" if ignored else "accepted", "time": 1}
        if ignored:
            event["reason"] = "no_change"
        if self.bad_expectation:
            event["disposition"] = "ignored"
        self.events.append(event)
        if feedback:
            self.feedback_values.setdefault(row["id"], {})[arguments["kind"]] = arguments["value"]
        else:
            self.inputs[row["id"]] = arguments["value"]
        return copy.deepcopy(event)


def fixture_bytes(scenarios):
    fixture = json.loads((ROOT / "fixtures/surface-control-software-v1.3.json").read_bytes())
    fixture["scenarios"] = scenarios
    return json.dumps(fixture).encode()


class ConformanceTests(unittest.TestCase):
    def test_live_fixture_reports_actual_pass_skip_counts_and_hash(self):
        host = MemoryHost()
        raw = (ROOT / "fixtures/surface-control-software-v1.3.json").read_bytes()
        report = run_fixture(host, raw, host.role_map)
        self.assertEqual(report["counts"]["fail"], 0, report)
        self.assertGreater(report["counts"]["pass"], 30)
        self.assertGreater(report["counts"]["skip"], 30)
        self.assertEqual(sum(report["counts"].values()), 97)
        self.assertEqual(report["fixture_sha256"], hashlib.sha256(raw).hexdigest())
        self.assertNotIn("secret-test-token", json.dumps(report))

    def test_contract_violation_is_failure_and_stops_scenario(self):
        host = MemoryHost()
        host.bad_expectation = True
        raw = fixture_bytes([{"id": "bad", "scope": "host", "steps": [{"operation": "input", "role": "input_a", "value": "maximum", "expect": {"disposition": "accepted"}}, {"operation": "snapshot", "expect": {}}]}])
        report = run_fixture(host, raw, host.role_map)
        self.assertEqual(report["counts"], {"pass": 0, "fail": 1, "skip": 1})

    def test_response_must_match_request_and_committed_journal(self):
        host = MemoryHost()
        original = host.call
        def call(name, arguments=None):
            result = original(name, arguments)
            if name.endswith("input"):
                result["control_id"] = "input_b"
            return result
        host.call = call
        raw = fixture_bytes([{"id": "wrong-result", "steps": [{"operation": "input", "role": "input_a", "value": "maximum", "expect": {"disposition": "accepted"}}]}])
        report = run_fixture(host, raw, host.role_map)
        self.assertEqual(report["counts"], {"pass": 0, "fail": 1, "skip": 0})
        self.assertEqual(report["steps"][0]["disposition"], "accepted")

    def test_unknown_transport_is_not_retried_and_tail_is_skipped(self):
        host = MemoryHost()
        host.failure = ("input", "transport_unknown")
        raw = fixture_bytes([{"id": "lost", "scope": "host", "steps": [{"operation": "input", "role": "input_a", "value": "maximum", "expect": {}}, {"operation": "input", "role": "input_a", "value": "minimum", "expect": {}}]}])
        report = run_fixture(host, raw, host.role_map)
        self.assertEqual(report["counts"], {"pass": 0, "fail": 1, "skip": 1})
        self.assertEqual(sum(name.endswith("input") for name, _ in host.requests), 1)
        self.assertEqual(report["steps"][0]["error"], "transport_unknown")

    def test_missing_role_and_clock_expectation_skip_dependent_tail(self):
        for step in ({"operation": "input", "role": "blocked_input", "value": "minimum", "expect": {}}, {"operation": "input", "role": "hold_input", "value": "active", "hold_s": 1, "expect": {"hold_deadline_at_s": 1.1}}):
            host = MemoryHost()
            host.role_map["roles"].pop("blocked_input")
            raw = fixture_bytes([{"id": "unavailable", "scope": "host", "steps": [step, {"operation": "input", "role": "input_a", "value": "minimum", "expect": {}}]}])
            report = run_fixture(host, raw, host.role_map)
            self.assertEqual(report["counts"], {"pass": 0, "fail": 0, "skip": 2})
            self.assertEqual([name for name, _ in host.requests], ["surface_control_discover"])

    def test_unimplemented_expectation_fails_instead_of_silently_passing(self):
        host = MemoryHost()
        raw = fixture_bytes([{"id": "future", "steps": [{"operation": "snapshot", "expect": {"future_invariant": True}}]}])
        report = run_fixture(host, raw, host.role_map)
        self.assertEqual(report["counts"]["fail"], 1)

    def test_reset_permission_failure_is_skip_and_never_retried(self):
        host = MemoryHost()
        host.failure = ("reset", "permission_denied")
        raw = fixture_bytes([{"id": "resetless", "steps": [{"operation": "snapshot", "expect": {"sequence": "0"}}, {"operation": "snapshot", "expect": {}}]}])
        report = run_fixture(host, raw, host.role_map)
        self.assertEqual(report["counts"], {"pass": 0, "fail": 0, "skip": 2})
        self.assertEqual(sum(name.endswith("reset") for name, _ in host.requests), 1)

    def test_skipped_atomic_rejection_does_not_taint_unchanged_poststate(self):
        host = MemoryHost()
        raw = fixture_bytes([{"id": "atomic", "steps": [
            {"operation": "input", "role": "blocked_input", "value": "minimum", "expect": {"error": "permission_denied", "atomic": True}},
            {"operation": "input", "role": "input_a", "value": "maximum", "expect": {"disposition": "accepted", "accepted_input_delta": 1}}
        ]}])
        report = run_fixture(host, raw, host.role_map)
        self.assertEqual(report["counts"], {"pass": 1, "fail": 0, "skip": 1})
        self.assertFalse(report["steps"][0]["executed"])
        self.assertNotIn("actual", report["steps"][0])
        self.assertEqual(sum(name.endswith("input") for name, _ in host.requests), 1)

    def test_reset_recovers_after_skipped_successful_mutation(self):
        host = MemoryHost()
        host.role_map["roles"].pop("input_b")
        raw = fixture_bytes([{"id": "recover", "steps": [
            {"operation": "input", "role": "input_b", "value": "maximum", "expect": {"disposition": "accepted"}},
            {"operation": "snapshot", "expect": {"sequence": "1"}},
            {"operation": "reset", "expect": {"epoch_changed": True, "sequence": "0"}},
            {"operation": "snapshot", "expect": {"sequence": "0"}}
        ]}])
        report = run_fixture(host, raw, host.role_map)
        self.assertEqual([row["status"] for row in report["steps"]], ["skip", "skip", "pass", "pass"])

    def test_one_per_fixture_role_file_runs_all_four_frozen_fixtures(self):
        host = MemoryHost()
        documents = [json.loads(path.read_bytes()) for path in sorted((ROOT / "fixtures").glob("surface-control-software-v*.json"))]
        roles = {"schema_version": 1, "writer_ids": host.role_map["writer_ids"], "fixtures": {doc["scenario_id"]: {"roles": {name: name for name in doc["roles"]}} for doc in documents}}
        for document in documents:
            other = MemoryHost()
            report = run_fixture(other, json.dumps(document).encode(), roles)
            self.assertEqual(report["counts"]["fail"], 0, document["scenario_id"])
        wrong = copy.deepcopy(roles)
        wrong["fixtures"][documents[0]["scenario_id"]]["roles"]["misspelled_role"] = "input_a"
        with self.assertRaises(CheckFailure):
            run_fixture(MemoryHost(), json.dumps(documents[0]).encode(), wrong)
        wrong = dict(roles, roles={})
        with self.assertRaises(CheckFailure):
            run_fixture(MemoryHost(), json.dumps(documents[0]).encode(), wrong)

    def test_wire_invariants_reject_corrupt_journal_even_without_fixture_expectations(self):
        mutations = [lambda e: e.update(source="hardware"), lambda e: e.update(kind="future"),
                     lambda e: e.update(sequence="02"), lambda e: e.update(sequence="2"),
                     lambda e: e.update(input_sequence="0"), lambda e: e.pop("writer_id"),
                     lambda e: e.update(writer_id="invalid id"), lambda e: e.update(control_id="missing"),
                     lambda e: e.update(encoding="boolean"), lambda e: e.update(origin="hardware"),
                     lambda e: e.update(time=float("nan"))]
        for mutate in mutations:
            host = MemoryHost()
            original = host.call
            def call(name, arguments=None):
                result = original(name, arguments)
                if name.endswith("input"):
                    mutate(host.events[-1])
                    return copy.deepcopy(host.events[-1])
                return result
            host.call = call
            raw = fixture_bytes([{"id": "wire", "steps": [{"operation": "input", "role": "input_a", "value": "maximum", "expect": {}}]}])
            report = run_fixture(host, raw, host.role_map)
            self.assertEqual(report["counts"]["fail"], 1, mutate)

    def test_secret_echo_is_absent_from_report_stdout_and_stderr(self):
        from surface_conformance.__main__ import main
        host = MemoryHost()
        host.failure = ("input", host.token)
        raw = fixture_bytes([{"id": "echo", "steps": [{"operation": "input", "role": "input_a", "value": "maximum", "expect": {}}]}])
        report = run_fixture(host, raw, host.role_map)
        self.assertNotIn(host.token, json.dumps(report))
        self.assertEqual(report["steps"][0]["error"], "credential_reflection")
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / "token").write_text(host.token)
            (folder / "fixture").write_bytes(raw)
            (folder / "roles").write_text(json.dumps(host.role_map))
            argv = ["checker", "--url", host.url, "--token-file", str(folder / "token"), "--instance-id", host.instance_id, "--fixture", str(folder / "fixture"), "--roles", str(folder / "roles"), "--report", str(folder / "report")]
            for failure in (("input", host.token), ("discover", host.token)):
                host.failure = failure
                out, err = io.StringIO(), io.StringIO()
                with mock.patch("sys.argv", argv), mock.patch("surface_conformance.__main__.Client", return_value=host), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                    status = main()
                self.assertIn(status, (1, 2))
                self.assertNotIn(host.token, out.getvalue() + err.getvalue() + (folder / "report").read_text())

    def test_descriptor_mismatch_is_configuration_failure(self):
        host = MemoryHost()
        host.prof["controls"][-1]["accepts_input"] = True
        with self.assertRaises(CheckFailure):
            run_fixture(host, (ROOT / "fixtures/surface-control-software-v1.3.json").read_bytes(), host.role_map)

    def test_each_supported_expectation_detects_deliberate_corruption(self):
        # Exercise every assertion family reachable in a live prefix using the real fixture.
        host = MemoryHost()
        raw = (ROOT / "fixtures/surface-control-software-v1.3.json").read_bytes()
        good = run_fixture(host, raw, host.role_map)
        self.assertEqual(good["counts"]["fail"], 0)
        tested = set()
        fixture = json.loads(raw)
        for row in good["steps"]:
            if row["status"] != "pass":
                continue
            scenario = next(s for s in fixture["scenarios"] if s["id"] == row["scenario"])
            for key in scenario["steps"][row["step"]]["expect"]:
                if key in tested:
                    continue
                altered = copy.deepcopy(scenario)
                value = altered["steps"][row["step"]]["expect"][key]
                altered["steps"][row["step"]]["expect"][key] = (not value if type(value) is bool else "deliberately-wrong" if isinstance(value, str) else 999 if type(value) is int else (["input_a"] if key == "holds" else []) if isinstance(value, list) else {"input_a": "maximum"})
                other = MemoryHost()
                if key == "writer_kind":
                    altered["steps"][row["step"]]["expect"][key] = value
                    other.role_map["writer_ids"][value] = "wrong.public.id"
                report = run_fixture(other, fixture_bytes([altered]), other.role_map)
                self.assertGreater(report["counts"]["fail"], 0, key)
                tested.add(key)
        self.assertTrue({"disposition", "known_inputs", "accepted_input_delta", "event_count", "event_input_sequences", "event_writer_kinds"} <= tested)


if __name__ == "__main__":
    unittest.main()
