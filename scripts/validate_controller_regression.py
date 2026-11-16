#!/usr/bin/env python3
"""Strict H-10 data/result validation. Valid result JSON may contain scenario failures.

The validator uses the standard library and the finite vocabulary of its checked-in
schemas. Unsupported schema keywords fail rather than being silently ignored.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import math
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
MAX_BYTES = 8 * 1024 * 1024


class Invalid(ValueError):
    pass


def need(condition, code):
    if not condition:
        raise Invalid(code)


def load(path):
    raw = Path(path).read_bytes()
    need(len(raw) <= MAX_BYTES, "document_too_large")
    def pairs(items):
        result = {}
        for key, value in items:
            need(key not in result, "duplicate_key")
            result[key] = value
        return result
    def constant(_):
        raise Invalid("nonfinite_number")
    return json.loads(raw, object_pairs_hook=pairs, parse_constant=constant)


def numeric(value):
    return type(value) in (int, float) and math.isfinite(value)


def same(left, right):
    if numeric(left) and numeric(right):
        return left == right
    if type(left) is not type(right):
        return False
    if type(left) is dict:
        return set(left) == set(right) and all(same(left[key], right[key]) for key in left)
    if type(left) is list:
        return len(left) == len(right) and all(same(a, b) for a, b in zip(left, right))
    return left == right


def validate(value, schema, *, root=None, path="$"):
    root = schema if root is None else root
    allowed = {"$schema", "$id", "$defs", "$ref", "type", "const", "enum", "pattern", "minLength", "maxLength",
               "properties", "required", "additionalProperties", "minItems", "maxItems", "uniqueItems", "items",
               "anyOf", "oneOf", "allOf", "not", "if", "then", "else", "minimum", "maximum"}
    need(isinstance(schema, dict) and set(schema) <= allowed, path + ":unsupported_schema")
    if "$ref" in schema:
        parts = schema["$ref"].split("/")
        need(len(parts) == 3 and parts[:2] == ["#", "$defs"] and parts[2] in root.get("$defs", {}), path + ":invalid_ref")
        validate(value, root["$defs"][parts[2]], root=root, path=path)
    types = {"object": lambda x: type(x) is dict, "array": lambda x: type(x) is list, "number": numeric,
             "integer": lambda x: numeric(x) and x == int(x), "boolean": lambda x: type(x) is bool,
             "string": lambda x: type(x) is str, "null": lambda x: x is None}
    if "type" in schema:
        wanted = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        need(all(t in types for t in wanted) and any(types[t](value) for t in wanted), path + ":type")
    if "const" in schema:
        need(same(value, schema["const"]), path + ":const")
    if "enum" in schema:
        need(any(same(value, item) for item in schema["enum"]), path + ":enum")
    if type(value) is dict:
        need(set(schema.get("required", [])) <= set(value), path + ":required")
        properties = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            need(set(value) <= set(properties), path + ":extra_field")
        for key in value.keys() & properties.keys():
            validate(value[key], properties[key], root=root, path=path + "." + key)
    if type(value) is list:
        need(schema.get("minItems", 0) <= len(value) <= schema.get("maxItems", MAX_BYTES), path + ":array_length")
        if schema.get("uniqueItems"):
            need(not any(same(a, b) for i, a in enumerate(value) for b in value[i + 1:]), path + ":duplicate_item")
        for index, item in enumerate(value if "items" in schema else []):
            validate(item, schema["items"], root=root, path=path + "[" + str(index) + "]")
    if type(value) is str:
        need(schema.get("minLength", 0) <= len(value) <= schema.get("maxLength", MAX_BYTES), path + ":string_length")
        if "pattern" in schema:
            need(re.search(schema["pattern"], value) is not None, path + ":pattern")
    if numeric(value):
        need(schema.get("minimum", -math.inf) <= value <= schema.get("maximum", math.inf), path + ":number_range")
    def matches(candidate):
        try:
            validate(value, candidate, root=root, path=path)
            return True
        except Invalid:
            return False
    for keyword in ("anyOf", "oneOf"):
        if keyword in schema:
            total = sum(matches(candidate) for candidate in schema[keyword])
            need(total >= 1 if keyword == "anyOf" else total == 1, path + ":" + keyword)
    for candidate in schema.get("allOf", []):
        validate(value, candidate, root=root, path=path)
    if "not" in schema:
        need(not matches(schema["not"]), path + ":not")
    if "if" in schema:
        branch = "then" if matches(schema["if"]) else "else"
        if branch in schema:
            validate(value, schema[branch], root=root, path=path)


def keyed(rows, key, path):
    ids = [row[key] for row in rows]
    need(len(ids) == len(set(ids)), path + ":duplicate_id")
    return {row[key]: row for row in rows}


def validate_fixture(path=ROOT / "fixtures/controller-regression-v1.json"):
    document = load(path)
    validate(document, load(ROOT / "docs/controller-regression.schema.json"))
    need([row["id"] for row in document["scenarios"]] == ["T" + str(i).zfill(2) for i in range(1, 31)], "scenario_inventory")
    for scenario in document["scenarios"]:
        name, setup = scenario["id"], scenario["setup"]
        instances = keyed(setup["instances"], "id", name + ".instances")
        controls = keyed(setup["controls"], "id", name + ".controls")
        parameters = keyed(setup["parameters"], "id", name + ".parameters")
        pages = keyed(setup["pages"], "id", name + ".pages")
        for p in parameters.values():
            need(p["minimum"] < p["maximum"] and p["minimum"] <= p["initial"] <= p["maximum"], name + ":parameter_range")
        for c in controls.values():
            need((c["input_endpoint"] is None) == (c["kind"] == "meter"), name + ":input_endpoint")
            need((c["touch_endpoint"] is not None) == (c["kind"] == "fader"), name + ":touch_endpoint")
        for page in pages.values():
            for element, binding in keyed(page["bindings"], "element_id", name + ".bindings").items():
                need(element in controls and controls[element]["kind"] != "meter", name + ":binding_element")
                need(binding["kind"] != "parameter" or binding["target_id"] in parameters, name + ":binding_parameter")
        for instance in instances.values():
            need(instance["hardware_context"] in setup["hardware_contexts"], name + ":initial_context")
        need(bool(scenario["steps"][-1]["expect"]), name + ":final_assertions_required")
        for index, action in enumerate(scenario["steps"]):
            here, args = name + ".step" + str(index), action["arguments"]
            need(action["instance_id"] in instances, here + ":instance")
            if "element_id" in args and action["operation"] != "receive_unconfigured":
                need(args["element_id"] in controls, here + ":control")
            if "parameter_id" in args:
                need(args["parameter_id"] in parameters, here + ":parameter")
            if "context" in args:
                need(args["context"] in setup["hardware_contexts"], here + ":context")
            if "page" in args:
                need(args["page"] in pages, here + ":page")
            if action["operation"].startswith("simulation_"):
                need(instances[action["instance_id"]]["source"] == "simulation", here + ":simulation_source")
            for event in args.get("events", []):
                need(event["element_id"] in controls and event["context"] in setup["hardware_contexts"], here + ":batch_reference")
            for assertion in action["expect"]:
                need(assertion.get("instance_id", action["instance_id"]) in instances, here + ":assertion_instance")
    return document


def observed(record, when, instance, metric):
    need(instance in record[when] and metric in record[when][instance], "missing_observation")
    return record[when][instance][metric]


def assertion_passes(assertion, action, record):
    instance = assertion.get("instance_id", action["instance_id"])
    metric, relation = assertion["metric"], assertion["relation"]
    after = observed(record, "after", instance, metric)
    if relation == "equals":
        return same(after, assertion["value"])
    if relation == "not_equals":
        return not same(after, assertion["value"])
    if relation == "at_least":
        return numeric(after) and numeric(assertion["value"]) and after >= assertion["value"]
    before = observed(record, "before", instance, metric)
    if relation == "unchanged":
        return same(after, before)
    if relation == "increased":
        return numeric(after) and numeric(before) and after > before
    if relation == "increased_by":
        return numeric(after) and numeric(before) and numeric(assertion["value"]) and after - before == assertion["value"]
    raise Invalid("unknown_relation")


def validate_report(path, fixture_path=ROOT / "fixtures/controller-regression-v1.json"):
    fixture = validate_fixture(fixture_path)
    report = load(path)
    validate(report, load(ROOT / "docs/controller-regression-results.schema.json"))
    need(report["fixture_sha256"] == hashlib.sha256(Path(fixture_path).read_bytes()).hexdigest(), "fixture_hash")
    need([row["id"] for row in report["results"]] == [row["id"] for row in fixture["scenarios"]], "result_inventory")
    features, counters, checked, step_na = set(report["features"]), {"pass": 0, "not_applicable": 0, "fail": 0}, 0, 0
    for scenario, result in zip(fixture["scenarios"], report["results"]):
        name = scenario["id"]
        counters[result["status"]] += 1
        missing = set(scenario["requires_features"]) - features
        if missing:
            need(result["status"] == "not_applicable" and result["reason"] and not result["steps"], name + ":missing_physical_feature")
            continue
        need(result["status"] != "not_applicable", name + ":unsupported_NA")
        need(result["reason"] is None if result["status"] == "pass" else bool(result["reason"]), name + ":reason")
        need(len(result["steps"]) == len(scenario["steps"]), name + ":incomplete_execution")
        instances, any_fail = {row["id"] for row in scenario["setup"]["instances"]}, False
        for index, (action, record) in enumerate(zip(scenario["steps"], result["steps"])):
            need(record["index"] == index and record["operation"] == action["operation"], name + ":step_inventory")
            need(set(record["before"]) <= instances and set(record["after"]) <= instances, name + ":observation_instance")
            if set(action["requires_features"]) - features:
                need(record["status"] == "not_applicable" and record["reason"] and not record["before"] and not record["after"] and not record["effects"], name + ":step_NA")
                step_na += 1
                continue
            need(record["status"] != "not_applicable", name + ":unsupported_step_NA")
            need(record["reason"] is None if record["status"] == "pass" else bool(record["reason"]), name + ":step_reason")
            for effect in record["effects"]:
                need(effect["instance_id"] in instances, name + ":effect_instance")
                need("value_projection" not in effect["kinds"] or "display" in effect["kinds"], name + ":projection_requires_display")
            for instance in set(record["before"]) | set(record["after"]):
                after = record["after"].get(instance, {})
                for when in ("before", "after"):
                    for metric in ("prepared_motor_plan_count", "revoked_motor_plan_count"):
                        values = record[when].get(instance, {})
                        if metric in values:
                            value = values[metric]
                            need(numeric(value) and value >= 0 and value == int(value), name + ":plan_counter_structure")
                counts = {"device_output_count": lambda effect: True,
                          "motor_output_count": lambda effect: "motor" in effect["kinds"],
                          "display_output_count": lambda effect: "display" in effect["kinds"],
                          "value_projection_output_count": lambda effect: effect["accepted"] and "value_projection" in effect["kinds"],
                          "layer_select_output_count": lambda effect: "context" in effect["kinds"],
                          "accepted_transport_count": lambda effect: effect["accepted"]}
                for metric, includes in counts.items():
                    if metric in after:
                        before = observed(record, "before", instance, metric)
                        amount = sum(effect["instance_id"] == instance and includes(effect) for effect in record["effects"])
                        need(numeric(before) and numeric(after[metric]) and after[metric] == before + amount, name + ":effect_counter")
            if record["status"] == "pass":
                for assertion in action["expect"]:
                    need(assertion_passes(assertion, action, record), name + ":false_pass_assertion")
                    checked += 1
            else:
                any_fail = True
        need((result["status"] == "fail") == any_fail, name + ":result_status")
    return {"validation": "pass", "conformance": "fail" if counters["fail"] else "pass", "scenario_counts": counters, "step_not_applicable": step_na, "assertions_checked": checked,
            "plan_evidence_verification": "supervisor_raw_required"}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, default=ROOT / "fixtures/controller-regression-v1.json")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args(argv)
    try:
        document = validate_fixture(args.fixture)
        output = validate_report(args.report, args.fixture) if args.report else {"validation": "pass", "scenarios": len(document["scenarios"]), "steps": sum(len(row["steps"]) for row in document["scenarios"])}
        print(json.dumps(output, sort_keys=True))
        return 0
    except (Invalid, OSError, ValueError, TypeError, KeyError, OverflowError, RecursionError) as error:
        print(json.dumps({"validation": "fail", "code": str(error) if isinstance(error, Invalid) else "invalid_document"}, sort_keys=True))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
