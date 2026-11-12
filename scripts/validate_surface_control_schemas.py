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
    fixture = json.loads((root / "fixtures/surface-control-software-v1.json").read_text())
    Draft202012Validator(scenario_schema).validate(fixture)
    for scenario in fixture["scenarios"]:
        times = [step["at_s"] for step in scenario["steps"]]
        assert times == sorted(times), f"Unordered scenario: {scenario['id']}"
    print(json.dumps({"status": "pass", "schema_definitions": 2 * len(tools) + 1,
                      "typed_request_result_examples": len(examples),
                      "scenario_count": len(fixture["scenarios"]),
                      "scenario_steps": sum(len(s["steps"]) for s in fixture["scenarios"])}))


if __name__ == "__main__":
    main()
