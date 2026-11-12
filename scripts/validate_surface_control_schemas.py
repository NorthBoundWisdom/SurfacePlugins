#!/usr/bin/env python3
"""Development check; run in an isolated Python environment with jsonschema installed."""
import argparse
import json
from pathlib import Path

from jsonschema import Draft202012Validator


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--examples", type=Path, required=True,
                        help="JSON produced by swift run surface-control-schema --examples")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    contract = json.loads((root / "docs/surface-control-tools.json").read_text())
    tools = {tool["name"]: tool for tool in contract["tools"]}
    for tool in tools.values():
        Draft202012Validator.check_schema(tool["inputSchema"])
        Draft202012Validator.check_schema(tool["outputSchema"])
    examples = json.loads(args.examples.read_text())
    for sample in examples:
        tool = tools[sample["tool"]]
        Draft202012Validator(tool["inputSchema"]).validate(sample["arguments"])
        Draft202012Validator(tool["outputSchema"]).validate(sample["result"])
    assert {sample["tool"] for sample in examples} == set(tools), "Missing tool examples"
    assert {sample["result"]["disposition"] for sample in examples
            if sample["tool"] == "surface_control_input"} == {"accepted", "ignored"}
    scenario_schema = json.loads((root / "docs/surface-control-scenario.schema.json").read_text())
    Draft202012Validator.check_schema(scenario_schema)
    assert any(sample["result"].get("hold_deadline") is not None for sample in examples
               if sample["tool"] == "surface_control_input"), "Missing hold example"
    assert any(event.get("reason") == "hold_expired" for sample in examples
               if sample["tool"] == "surface_control_events" for event in sample["result"]["events"]), "Missing expiry example"
    counts = {}
    for name in ("surface-control-software-v1.json", "surface-control-software-v1.1.json", "surface-control-software-v1.2.json", "surface-control-software-v1.3.json"):
        fixture = json.loads((root / "fixtures" / name).read_text())
        Draft202012Validator(scenario_schema).validate(fixture)
        for scenario in fixture["scenarios"]:
            times = [step["at_s"] for step in scenario["steps"]]
            assert times == sorted(times), f"Unordered scenario: {scenario['id']}"
            for step in scenario["steps"]:
                role = step.get("role")
                assert role is None or role in fixture["roles"], f"Unknown role: {role}"
                if "hold_s" in step or step["operation"] == "renew" or step.get("value") in ("rest", "active"):
                    assert fixture.get("contract_version") in ("1.1", "1.2", "1.3"), f"1.1 step in 1.0 fixture: {scenario['id']}"
                if "omit_sequence" in step or "expected_sequence" in step or step["operation"] == "refresh_sequence" or "hold_deadlines_at_s" in step["expect"]:
                    assert fixture.get("contract_version") in ("1.2", "1.3"), f"1.2 step in old fixture: {scenario['id']}"
                if "expected_input_sequence" in step or "latest_input_sequence" in step["expect"]:
                    assert fixture.get("contract_version") == "1.3", "1.3 step in old fixture"
                if "omit_sequence" in step:
                    assert step["operation"] == "feedback", "Only feedback may omit sequence"
                assert set(step["expect"].get("hold_deadlines_at_s", {})) <= set(fixture["roles"]), "Unknown hold role"
        counts[name] = {"scenario_count": len(fixture["scenarios"]),
                        "scenario_steps": sum(len(s["steps"]) for s in fixture["scenarios"])}
    operations = {step["operation"] for scenario in fixture["scenarios"] for step in scenario["steps"]}
    assert {"advance", "renew"} <= operations, "1.1 fixture lacks hold operations"
    print(json.dumps({"status": "pass", "schema_definitions": 2 * len(tools) + 1,
                      "typed_request_result_examples": len(examples), "fixtures": counts}))


if __name__ == "__main__":
    main()
