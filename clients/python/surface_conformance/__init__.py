"""Live fixture runner. Public observations only; never retries a write."""
from __future__ import annotations

import copy
import hashlib
import json
import re

from surface_control import CONTRACT_VERSIONS, EventCursor, SurfaceError, admits, cursor, finite


class CheckFailure(Exception):
    pass


def check(condition, message):
    if not condition:
        raise CheckFailure(message)


def safe_error(error, token=None):
    code = error.code
    if not isinstance(code, str) or (token and token in code):
        return "credential_reflection"
    return code if re.fullmatch(r"[a-z][a-z0-9_]{0,63}", code) else "untrusted_error"


def select_roles(document, fixture):
    check(isinstance(document, dict) and set(document) <= {"schema_version", "roles", "fixtures", "writer_ids"}, "invalid role map fields")
    check(type(document.get("schema_version")) is int and document["schema_version"] == 1, "invalid role map version")
    check(("roles" in document) != ("fixtures" in document), "select exactly one role-map mode")
    if "fixtures" in document:
        fixtures = document["fixtures"]
        check(isinstance(fixtures, dict) and fixture["scenario_id"] in fixtures, "fixture role mapping absent")
        selected = fixtures[fixture["scenario_id"]]
        check(isinstance(selected, dict) and set(selected) == {"roles"}, "invalid fixture role entry")
        document = {"schema_version": 1, "roles": selected["roles"], "writer_ids": document.get("writer_ids", {})}
    check(isinstance(document.get("roles"), dict), "invalid role dictionary")
    return document


def validate_roles(document, fixture, profile):
    roles = document["roles"]
    check(set(roles) <= set(fixture["roles"]), "unknown role")
    mapped = [v for v in roles.values() if v is not None]
    check(all(isinstance(v, str) and v for v in mapped) and len(set(mapped)) == len(mapped), "roles must map to separate control IDs")
    controls = {row["id"]: row for row in profile["controls"]}
    for name, ident in roles.items():
        if ident is None:
            continue
        check(ident in controls, "mapped control is absent")
        row, required = controls[ident], fixture["roles"][name]
        for key in ("input_kind", "encoding", "accepts_input"):
            if key in required:
                check(row.get(key) == required[key], "role descriptor mismatch: " + name + "." + key)
        if required.get("hold"):
            check(isinstance(row.get("hold"), dict), "role requires hold descriptor")
        if "feedback_kind" in required:
            check(required["feedback_kind"] in row.get("feedback_kinds", []), "role requires feedback kind")
    writers = document.get("writer_ids", {})
    check(isinstance(writers, dict) and set(writers) <= {"remote", "interface", "system"}, "invalid writer kinds")
    check(all(isinstance(v, str) and v for v in writers.values()), "invalid public writer ID")
    return controls


class Runner:
    def __init__(self, client, fixture, roles, fixture_sha256):
        self.client, self.fixture = client, fixture
        self.roles = select_roles(roles, fixture)
        self.digest = fixture_sha256
        self.last_write = None

    def value(self, role, symbolic, *, feedback=False):
        row = self.controls[self.roles["roles"][role]]
        if symbolic == "rest":
            return row["hold"]["rest_value"]
        if symbolic == "active":
            rest = row["hold"]["rest_value"]
            return not rest if row["encoding"] == "boolean" else next(v for v in (row["range"]["minimum"], row["range"]["maximum"]) if v != rest)
        if symbolic in ("minimum", "maximum"):
            span = row.get("feedback_range", row.get("range")) if feedback else row.get("range")
            return span[symbolic] if span else symbolic == "maximum"
        return symbolic

    def page(self, after="0"):
        snapshot = self.client.snapshot()
        self.validate_snapshot(snapshot)
        expected = snapshot["discovery"]["expected"]
        page = self.client.call("surface_control_events", {"instance_id": expected["instance_id"], "epoch": expected["epoch"], "after_sequence": after, "limit": 1024})
        check(page.get("expected") == expected, "event identity differs from snapshot")
        check(page.get("latest_sequence") == snapshot["latest_sequence"], "concurrent journal change")
        # Validate the complete epoch journal using an isolated SDK cursor/cache. This
        # must not move the runner's explicitly selected fixture CAS or issue another call.
        validator = copy.copy(self.client)
        validator.call = lambda *_: page
        baseline = {"discovery": {"expected": expected}, "latest_sequence": "0"}
        if "input.independent_sequence" in validator.profile.get("capabilities", []):
            baseline["latest_input_sequence"] = "0"
        events = EventCursor(validator, clock=lambda: 0)
        events.bootstrap(baseline)
        events.poll()
        check(events.sequence == cursor(page["latest_sequence"]), "incomplete epoch journal")
        check(page.get("holds", {}) == snapshot.get("holds", {}), "page and snapshot holds differ")
        self.validate_holds(snapshot)
        for event in page["events"]:
            row = self.controls.get(event["control_id"])
            check(row is not None, "journal references unknown control")
            if event["kind"] == "input":
                check(event.get("encoding") == row["encoding"] and admits(row, event.get("value")), "invalid journal input value or encoding")
            else:
                self.validate_feedback(row, event.get("encoding"), event.get("value"))
        return snapshot, page

    def validate_snapshot(self, snapshot):
        discovery = snapshot["discovery"]
        check(discovery.get("contract_version") == self.client.contract_version and discovery.get("profile") == self.client.profile, "snapshot profile or contract changed")
        check(discovery.get("latest_sequence") == snapshot["latest_sequence"], "snapshot discovery highwater differs")
        for ident, value in snapshot["inputs"].items():
            check(ident in self.controls and admits(self.controls[ident], value), "invalid snapshot input")
        for ident, values in snapshot["feedback"].items():
            check(ident in self.controls and isinstance(values, dict), "invalid snapshot feedback control")
            for kind, value in values.items():
                self.validate_feedback(self.controls[ident], kind, value)
        self.validate_holds(snapshot)

    def validate_feedback(self, row, kind, value):
        check(kind in row.get("feedback_kinds", []), "invalid feedback kind")
        if kind == "indicator":
            check(value in ("off", "on", "blink"), "invalid feedback indicator")
        elif kind == "value":
            descriptor = {**row, "range": row.get("feedback_range", row.get("range"))}
            if descriptor.get("range") is not None:
                descriptor["encoding"] = "scalar"
            check(admits(descriptor, value), "invalid feedback value")
        else:
            raise CheckFailure("unsupported feedback kind")

    def validate_holds(self, snapshot):
        for ident, deadline in snapshot.get("holds", {}).items():
            row = self.controls.get(ident)
            check("input.hold" in self.client.profile.get("capabilities", []) and row is not None and "hold" in row, "hold capability or control absent")
            check(finite(deadline) and deadline > snapshot["server_time"], "invalid current hold deadline")

    def prepare(self):
        # A fresh SDK identity cache is needed after an authorized reset.
        self.client.reset()
        self.last_write = None
        snapshot, page = self.page()
        check(snapshot["latest_sequence"] == "0" and not page["events"], "reset did not clear history")
        self.initial = copy.deepcopy(self.client.expected)
        return snapshot, page

    def unsupported(self, scenario, step):
        if scenario.get("scope") == "inprocess":
            return "inprocess scenario requires private host state or fault injection"
        if scenario.get("event_capacity", 1024) != 1024:
            return "journal capacity cannot be configured by public tools"
        if step["operation"] in ("advance", "restart") or "clock_override_s" in step or "invalid_value" in step:
            return "operation requires clock, process, or nonfinite-value injection"
        expect = step.get("expect", {})
        if expect.get("atomic"):
            return "atomic expectation includes private engine state unavailable through public tools; request not submitted"
        if set(expect) & {"hold_deadline_at_s", "hold_deadlines_at_s", "expired", "instance_changed"}:
            return "expectation requires exact injected clock or process control"
        names = {step["role"]} if "role" in step else set()
        names.update(expect.get("known_inputs", {}))
        names.update(expect.get("holds", []))
        for name in names:
            if not self.roles["roles"].get(name):
                return "role unavailable: " + name
        kinds = set(expect.get("event_writer_kinds", []))
        if "writer_kind" in expect:
            kinds.add(expect["writer_kind"])
        if not kinds <= set(self.roles.get("writer_ids", {})):
            return "trusted public writer ID mapping unavailable"
        return None

    def execute(self, step):
        op, client = step["operation"], self.client
        if op in ("snapshot", "refresh_sequence"):
            result = client.snapshot()
            self.validate_snapshot(result)
            return result
        if op == "events":
            return client.call("surface_control_events", {"instance_id": client.instance_id, "epoch": client.expected["epoch"], "after_sequence": step["after_sequence"], "limit": 1024})
        if op == "replay_last_write":
            check(self.last_write is not None, "no saved write to replay")
            return client.call(*copy.deepcopy(self.last_write))
        expected = self.initial if step.get("expected_scope") == "initial" else client.expected
        arguments = {"expected": copy.deepcopy(expected)}
        if op not in ("renew",) and not step.get("omit_sequence", False):
            key = "expected_input_sequence" if "expected_input_sequence" in step else "expected_sequence"
            arguments[key] = step.get(key, client.latest_sequence)
        if op in ("input", "feedback", "renew"):
            role = step["role"]
            arguments["control_id"] = self.roles["roles"][role]
            row = self.controls[arguments["control_id"]]
            if op != "renew":
                arguments["value"] = self.value(role, step["value"], feedback=op == "feedback")
                arguments["kind" if op == "feedback" else "encoding"] = self.fixture["roles"][role]["feedback_kind"] if op == "feedback" else step.get("encoding", row["encoding"])
            if "hold_s" in step:
                arguments["hold_s"] = step["hold_s"]
        check(op in ("input", "feedback", "renew", "reset"), "unsupported operation")
        request = ("surface_control_" + op, arguments)
        self.last_write = copy.deepcopy(request)
        result = client.reset() if op == "reset" else client.renew(arguments["control_id"], arguments["hold_s"]) if op == "renew" else client.call(*request)
        return result

    def verify(self, step, result, error, before, after):
        expect = step.get("expect", {})
        snap, page = after
        prior, prior_page = before
        events = page["events"]
        count = lambda rows: sum(row.get("kind") == "input" and row.get("disposition") == "accepted" for row in rows)
        actual = {}
        if error is None and step["operation"] in ("snapshot", "refresh_sequence"):
            fields = ("discovery", "latest_sequence", "latest_input_sequence", "inputs", "feedback", "holds")
            check(all(result.get(field) == snap.get(field) for field in fields), "snapshot result differs from following observation")
        if error is None and step["operation"] == "events":
            expected_events = [row for row in events if cursor(row["sequence"]) > cursor(step["after_sequence"])]
            check(result.get("events") == expected_events, "event operation differs from validated epoch journal")
            for field in ("expected", "latest_sequence", "latest_input_sequence", "holds"):
                check(result.get(field, {} if field == "holds" else None) == page.get(field, {} if field == "holds" else None), "event page metadata differs")
            check(finite(result.get("server_time")) and prior["server_time"] <= result["server_time"] <= page["server_time"], "invalid event page time")
        if error is None and step["operation"] in ("input", "feedback"):
            arguments = self.last_write[1]
            check(result.get("expected") == snap["discovery"]["expected"], "mutation identity differs from snapshot")
            check(result.get("source") == "simulation" and result.get("origin") == "remote", "mutation source or origin differs")
            check(result.get("kind") == step["operation"], "mutation kind differs")
            for field in ("control_id", "value"):
                check(result.get(field) == arguments[field], "mutation result differs from request: " + field)
            check(result.get("encoding") == arguments.get("encoding", arguments.get("kind")), "mutation encoding differs")
            check(cursor(result.get("sequence")) > cursor(prior["latest_sequence"]), "mutation returned an old journal event")
            if "expected_sequence" in arguments:
                check(cursor(result["sequence"]) == cursor(prior["latest_sequence"]) + 1, "sequenced mutation skipped a journal sequence")
            check(any(row == result for row in events), "mutation response differs from committed journal event")
        if error is None and step["operation"] == "reset":
            check(result.get("expected") == snap["discovery"]["expected"], "reset response identity differs")
            for field in ("instance_id", "mapping_revision", "profile_id", "profile_version"):
                check(result["expected"].get(field) == prior["discovery"]["expected"].get(field), "reset changed profile or instance")
        for key, wanted in expect.items():
            if key == "error":
                got = error
            elif key == "disposition":
                got = result.get("disposition")
            elif key in ("sequence", "latest_sequence"):
                got = snap["latest_sequence"]
            elif key == "latest_input_sequence":
                got = (result.get("input_sequence") if step["operation"] in ("input", "feedback") else result.get(key))
                check(got == snap.get(key), "result and snapshot input highwaters differ")
            elif key == "accepted_input_count":
                got = count(events)
            elif key == "accepted_input_delta":
                got = count(events) - count(prior_page["events"])
            elif key == "inputs_unchanged":
                got = snap["inputs"] == prior["inputs"]
            elif key == "epoch_changed":
                got = snap["discovery"]["expected"]["epoch"] != prior["discovery"]["expected"]["epoch"]
            elif key == "known_inputs":
                got = {name: snap["inputs"].get(self.roles["roles"][name]) for name in wanted}
                wanted = {name: self.value(name, value) for name, value in wanted.items()}
            elif key == "holds":
                got = sorted(snap.get("holds", {}))
                if step["operation"] == "events":
                    check(result.get("holds", {}) == snap.get("holds", {}), "event-page holds differ")
                wanted = sorted(self.roles["roles"][name] for name in wanted)
            elif key == "atomic":
                fields = ("discovery", "latest_sequence", "latest_input_sequence", "inputs", "feedback", "holds")
                # Discovery may contain no clock. All observable control state and journal must be unchanged.
                got = all(prior.get(field) == snap.get(field) for field in fields) and prior_page["events"] == events
            elif key == "event_count":
                got = len(result.get("events", []))
            elif key == "event_reasons":
                got = [row.get("reason") for row in result.get("events", [])]
            elif key == "event_input_sequences":
                got = [row.get("input_sequence") for row in result.get("events", [])]
            elif key == "writer_kind":
                got = result.get("writer_id")
                wanted = self.roles["writer_ids"][wanted]
            elif key == "event_writer_kinds":
                got = [row.get("writer_id") for row in result.get("events", [])]
                wanted = [self.roles["writer_ids"][kind] for kind in wanted]
            else:
                raise CheckFailure("unimplemented expectation: " + key)
            check(got == wanted, "expectation mismatch: " + key)
            actual[key] = got
        check(error is None or "error" in expect, "unexpected tool error: " + str(error))
        check(error is not None or "error" not in expect, "expected tool rejection was absent")
        # Check highwater at the actual operation result too, not only a follow-up snapshot.
        for key in ("sequence", "latest_sequence"):
            if key in expect and error is None:
                observed = result.get("sequence", result.get("latest_sequence"))
                check(observed == expect[key], "operation result highwater differs")
        return actual

    def run(self):
        discovery = self.client.discover()
        fixture_version = self.fixture.get("contract_version", "1.0")
        check(fixture_version in CONTRACT_VERSIONS and CONTRACT_VERSIONS.index(fixture_version) <= CONTRACT_VERSIONS.index(discovery["contract_version"]), "fixture contract exceeds host contract")
        check(set(self.fixture.get("required_capabilities", [])) <= set(self.client.profile.get("capabilities", [])), "required capabilities absent")
        self.controls = validate_roles(self.roles, self.fixture, self.client.profile)
        report = {"schema_version": 1, "fixture_id": self.fixture["scenario_id"], "fixture_sha256": self.digest,
                  "fixture_contract_version": fixture_version, "contract_version": discovery["contract_version"], "profile_id": self.client.profile["id"],
                  "profile_version": self.client.profile["version"], "mapping_revision": self.client.expected["mapping_revision"],
                  "roles": self.roles["roles"], "steps": []}
        for scenario in self.fixture["scenarios"]:
            dependency = None
            failed = False
            before = None
            for index, step in enumerate(scenario["steps"]):
                entry = {"scenario": scenario["id"], "step": index, "operation": step["operation"], "status": "skip", "executed": False}
                unsupported = self.unsupported(scenario, step)
                # An explicit successful reset reestablishes state after skipped mutations.
                recovery = dependency and not failed and step["operation"] == "reset" and not step.get("expect", {}).get("error") and not unsupported
                reason = unsupported or (dependency if not recovery else None)
                if reason:
                    entry["reason"] = reason
                    # A skipped rejection+atomic probe would not change state. Reads do not
                    # change it either. Only missing successful transitions taint later steps.
                    unchanged = step.get("expect", {}).get("error") and step.get("expect", {}).get("atomic")
                    scene_unavailable = scenario.get("scope") == "inprocess" or scenario.get("event_capacity", 1024) != 1024
                    if scene_unavailable or (not unchanged and step["operation"] not in ("snapshot", "events", "refresh_sequence")):
                        dependency = dependency or "state prerequisite unavailable after skipped step"
                else:
                    try:
                        if before is None:
                            try:
                                before = self.prepare()
                            except SurfaceError as exc:
                                code = safe_error(exc, self.client.token)
                                if code in ("permission_denied", "simulation_admin_disabled", "reset_disabled"):
                                    entry["reason"] = "reset unavailable: " + code
                                    dependency = entry["reason"]
                                    failed = True
                                    report["steps"].append(entry)
                                    continue
                                raise
                        result, error = {}, None
                        entry["executed"] = True
                        try:
                            result = self.execute(step)
                        except SurfaceError as exc:
                            error = safe_error(exc, self.client.token)
                            if error in ("transport_unknown", "invalid_response", "rpc_error", "session_changed", "provider_mismatch", "redirect_refused", "credential_reflection", "untrusted_error") or error.startswith("http_"):
                                raise SurfaceError(error) from None
                        if error:
                            entry["error"] = error
                        if "disposition" in result:
                            entry["disposition"] = result["disposition"]
                        after = self.page()
                        entry["actual"] = self.verify(step, result, error, before, after)
                        entry["status"] = "pass"
                        before = after
                        if recovery:
                            dependency = None
                    except (SurfaceError, CheckFailure) as exc:
                        entry["status"] = "fail"
                        entry["reason"] = safe_error(exc, self.client.token) if isinstance(exc, SurfaceError) else str(exc)
                        if isinstance(exc, SurfaceError):
                            entry["error"] = safe_error(exc, self.client.token)
                        dependency = "prior failed step; scenario stopped"
                        failed = True
                report["steps"].append(entry)
        report["counts"] = {status: sum(row["status"] == status for row in report["steps"]) for status in ("pass", "fail", "skip")}
        return report


def run_fixture(client, fixture_bytes, roles):
    fixture = json.loads(fixture_bytes)
    return Runner(client, fixture, roles, hashlib.sha256(fixture_bytes).hexdigest()).run()
