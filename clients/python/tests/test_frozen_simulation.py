"""Pin E-before simulation bytes, independent of the current schema generator.

ControlV14Tests.testSimulationDiscoveryBytesMatchFrozen13Example compares the live
Swift session to this frozen example using the same sorted-key encoding. CI also
compares generated schema/example bytes to these files. These hashes prevent
changing both that implementation and its golden input together.
"""
import hashlib
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[3]
# Read from Git objects at the last E-before shared commit, not regenerated output:
# 236705c4805505aa8a42bfc880bca0e926d7a675.
FROZEN_SHA256 = {
    "fixtures/surface-control-software-v1.json":
        "e7d1fe278026778fd1c148f8d1fcfa334cbac6a3202ec01bf52594c205d80f18",
    "fixtures/surface-control-software-v1.1.json":
        "e94698d0ff44125648cf541498ee88219e590ff65a7829100a31fe6f31248aec",
    "fixtures/surface-control-software-v1.2.json":
        "0109293e0aceff6c57d0dee271511ad2a2fc1f3f87e552b34466f93c1c0dcf34",
    "fixtures/surface-control-software-v1.3.json":
        "fd153591d8f4815357068b36141e9dc418f2f67f787367e3f75e945283eabb85",
    "docs/surface-control-tools.json":
        "2bf891a9a358a7928bd063e59094f041e040447b7a833d5d267b359ee1c8292e",
    "docs/surface-control-examples.json":
        "0b8cb50fa2771dcea604665a1cff43310f763cac69cd1cfb760855873099206d",
}


class FrozenSimulationTests(unittest.TestCase):
    def test_four_fixtures_and_v13_schema_examples_keep_original_bytes(self):
        for relative, expected in FROZEN_SHA256.items():
            with self.subTest(path=relative):
                self.assertEqual(hashlib.sha256((ROOT / relative).read_bytes()).hexdigest(), expected)

    def test_v13_discovery_keeps_e_before_canonical_bytes(self):
        samples = json.loads((ROOT / "docs/surface-control-examples.json").read_bytes())
        self.assertEqual(samples[0]["tool"], "surface_control_discover")
        discovery = samples[0]["result"]
        self.assertEqual(discovery["contract_version"], "1.3")
        self.assertEqual(discovery["source"], "simulation")
        canonical = json.dumps(discovery, sort_keys=True, separators=(",", ":"),
                               ensure_ascii=False, allow_nan=False).encode("utf-8")
        self.assertEqual(len(canonical), 1095)
        self.assertEqual(hashlib.sha256(canonical).hexdigest(),
                         "10271322a0b0a58fab15f1a6f9c1d15e04e41aa26cc2bbb0135856f49284a728")


if __name__ == "__main__":
    unittest.main()
