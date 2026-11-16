#!/usr/bin/env python3
"""Development-only JSON Schema check of positive and deliberately failing live reports."""
import json
from pathlib import Path
import sys

from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path[:0] = [str(ROOT / "clients/python/tests"), str(ROOT / "clients/python")]
from test_surface_conformance import MemoryHost, fixture_bytes
from surface_conformance import run_fixture

schema = json.loads((ROOT / "docs/surface-control-conformance-report.schema.json").read_bytes())
Draft202012Validator.check_schema(schema)
validator = Draft202012Validator(schema)
host = MemoryHost()
report = run_fixture(host, (ROOT / "fixtures/surface-control-software-v1.3.json").read_bytes(), host.role_map)
validator.validate(report)
assert report["counts"] == {"pass": 35, "fail": 0, "skip": 62}
host = MemoryHost()
host.failure = ("input", "transport_unknown")
report = run_fixture(host, fixture_bytes([{"id": "unknown", "steps": [
    {"operation": "input", "role": "input_a", "value": "maximum", "expect": {}},
    {"operation": "snapshot", "expect": {}}
]}]), host.role_map)
validator.validate(report)
assert report["counts"] == {"pass": 0, "fail": 1, "skip": 1}
# The schema rejects a skipped row falsely claiming execution.
report["steps"][1]["executed"] = True
assert list(validator.iter_errors(report))
print(json.dumps({"status": "pass", "report_schema": 1, "positive_and_negative_reports": 2}))

from surface_control import Client
from surface_control_testing import TestOnlyHardwareHost
with TestOnlyHardwareHost("schema-test-only-token") as host:
    client = Client(host.url, "schema-test-only-token", host.instance_id, accepted_sources=("hardware",))
    report = run_fixture(client, (ROOT / "fixtures/surface-control-hardware-v1.4.json").read_bytes(), {"schema_version": 1, "roles": {"input_a": "axis"}})
    validator.validate(report)
    assert report["counts"] == {"pass": 6, "fail": 0, "skip": 33}
print(json.dumps({"status": "pass", "hardware_read_only_reports": 1}))

from surface_control_diagnostics import ReadOnlyClient, capture, verify
capture_schema14 = json.loads((ROOT / "docs/surface-control-diagnostic-capture.schema.json").read_bytes())
Draft202012Validator.check_schema(capture_schema14)
capture_schema = json.loads((ROOT / "docs/surface-control-diagnostic-capture-v1.5.schema.json").read_bytes())
Draft202012Validator.check_schema(capture_schema)
# Consumers register both SDK schema resources together; a duplicate URI must not
# replace the frozen SDK1.4 resource silently.
from referencing import Registry, Resource
capture_registry = Registry().with_resources([
    (capture_schema14["$id"], Resource.from_contents(capture_schema14)),
    (capture_schema["$id"], Resource.from_contents(capture_schema)),
])
assert capture_registry.contents(capture_schema14["$id"]) == capture_schema14, "SDK1.5 schema overwrote frozen SDK1.4 resource URI"
assert capture_registry.contents(capture_schema["$id"]) == capture_schema
with TestOnlyHardwareHost("diagnostic-schema-test-only") as host:
    host.connected = False
    client = ReadOnlyClient(host.url, "diagnostic-schema-test-only", host.instance_id, accepted_sources=("hardware",))
    captured = capture(client, host.profile["id"], host.profile["version"], limits={"max_polls": 1})
    Draft202012Validator(capture_schema).validate(captured)
    diagnostic = verify(captured)
    assert diagnostic["capture_integrity"] == "verified_recorded_invariants"
    assert diagnostic["diagnostic_status"] == "incomplete_or_failed" and diagnostic["exit_code"] == 1
    assert diagnostic["validated_page_count"] == 0 and diagnostic["physical_qualification"] is False
print(json.dumps({"status": "pass", "diagnostic_capture_schema": 1, "disconnected_capture_keeps_nonzero": True}))

# Execute the complete frozen SDK1.4 source, rather than relabeling a new capture with an
# old version. Load only the diagnostic adapter against it; production imports are restored.
import importlib.util
from test_legacy_sdk import legacy
current_sdk = sys.modules["surface_control"]
try:
    sys.modules["surface_control"] = legacy
    spec = importlib.util.spec_from_file_location("diagnostics_sdk14_check", ROOT / "clients/python/surface_control_diagnostics/__init__.py")
    legacy_diagnostics = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(legacy_diagnostics)
finally:
    sys.modules["surface_control"] = current_sdk
with TestOnlyHardwareHost("diagnostic-sdk14-schema-test-only") as host:
    host.connected = False
    client14 = legacy_diagnostics.ReadOnlyClient(host.url, "diagnostic-sdk14-schema-test-only", host.instance_id, accepted_sources=("hardware",))
    captured14 = legacy_diagnostics.capture(client14, host.profile["id"], host.profile["version"], limits={"max_polls": 1})
    assert captured14["sdk_version"] == "1.4.0"
    Draft202012Validator(capture_schema14).validate(captured14)
    diagnostic14 = verify(captured14)
    assert diagnostic14["capture_integrity"] == "verified_recorded_invariants"
    assert diagnostic14["diagnostic_status"] == "incomplete_or_failed" and diagnostic14["exit_code"] == 1
    assert diagnostic14["validated_page_count"] == 0 and diagnostic14["physical_qualification"] is False
print(json.dumps({"status": "pass", "frozen_sdk14_original_capture_schema": True, "current_sdk15_capture_schema": True}))

# Resolve by URI, not by passing an isolated in-memory schema that hides collisions.
validator14 = Draft202012Validator({"$ref": capture_schema14["$id"]}, registry=capture_registry)
validator15 = Draft202012Validator({"$ref": capture_schema["$id"]}, registry=capture_registry)
validator14.validate(captured14)
validator15.validate(captured)
assert list(validator14.iter_errors(captured)), "SDK1.5 capture must not validate as SDK1.4"
assert list(validator15.iter_errors(captured14)), "SDK1.4 capture must not validate as SDK1.5"
# Deliberately reproduce the old URI collision: later registration overwrites the old
# resource and rejects a genuine old-SDK capture. This negative control must remain red.
colliding_registry = Registry().with_resources([
    (capture_schema14["$id"], Resource.from_contents(capture_schema14)),
    (capture_schema14["$id"], Resource.from_contents(capture_schema)),
])
assert colliding_registry.contents(capture_schema14["$id"]) != capture_schema14
assert list(Draft202012Validator({"$ref": capture_schema14["$id"]}, registry=colliding_registry).iter_errors(captured14))
print(json.dumps({"status": "pass", "coexisting_diagnostic_schema_ids": [capture_schema14["$id"], capture_schema["$id"]],
                  "genuine_old_and_current_capture_uri_resolution": True, "deliberate_uri_collision_rejected_old_capture": True}))
