#!/usr/bin/env python3
"""Independent opt-in1.5 schema/example checks; all default generator modes remain separate."""
import argparse
import copy
import json
from pathlib import Path
import subprocess
import sys
from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path[:0] = [str(ROOT / "clients/python/tests"), str(ROOT / "clients/python")]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-path", default="build/swiftpm")
    args = parser.parse_args()
    checked = 0
    for hardware in (False, True):
        stem = "surface-control-input-retention" + ("-hardware" if hardware else "")
        outputs = []
        for examples in (False, True):
            argv = ["swift", "run", "--build-path", args.build_path, "--skip-build", "surface-control-schema", "--input-retention"]
            if hardware: argv.append("--hardware")
            if examples: argv.append("--examples")
            output = subprocess.check_output(argv, cwd=ROOT)
            assert output == (ROOT / "docs" / (stem + ("-examples" if examples else "-tools") + ".json")).read_bytes()
            outputs.append(json.loads(output))
        catalogue, examples = outputs
        assert catalogue["contract_version"] == "1.5" and catalogue["schema_version"] == 1
        assert len(catalogue["tools"]) == 1
        tool = catalogue["tools"][0]
        assert tool["name"] == "surface_control_input_events" and tool["isMutation"] is False
        for key in ("inputSchema", "outputSchema"): Draft202012Validator.check_schema(tool[key])
        for sample in examples:
            assert sample["tool"] == tool["name"]
            Draft202012Validator(tool["inputSchema"]).validate(sample["arguments"])
            Draft202012Validator(tool["outputSchema"]).validate(sample["result"])
            assert ("link" in sample["result"]) == hardware
            checked += 1
        # New result does not permit feedback entries or omitted input sequence.
        sample = next(s["result"] for s in examples if s["result"]["events"])
        for mutation in (lambda x: x["events"][0].__setitem__("kind", "feedback"), lambda x: x["events"][0].pop("input_sequence")):
            bad = copy.deepcopy(sample); mutation(bad)
            assert list(Draft202012Validator(tool["outputSchema"]).iter_errors(bad))
    from surface_control_diagnostics import ReadOnlyClient, capture, verify
    from surface_control_testing import TestOnlyHardwareHost, example_profile
    schema = json.loads((ROOT / "docs/surface-control-diagnostic-capture-v1.5.schema.json").read_bytes())
    Draft202012Validator.check_schema(schema)
    profile = example_profile(); profile["id"] = "test.owned-virtual-rehearsal"
    profile["capabilities"].append("session.owned_virtual_rehearsal")
    with TestOnlyHardwareHost("retention-schema-test-only", profile=profile) as host:
        old_discover = host.discover
        def discovery15():
            value = old_discover(); value["contract_version"] = "1.5"; return value
        host.discover = discovery15
        client = ReadOnlyClient(host.url, "retention-schema-test-only", host.instance_id, accepted_sources=("hardware",))
        result = capture(client, profile["id"], profile["version"], limits={"max_polls": 1})
        Draft202012Validator(schema).validate(result)
        report = verify(result)
        assert report["rehearsal"] == {"owned_virtual_rehearsal": True, "physical_evidence": False}
        assert report["physical_qualification"] is False
        for mutation in (lambda x: x.pop("rehearsal"), lambda x: x["rehearsal"].__setitem__("physical_evidence", True)):
            bad = copy.deepcopy(result); mutation(bad)
            assert list(Draft202012Validator(schema).iter_errors(bad))
    print(json.dumps({"status": "pass", "opt_in_generated_files": 4, "typed_input_page_examples": checked,
                      "rehearsal_schema_positive_and_negative": True, "physical_qualification": False}))


if __name__ == "__main__":
    main()
