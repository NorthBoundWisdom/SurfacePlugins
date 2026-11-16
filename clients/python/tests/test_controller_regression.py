"""H-10 validator unit data only; these tests do not execute either controller host."""
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("controller_regression_validator", ROOT / "scripts/validate_controller_regression.py")
validator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validator)


class ControllerRegressionValidatorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture_path = ROOT / "fixtures/controller-regression-v1.json"
        cls.fixture = validator.validate_fixture(cls.fixture_path)
        cls.features = validator.load(ROOT / "docs/controller-regression-results.schema.json")["properties"]["features"]["items"]["enum"]

    def validate_fixture_copy(self, value):
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch) / "fixture.json"
            path.write_text(json.dumps(value))
            return validator.validate_fixture(path)

    def report(self, features=None):
        """Synthetic envelopes for validator tests, never a host conformance result."""
        features = list(self.features if features is None else features)
        report = {"schema_version": 1, "artifact": "neutral-controller-regression-results",
                  "fixture_sha256": hashlib.sha256(self.fixture_path.read_bytes()).hexdigest(),
                  "host_revision": "0" * 40, "host_id": "validator.synthetic.unit.data",
                  "qualification": "test-only-fake-device", "features": features, "results": []}
        for scenario in self.fixture["scenarios"]:
            missing = set(scenario["requires_features"]) - set(features)
            row = {"id": scenario["id"], "status": "not_applicable" if missing else "fail",
                   "reason": "missing_physical_feature" if missing else "validator_unit_data_not_host_execution", "steps": []}
            if not missing:
                for index, action in enumerate(scenario["steps"]):
                    step_missing = set(action["requires_features"]) - set(features)
                    row["steps"].append({"index": index, "operation": action["operation"],
                                         "status": "not_applicable" if step_missing else "fail",
                                         "reason": "missing_physical_feature" if step_missing else "validator_unit_data_not_host_execution",
                                         "before": {}, "after": {}, "effects": []})
            report["results"].append(row)
        return report

    def validate_report_copy(self, value):
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch) / "validator-unit-data.json"
            path.write_text(json.dumps(value))
            return validator.validate_report(path)

    def projection_report(self):
        value = self.report()
        record = value["results"][13]["steps"][1]
        record.update(status="pass", reason=None,
                      before={"primary": {"value_projection_output_count": 0, "sent_value": 7}},
                      after={"primary": {"value_projection_output_count": 1, "sent_value": 7}},
                      effects=[{"instance_id": "primary", "kinds": ["display", "value_projection"],
                                "endpoint": "axis.display", "value": 7, "accepted": True}])
        return value

    def motor_plan_report(self):
        value = self.report()
        row = value["results"][6]
        row["steps"][0].update(status="pass", reason=None,
                               before={"primary": {"device_output_count": 0}},
                               after={"primary": {"device_output_count": 0, "prepared_motor_plan_count": 1}})
        row["steps"][2].update(status="pass", reason=None,
                               before={"primary": {"device_output_count": 0, "motor_output_count": 0}},
                               after={"primary": {"device_output_count": 0, "motor_output_count": 0,
                                                  "revoked_motor_plan_count": 1, "pending_motor_count": 1}})
        return value

    def test_inventory_is_exactly_thirty_scenarios_and_seventy_eight_steps(self):
        self.assertEqual([row["id"] for row in self.fixture["scenarios"]], ["T" + str(n).zfill(2) for n in range(1, 31)])
        self.assertEqual(sum(len(row["steps"]) for row in self.fixture["scenarios"]), 78)

    def test_only_T17_binds_the_second_physical_fader_to_the_shared_parameter(self):
        for scenario in self.fixture["scenarios"]:
            if any(control["id"] == "fader1" for control in scenario["setup"]["controls"]):
                self.assertTrue(any(control["id"] == "fader2" for control in scenario["setup"]["controls"]))
                for page in scenario["setup"]["pages"]:
                    bindings = {row["element_id"]: row["target_id"] for row in page["bindings"]}
                    if scenario["id"] == "T17":
                        self.assertEqual(bindings["fader1"], bindings["fader2"])
                    else:
                        self.assertNotIn("fader2", bindings)

    def test_T29_alone_distinguishes_old_and_new_page_parameter_values(self):
        for index, scenario in enumerate(self.fixture["scenarios"]):
            parameters = {row["id"]: row for row in scenario["setup"]["parameters"]}
            self.assertEqual(parameters["p1"]["initial"], 0)
            self.assertEqual(parameters["p2"]["initial"], 96 if index == 28 else 0)
        scenario = self.fixture["scenarios"][28]
        for page, expected in zip(scenario["setup"]["pages"], ("p1", "p2")):
            self.assertEqual(next(row["target_id"] for row in page["bindings"] if row["element_id"] == "axis"), expected)
        self.assertEqual(scenario["steps"][0]["expect"], [
            {"metric": "layer_select_output_count", "relation": "equals", "value": 0},
            {"metric": "hardware_context", "relation": "equals", "value": "context1"},
            {"metric": "display_plan_valid", "relation": "equals", "value": True}])

    def test_T29_incorrect_projection_cannot_claim_pass_but_remains_a_valid_failure(self):
        value = self.report()
        row = value["results"][28]
        record = row["steps"][0]
        record.update(status="pass", reason=None, before={"primary": {"layer_select_output_count": 0}},
                      after={"primary": {"layer_select_output_count": 0, "hardware_context": "context1", "display_plan_valid": False}})
        with self.assertRaisesRegex(validator.Invalid, "false_pass_assertion"):
            self.validate_report_copy(value)
        record.update(status="fail", reason="actual_product_projection_did_not_follow_new_binding")
        result = self.validate_report_copy(value)
        self.assertEqual(result["validation"], "pass")
        self.assertEqual(result["conformance"], "fail")

    def test_touch_plan_revocation_is_separate_from_IO_and_deferred_intent(self):
        result = self.validate_report_copy(self.motor_plan_report())
        self.assertEqual(result["assertions_checked"], 3)
        self.assertEqual(result["plan_evidence_verification"], "supervisor_raw_required")
        self.assertEqual(result["conformance"], "fail")  # Only synthetic validator data, not host execution.

    def test_plan_counts_cannot_be_negative_fractional_boolean_or_IO(self):
        for counter in (-1, 0.5, True):
            with self.subTest(counter=counter):
                value = self.motor_plan_report()
                value["results"][6]["steps"][0]["after"]["primary"]["prepared_motor_plan_count"] = counter
                with self.assertRaisesRegex(validator.Invalid, "plan_counter_structure"):
                    self.validate_report_copy(value)
        value = self.motor_plan_report()
        value["results"][6]["steps"][0]["after"]["primary"]["device_output_count"] = 1
        with self.assertRaisesRegex(validator.Invalid, "effect_counter"):
            self.validate_report_copy(value)

    def test_absent_prepared_plan_or_no_actual_revocation_cannot_claim_pass(self):
        for index, metric, amount in ((0, "prepared_motor_plan_count", 0), (2, "revoked_motor_plan_count", 0)):
            with self.subTest(metric=metric):
                value = self.motor_plan_report()
                value["results"][6]["steps"][index]["after"]["primary"][metric] = amount
                with self.assertRaisesRegex(validator.Invalid, "false_pass_assertion"):
                    self.validate_report_copy(value)

    def test_fixture_rejects_duplicate_ids_and_dangling_references(self):
        for mutation in (lambda d: d["scenarios"][1].update(id="T01"),
                         lambda d: d["scenarios"][0]["setup"]["parameters"][1].update(id="p1"),
                         lambda d: d["scenarios"][0]["steps"][0].update(instance_id="absent"),
                         lambda d: d["scenarios"][0]["steps"][0]["arguments"].update(element_id="absent")):
            with self.subTest(mutation=mutation):
                document = copy.deepcopy(self.fixture); mutation(document)
                with self.assertRaises(validator.Invalid):
                    self.validate_fixture_copy(document)

    def test_closed_shapes_reject_host_addresses_unknown_operations_and_fake_metrics(self):
        for mutation in (lambda d: d.update(extra=True),
                         lambda d: d["scenarios"][0]["steps"][0].update(operation="run_existing_test"),
                         lambda d: d["scenarios"][0]["steps"][0]["arguments"].update(midi_cc=1),
                         lambda d: d["scenarios"][0]["steps"][0]["expect"][0].update(metric="always_pass")):
            with self.subTest(mutation=mutation):
                document = copy.deepcopy(self.fixture); mutation(document)
                with self.assertRaises(validator.Invalid):
                    self.validate_fixture_copy(document)

    def test_simulation_operations_cannot_target_a_hardware_instance(self):
        document = copy.deepcopy(self.fixture)
        document["scenarios"][21]["steps"][2]["instance_id"] = "primary"
        with self.assertRaisesRegex(validator.Invalid, "simulation_source"):
            self.validate_fixture_copy(document)

    def test_final_assertions_cannot_be_silently_removed(self):
        document = copy.deepcopy(self.fixture)
        document["scenarios"][0]["steps"][-1]["expect"] = []
        with self.assertRaisesRegex(validator.Invalid, "final_assertions_required"):
            self.validate_fixture_copy(document)

    def test_loader_rejects_duplicate_keys_and_nonfinite_numbers(self):
        for raw in ('{"id":1,"id":2}', '{"value":NaN}', '{"value":Infinity}'):
            with self.subTest(raw=raw), tempfile.TemporaryDirectory() as scratch:
                path = Path(scratch) / "invalid.json"; path.write_text(raw)
                with self.assertRaises(validator.Invalid):
                    validator.load(path)

    def test_schema_numeric_equality_preserves_boolean_distinction(self):
        validator.validate(1.0, {"const": 1})
        validator.validate(1.0, {"type": "integer"})
        for schema in ({"const": 1}, {"type": "integer"}):
            with self.assertRaises(validator.Invalid):
                validator.validate(True, schema)

    def test_unknown_schema_keywords_are_rejected(self):
        with self.assertRaisesRegex(validator.Invalid, "unsupported_schema"):
            validator.validate({}, {"type": "object", "unsupported_keyword": True})

    def test_valid_envelope_does_not_turn_thirty_failures_into_conformance_success(self):
        result = self.validate_report_copy(self.report())
        self.assertEqual(result["validation"], "pass")
        self.assertEqual(result["conformance"], "fail")
        self.assertEqual(result["scenario_counts"], {"pass": 0, "not_applicable": 0, "fail": 30})

    def test_report_rejects_wrong_hash_missing_rows_or_missing_steps(self):
        for mutation in (lambda d: d.update(fixture_sha256="0" * 64),
                         lambda d: d["results"].pop(),
                         lambda d: d["results"][0]["steps"].pop()):
            with self.subTest(mutation=mutation):
                value = self.report(); mutation(value)
                with self.assertRaises(validator.Invalid):
                    self.validate_report_copy(value)

    def test_missing_gui_authority_and_journal_implementations_cannot_claim_NA(self):
        for index in (17, 24, 26, 29):
            with self.subTest(scenario=index + 1):
                value = self.report()
                value["results"][index].update(status="not_applicable", reason="missing_implementation", steps=[])
                with self.assertRaisesRegex(validator.Invalid, "unsupported_NA"):
                    self.validate_report_copy(value)

    def test_T25_still_executes_journal_when_motor_step_is_not_applicable(self):
        value = self.report(features=[f for f in self.features if f != "motor"])
        row = value["results"][24]
        row.update(status="pass", reason=None)
        row["steps"][0].update(status="pass", reason=None, after={"primary": {"journal_gap": True}})
        self.assertEqual(row["steps"][1]["status"], "not_applicable")
        result = self.validate_report_copy(value)
        self.assertEqual(result["step_not_applicable"], 1)
        self.assertEqual(result["scenario_counts"]["pass"], 1)
        self.assertEqual(result["conformance"], "fail")  # Other synthetic rows remain explicit failures.

    def test_T14_accepts_real_local_wire_unit_unchanged_with_value_reprojection(self):
        value = self.projection_report()
        result = self.validate_report_copy(value)
        self.assertEqual(result["assertions_checked"], 2)
        self.assertEqual(result["conformance"], "fail")  # This remains validator unit data only.
        self.assertEqual(self.fixture["scenarios"][13]["steps"][0]["arguments"]["value"], 64)
        self.assertEqual(self.fixture["scenarios"][13]["steps"][1]["arguments"]["value"], 64)

    def test_T14_style_only_or_rejected_projection_cannot_increment_accepted_value_counter(self):
        for kinds, accepted in ((["display"], True), (["display", "value_projection"], False)):
            with self.subTest(kinds=kinds, accepted=accepted):
                value = self.projection_report()
                value["results"][13]["steps"][1]["effects"][0].update(kinds=kinds, accepted=accepted)
                with self.assertRaisesRegex(validator.Invalid, "effect_counter"):
                    self.validate_report_copy(value)

    def test_value_projection_requires_display_kind(self):
        value = self.projection_report()
        value["results"][13]["steps"][1]["effects"][0]["kinds"] = ["value_projection"]
        with self.assertRaisesRegex(validator.Invalid, "projection_requires_display"):
            self.validate_report_copy(value)

    def test_false_pass_missing_observation_and_copied_semantic_sent_cache_are_rejected(self):
        for mutation in (lambda r: r["after"]["primary"].update(sent_value=64),
                         lambda r: r["after"]["primary"].pop("sent_value")):
            with self.subTest(mutation=mutation):
                value = self.projection_report(); mutation(value["results"][13]["steps"][1])
                with self.assertRaises(validator.Invalid):
                    self.validate_report_copy(value)

    def test_row_summary_cannot_claim_pass_when_a_step_failed(self):
        value = self.report()
        value["results"][0].update(status="pass", reason=None)
        with self.assertRaisesRegex(validator.Invalid, "result_status"):
            self.validate_report_copy(value)

    def test_cli_reports_validation_and_conformance_separately(self):
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch) / "validator-unit-data.json"
            path.write_text(json.dumps(self.report()))
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(validator.main(["--report", str(path)]), 0)
            result = json.loads(output.getvalue())
            self.assertEqual(result["validation"], "pass")
            self.assertEqual(result["conformance"], "fail")


if __name__ == "__main__":
    unittest.main()
