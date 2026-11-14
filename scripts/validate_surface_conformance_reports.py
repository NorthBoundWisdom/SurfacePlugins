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
    assert report["counts"] == {"pass": 6, "fail": 0, "skip": 22}
print(json.dumps({"status": "pass", "hardware_read_only_reports": 1}))
