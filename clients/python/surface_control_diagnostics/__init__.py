"""Bounded, read-only software diagnostics. No device qualification or business interpretation."""
from __future__ import annotations

import copy
import json
import re
import time

from surface_control import Client, EventCursor, SurfaceError, __version__, admits, cursor, decode, finite
from surface_conformance import safe_error

ARTIFACT = "surface-control-diagnostic-capture"
QUALIFICATION = "software-diagnostic-only"
READ_TOOLS = frozenset(("surface_control_discover", "surface_control_snapshot", "surface_control_events"))
MAX_CAPTURE_BYTES = 16 * 1024 * 1024
DEFAULT_LIMITS = {"duration_s": 10.0, "interval_s": 0.1, "max_polls": 100, "max_events": 1024,
                  "max_bytes": 8 * 1024 * 1024, "max_age_s": 2.0}
ENVELOPE = {"schema_version", "artifact", "qualification", "sdk_version", "requested", "limits", "discovery", "snapshot", "pages", "clock_origin_s", "elapsed_s", "end"}

ERROR_CODES = frozenset(("credential_reflection", "untrusted_error", "unsupported_contract", "unsupported_profile", "unsupported_control",
    "invalid_argument", "invalid_profile", "invalid_identity", "invalid_response", "invalid_snapshot", "invalid_events", "invalid_event",
    "invalid_link", "invalid_input_sequence", "invalid_sequence", "invalid_writer", "invalid_write_limits", "invalid_time", "time_rollback",
    "instance_mismatch", "stale_epoch", "stale_mapping", "stale_sequence", "context_changed", "session_changed", "provider_mismatch",
    "event_gap", "sequence_rollback", "transport_unknown", "rpc_error", "initialization_failed", "redirect_refused", "invalid_clock",
    "input_stale", "link_disconnected", "permission_denied", "byte_limit", "not_initialized", "tool_error",
    "invalid_value", "unsupported_encoding", "unsupported_feedback", "invalid_result", "sequence_exhausted",
    "unsupported_hold", "hold_expired", "hold_expiry_pending", "stale_input_sequence", "invalid_capture", "invalid_limits", "readonly_client_required", "invalid_profile_pin", "invalid_required_controls",
    "invalid_source_allowlist", "invalid_output_path", "invalid_arguments"))

def safe_code(error, token=None):
    code = safe_error(error, token)
    return code if code in ERROR_CODES or re.fullmatch(r"http_[1-5][0-9]{2}", code) else "untrusted_error"


def check(condition, code="invalid_capture"):
    if not condition:
        raise SurfaceError(code)


def encoded(value):
    return json.dumps(value, ensure_ascii=True, allow_nan=False, sort_keys=True, separators=(",", ":")).encode() + b"\n"


def reject_reflection(value, token):
    """Reject whole untrusted values before storing, including reflected credentials in keys."""
    if isinstance(value, str):
        check(not token or token not in value, "credential_reflection")
        check(not value.lower().startswith(("bearer ", "authorization:")), "credential_reflection")
    elif isinstance(value, dict):
        for key, item in value.items():
            reject_reflection(key, token)
            reject_reflection(item, token)
    elif isinstance(value, list):
        for item in value:
            reject_reflection(item, token)


def reject_extra_fields(name, value):
    """Capture only contract data, never unknown transport/debug fields or headers."""
    discovery = {"schema_version", "contract_version", "source", "expected", "profile", "latest_sequence", "latest_input_sequence", "write_limits"}
    profile = {"id", "version", "controls", "capabilities"}
    control = {"id", "input_kind", "encoding", "range", "feedback_range", "feedback_kinds", "mapping", "hold", "accepts_input"}
    event = {"expected", "sequence", "input_sequence", "writer_id", "time", "source", "origin", "kind", "control_id", "encoding", "value", "disposition", "mapped_value", "reason", "hold_deadline"}
    def fields(row, allowed):
        check(isinstance(row, dict) and set(row) <= allowed, "invalid_response")
    def discovered(row):
        fields(row, discovery)
        fields(row.get("profile"), profile)
        controls = row["profile"].get("controls")
        check(isinstance(controls, list), "invalid_response")
        for item in controls:
            fields(item, control)
    if name == "surface_control_discover":
        discovered(value)
    elif name == "surface_control_snapshot":
        fields(value, {"discovery", "server_time", "latest_sequence", "latest_input_sequence", "inputs", "feedback", "holds", "link"})
        discovered(value.get("discovery"))
    else:
        fields(value, {"server_time", "expected", "latest_sequence", "latest_input_sequence", "events", "holds", "link"})
        check(isinstance(value.get("events"), list), "invalid_response")
        for item in value["events"]:
            fields(item, event)


class ReadOnlyClient(Client):
    """SDK transport fenced to three reads, even on failure paths. Never issues mutation probes."""
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.last_page = None

    def call(self, name, arguments=None):
        check(name in READ_TOOLS, "diagnostic_write_forbidden")
        value = super().call(name, arguments)
        reject_reflection(value, self.token)
        reject_extra_fields(name, value)
        if name == "surface_control_events":
            self.last_page = copy.deepcopy(value)
        return value


def validate_limits(limits):
    check(set(limits) == set(DEFAULT_LIMITS), "invalid_limits")
    for key in ("duration_s", "max_age_s"):
        check(finite(limits[key]) and 0 < limits[key] <= 3600, "invalid_limits")
    check(finite(limits["interval_s"]) and 0 <= limits["interval_s"] <= 60, "invalid_limits")
    for key, upper in (("max_polls", 10000), ("max_events", 65536), ("max_bytes", MAX_CAPTURE_BYTES)):
        check(type(limits[key]) is int and 1 <= limits[key] <= upper, "invalid_limits")
    check(limits["max_bytes"] >= 4096, "invalid_limits")


def validate_observations(client, snapshot):
    """Only validate recorded values; missing controls remain unknown."""
    d = snapshot["discovery"]
    check(d.get("profile") == client.profile and d.get("contract_version") == client.contract_version,
          "context_changed")
    check(d.get("latest_sequence") == snapshot.get("latest_sequence"), "invalid_snapshot")
    for ident, value in snapshot["inputs"].items():
        check(admits(client.control(ident), value), "invalid_snapshot")
    for ident, values in snapshot["feedback"].items():
        check(isinstance(values, dict), "invalid_snapshot")
        row = client.control(ident)
        for kind, value in values.items():
            check(kind in row.get("feedback_kinds", []), "invalid_snapshot")
            if kind == "indicator":
                check(value in ("off", "on", "blink"), "invalid_snapshot")
            else:
                check(admits({**row, "range": row.get("feedback_range", row.get("range"))}, value), "invalid_snapshot")


def validate_page_values(client, page):
    for event in page["events"]:
        row = client.control(event["control_id"])
        if event["kind"] == "input":
            check(event.get("encoding") == row["encoding"] and admits(row, event.get("value")), "invalid_event")
        else:
            kind, value = event.get("encoding"), event.get("value")
            check(kind in row.get("feedback_kinds", []), "invalid_event")
            if kind == "indicator":
                check(value in ("off", "on", "blink"), "invalid_event")
            else:
                check(admits({**row, "range": row.get("feedback_range", row.get("range"))}, value), "invalid_event")


def unknown_controls(document):
    snapshot = document["snapshot"]
    if snapshot is None:
        return None
    known = set(snapshot["inputs"])
    for record in document["pages"]:
        if record["result"] == "ok":
            for event in record["page"]["events"]:
                if event["kind"] == "input" and event["disposition"] == "accepted":
                    known.add(event["control_id"])
    required = document["requested"]["required_controls"]
    if required is None:
        required = [row["id"] for row in document["discovery"]["profile"]["controls"]]
    return sorted(set(required) - known)


def _end(document, trigger, reason, elapsed, event_count, polls):
    unknown = unknown_controls(document)
    pending = False
    if document["pages"]:
        good = [row for row in document["pages"] if row["result"] == "ok"]
        if good:
            last = good[-1]["page"]
            events = last["events"]
            last_sequence = events[-1]["sequence"] if events else last["latest_sequence"]
            pending = cursor(last_sequence) < cursor(last["latest_sequence"])
    if reason is None:
        reason = "unknown_inputs" if unknown else ("pending_events" if pending else ("no_poll_evidence" if polls == 0 else "bounded_complete"))
    document["elapsed_s"] = elapsed
    document["end"] = {"trigger": trigger, "reason": reason, "exit_code": 0 if reason == "bounded_complete" else 1,
                       "event_count": event_count, "poll_count": polls, "unknown_controls": unknown,
                       "pending_events": pending}


def capture(client, profile_id, profile_version, *, required_controls=None, limits=None, clock=time.monotonic, sleep=time.sleep):
    """Collect one pinned generation. Unknown controls yield exit 1 at the bound, not default values.

    Only successful validated data or a final SDK-rejected page is retained. Errors without a page
    preserve the validated prefix; their remote causes cannot be proved by offline verification.
    """
    check(isinstance(client, ReadOnlyClient), "readonly_client_required")
    limits = {**DEFAULT_LIMITS, **(limits or {})}
    validate_limits(limits)
    check(isinstance(profile_id, str) and profile_id and isinstance(profile_version, str) and profile_version, "invalid_profile_pin")
    check(required_controls is None or isinstance(required_controls, (list, tuple)) and required_controls
          and all(isinstance(item, str) and item for item in required_controls)
          and len(set(required_controls)) == len(required_controls), "invalid_required_controls")
    source = "hardware" if tuple(client.accepted_sources) == ("hardware",) else "simulation"
    check(tuple(client.accepted_sources) in (("hardware",), ("simulation",)), "invalid_source_allowlist")
    document = {"schema_version": 1, "artifact": ARTIFACT, "qualification": QUALIFICATION, "sdk_version": __version__,
                "requested": {"source": source, "instance_id": client.instance_id, "profile_id": profile_id,
                              "profile_version": profile_version, "required_controls": list(required_controls) if required_controls else None},
                "limits": limits, "discovery": None, "snapshot": None, "pages": [], "clock_origin_s": 0.0, "elapsed_s": 0.0, "end": None}
    reject_reflection(document, client.token)
    start = clock()
    check(finite(start), "invalid_clock")
    document["clock_origin_s"] = start
    event_count = polls = 0
    trigger, reason = "setup", None
    tracker = None

    def elapsed():
        value = clock() - start
        check(finite(value) and value >= 0, "invalid_clock")
        return value

    def budget(candidate):
        # Include realistic terminal fields, particularly a potentially large unknown list.
        draft = copy.deepcopy(candidate)
        _end(draft, "byte_limit", "byte_limit", elapsed(), event_count, polls)
        check(len(encoded(draft)) + 512 <= limits["max_bytes"], "byte_limit")

    try:
        budget(document)
        discovery = client.discover(profiles=(profile_id,), profile_versions=(profile_version,))
        candidate = {**document, "discovery": copy.deepcopy(discovery)}
        budget(candidate)
        document = candidate
        if required_controls is not None:
            for ident in required_controls:
                client.control(ident)
        snapshot = client.snapshot()
        validate_observations(client, snapshot)
        candidate = {**document, "snapshot": copy.deepcopy(snapshot)}
        budget(candidate)
        document = candidate
        tracker = EventCursor(client, clock=clock, max_age=limits["max_age_s"], limit=min(128, limits["max_events"]))
        tracker.bootstrap(snapshot)
        while True:
            if elapsed() >= limits["duration_s"]:
                trigger = "duration_limit"
                break
            if polls >= limits["max_polls"]:
                trigger = "poll_limit"
                break
            if event_count >= limits["max_events"]:
                trigger = "event_limit"
                break
            tracker.limit = min(128, limits["max_events"] - event_count)
            client.timeout = min(client.timeout, max(0.001, limits["duration_s"] - elapsed()))
            client.last_page = None
            ticks = []
            def record_clock():
                value = clock()
                ticks.append(value)
                return value
            tracker.clock = record_clock
            try:
                entries = tracker.poll()
                validate_page_values(client, client.last_page)
                check(all(tracker.fresh(entry, now=ticks[-1]) for entry in entries), "input_stale")
                page_error = None
            except SurfaceError as error:
                entries = []
                page_error = safe_code(error, client.token)
                if client.last_page is None:
                    raise
            check(len(ticks) == 2, "invalid_clock")
            record = {"started_s": ticks[0], "received_s": ticks[1], "page": client.last_page,
                      "result": "error" if page_error else "ok", "error_code": page_error}
            candidate = {**document, "pages": document["pages"] + [record]}
            budget(candidate)
            document = candidate
            polls += 1
            if page_error:
                trigger, reason = "error", page_error
                break
            event_count += len(entries)
            if polls < limits["max_polls"] and event_count < limits["max_events"]:
                sleep(min(limits["interval_s"], max(0, limits["duration_s"] - elapsed())))
    except SurfaceError as error:
        trigger, reason = "error", safe_code(error, client.token)
    except (ValueError, TypeError, KeyError, OverflowError):
        trigger, reason = "error", "invalid_response"
    _end(document, trigger, reason, elapsed(), event_count, polls)
    check(len(encoded(document)) <= limits["max_bytes"], "byte_limit")
    reject_reflection(document, client.token)
    return document


class _ReplayClient(Client):
    """In-memory SDK adapter; construction and all reads are offline."""
    def call(self, name, arguments=None):
        check(name in READ_TOOLS)
        if name == "surface_control_discover":
            return copy.deepcopy(self.document["discovery"])
        if name == "surface_control_snapshot":
            return copy.deepcopy(self.document["snapshot"])
        check(self.page is not None)
        return copy.deepcopy(self.page)


def _verify(document):
    """Validate only captured invariants through the SDK. Never opens a network connection.

    A valid capture can still be incomplete/unhealthy (exit 1). Invalid structure/evidence is exit 2.
    No offline check establishes authenticity, unrecorded actions or physical device qualification.
    """
    check(isinstance(document, dict) and set(document) == ENVELOPE)
    check(type(document["schema_version"]) is int and document["schema_version"] == 1)
    check(document["artifact"] == ARTIFACT and document["qualification"] == QUALIFICATION)
    check(document["sdk_version"] == __version__)
    check(isinstance(document["limits"], dict))
    validate_limits(document["limits"])
    limits = document["limits"]
    check(len(encoded(document)) <= limits["max_bytes"])
    requested = document["requested"]
    check(isinstance(requested, dict) and set(requested) == {"source", "instance_id", "profile_id", "profile_version", "required_controls"})
    check(requested["source"] in ("simulation", "hardware"))
    check(all(isinstance(requested[key], str) and requested[key] for key in ("instance_id", "profile_id", "profile_version")))
    required = requested["required_controls"]
    check(required is None or isinstance(required, list) and required and all(isinstance(item, str) and item for item in required) and len(set(required)) == len(required))
    pages, end = document["pages"], document["end"]
    check(isinstance(pages, list) and len(pages) <= limits["max_polls"])
    check(finite(document["elapsed_s"]) and document["elapsed_s"] >= 0 and finite(document["clock_origin_s"]))
    check(isinstance(end, dict) and set(end) == {"trigger", "reason", "exit_code", "event_count", "poll_count", "unknown_controls", "pending_events"})
    check(end["trigger"] in ("setup", "error", "duration_limit", "poll_limit", "event_limit"))
    check(isinstance(end["reason"], str) and re.fullmatch(r"[a-z][a-z0-9_]{0,63}", end["reason"]) is not None)
    check(type(end["exit_code"]) is int and end["exit_code"] in (0, 1))
    check(type(end["pending_events"]) is bool)
    check(type(end["event_count"]) is int and 0 <= end["event_count"] <= limits["max_events"])
    check(type(end["poll_count"]) is int and end["poll_count"] == len(pages))
    checked, unavailable = ["bounded_capture_structure"], []
    client = _ReplayClient("http://127.0.0.1:1024/mcp", "offline-placeholder", requested["instance_id"], accepted_sources=(requested["source"],))
    client.document, client.page = document, None
    if document["discovery"] is not None:
        reject_extra_fields("surface_control_discover", document["discovery"])
    if document["snapshot"] is not None:
        reject_extra_fields("surface_control_snapshot", document["snapshot"])
    now = [document["clock_origin_s"]]
    tracker = None
    if document["discovery"] is not None:
        client.discover(profiles=(requested["profile_id"],), profile_versions=(requested["profile_version"],))
        checked.append("discovery_identity_profile_source")
        if required:
            for ident in required:
                client.control(ident)
    else:
        check(document["snapshot"] is None and not pages)
        unavailable.append("discovery_not_captured")
    snapshot_error = None
    if document["snapshot"] is not None:
        client.snapshot()
        validate_observations(client, document["snapshot"])
        checked.append("snapshot_values_and_unknowns")
        tracker = EventCursor(client, clock=lambda: now[0], max_age=limits["max_age_s"], limit=min(128, limits["max_events"]))
        try:
            tracker.bootstrap(document["snapshot"])
        except SurfaceError as error:
            snapshot_error = safe_code(error)
            check(not pages and end["reason"] == snapshot_error)
        if snapshot_error is None:
            checked.append("snapshot_link_and_cursor_baseline")
        else:
            unavailable.append("connected_cursor_baseline_unavailable")
    else:
        check(not pages)
        unavailable.append("snapshot_not_captured")
    last_received = document["clock_origin_s"]
    event_count = 0
    page_error = None
    for index, record in enumerate(pages):
        check(isinstance(record, dict) and set(record) == {"started_s", "received_s", "page", "result", "error_code"})
        check(finite(record["started_s"]) and finite(record["received_s"])
              and last_received <= record["started_s"] <= record["received_s"]
              and record["received_s"] - document["clock_origin_s"] <= document["elapsed_s"])
        check(record["result"] in ("ok", "error") and isinstance(record["page"], dict))
        check(tracker is not None and snapshot_error is None and page_error is None)
        tracker.limit = min(128, limits["max_events"] - event_count)
        check(tracker.limit > 0)
        ticks = iter((record["started_s"], record["received_s"]))
        tracker.clock = lambda: next(ticks)
        reject_extra_fields("surface_control_events", record["page"])
        client.page = record["page"]
        try:
            entries = tracker.poll()
            validate_page_values(client, record["page"])
            check(all(tracker.fresh(entry, now=record["received_s"]) for entry in entries), "input_stale")
        except SurfaceError as error:
            page_error = safe_code(error)
            check(record["result"] == "error" and record["error_code"] == page_error
                  and index == len(pages) - 1 and end["trigger"] == "error" and end["reason"] == page_error)
        else:
            check(record["result"] == "ok" and record["error_code"] is None)
            event_count += len(entries)
        last_received = record["received_s"]
    check(event_count == end["event_count"])
    good_pages = sum(record["result"] == "ok" for record in pages)
    if good_pages:
        checked.append("sdk_validated_page_prefix_identity_sequence_input_sequence_time_link_and_values")
    else:
        unavailable.append("successful_event_pages_not_captured")
    if page_error is not None:
        checked.append("sdk_reproduced_terminal_page_rejection")
    if not pages:
        unavailable.append("event_pages_not_captured")
    if event_count == 0:
        unavailable.append("new_events_not_observed")
    check(unknown_controls(document) == end["unknown_controls"])
    rebuilt = copy.deepcopy(document)
    if end["trigger"] == "error":
        check((end["reason"] in ERROR_CODES or re.fullmatch(r"http_[1-5][0-9]{2}", end["reason"])) and end["exit_code"] == 1)
        if page_error is None and snapshot_error is None:
            unavailable.append("terminal_error_without_response_evidence")
    else:
        check(tracker is not None and snapshot_error is None)
        if end["trigger"] == "poll_limit":
            check(len(pages) == limits["max_polls"])
        elif end["trigger"] == "event_limit":
            check(event_count == limits["max_events"])
        elif end["trigger"] == "duration_limit":
            check(document["elapsed_s"] >= limits["duration_s"])
        else:
            check(False)
    _end(rebuilt, end["trigger"], end["reason"] if end["trigger"] == "error" else None, document["elapsed_s"], event_count, len(pages))
    check(rebuilt["end"] == end)
    return {"schema_version": 1, "qualification": QUALIFICATION, "capture_integrity": "verified_recorded_invariants",
            "diagnostic_status": "bounded_complete" if end["exit_code"] == 0 else "incomplete_or_failed",
            "exit_code": end["exit_code"], "termination": end["reason"], "checked": checked,
            "unavailable": unavailable, "event_count": event_count, "page_count": len(pages),
            "validated_page_count": good_pages, "rejected_page_count": len(pages) - good_pages,
            "unknown_control_count": len(end["unknown_controls"]) if end["unknown_controls"] is not None else None,
            "required_control_scope": "explicit_subset" if required is not None else "all_profile_controls",
            "required_control_count": len(required) if required is not None else (len(client.profile["controls"]) if client.profile else None),
            "source": document["discovery"]["source"] if document["discovery"] is not None else None,
            "authenticity_verified": False, "physical_qualification": False}


def verify(document):
    try:
        return _verify(document)
    except (ValueError, TypeError, KeyError, AttributeError, IndexError, OverflowError, RecursionError, StopIteration):
        raise SurfaceError("invalid_capture") from None


def load_capture(raw):
    check(isinstance(raw, bytes) and len(raw) <= MAX_CAPTURE_BYTES)
    try:
        return decode(raw)
    except (ValueError, UnicodeError, RecursionError):
        raise SurfaceError("invalid_capture") from None
