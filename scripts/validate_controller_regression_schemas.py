#!/usr/bin/env python3
"""Independent full Draft 2020-12 checks in the existing development/CI environment."""
import json
from pathlib import Path
from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parents[1]
for name in ("controller-regression.schema.json", "controller-regression-results.schema.json"):
    schema = json.loads((ROOT / "docs" / name).read_text())
    Draft202012Validator.check_schema(schema)
fixture = json.loads((ROOT / "fixtures/controller-regression-v1.json").read_text())
schema = json.loads((ROOT / "docs/controller-regression.schema.json").read_text())
Draft202012Validator(schema).validate(fixture)
print(json.dumps({"validation": "pass", "schemas": 2, "fixture_scenarios": len(fixture["scenarios"])}))
