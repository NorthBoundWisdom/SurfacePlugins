"""Hardware checker never sends input, renewal or reset; display requires explicit permission."""
import json
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from surface_control import Client
from surface_control_testing import TestOnlyHardwareHost
from surface_conformance import run_fixture

ROOT = Path(__file__).resolve().parents[3]


class HardwareConformanceTests(unittest.TestCase):
    def test_read_only_and_explicit_display(self):
        fixture = (ROOT / "fixtures/surface-control-hardware-v1.4.json").read_bytes()
        roles = {"schema_version": 1, "roles": {"input_a": "axis", "relative_input": "delta", "touch_input": "touch", "feedback_state": "button"}}
        for display in (False, True):
            with TestOnlyHardwareHost("test-only-token") as host:
                client = Client(host.url, "test-only-token", host.instance_id, accepted_sources=("hardware",))
                report = run_fixture(client, fixture, roles, allow_hardware_feedback=display)
                self.assertEqual(report["source"], "hardware")
                self.assertEqual(report["counts"]["fail"], 0)
                self.assertEqual(report["counts"]["pass"], 7 if display else 6)
                self.assertFalse({"surface_control_input", "surface_control_renew", "surface_control_reset"}.intersection(host.requests))
                self.assertEqual("surface_control_feedback" in host.requests, display)
                self.assertTrue(all(row["status"] == "skip" for row in report["steps"] if row["scenario"] != "hardware_read_only"))


if __name__ == "__main__":
    unittest.main()
