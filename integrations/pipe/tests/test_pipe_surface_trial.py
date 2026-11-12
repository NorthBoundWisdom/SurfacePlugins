"""The optional consumer must reserve its no-retry directory before any mutation."""

import contextlib
import importlib.util
import io
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


class PipeExampleTests(unittest.TestCase):
    def test_existing_output_causes_zero_provider_or_platform_mutations(self):
        source = Path(__file__).resolve().parents[1] / "pipe_surface_trial.py"
        spec = importlib.util.spec_from_file_location("surface_example_under_test", source)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        mutations = []

        class FakeClient:
            def __init__(self, *args, **kwargs):
                pass

            def discover(self, **_):
                return {"profile": {"controls": []}, "contract_version": "1.1"}

            def reset(self):
                mutations.append("reset")

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "already-reserved"
            output.mkdir()
            trial = SimpleNamespace(__file__=str(root / "controller_trial.py"), owned_mock=lambda _: {})
            with (
                patch.object(module, "delivery", return_value=(SimpleNamespace(Client=FakeClient), {})),
                patch.object(module, "digest", return_value="hash"),
                patch.object(module, "private_token", return_value="token"),
                patch.object(module.importlib, "import_module", return_value=trial),
                contextlib.redirect_stderr(io.StringIO()),
            ):
                result = module.main(
                    [
                        "--artifact",
                        str(root),
                        "--manifest-sha256",
                        "hash",
                        "--url",
                        "http://127.0.0.1:8787/mcp",
                        "--instance-id",
                        "A",
                        "--token-file",
                        str(root / "token"),
                        "--pipe-tools",
                        str(root),
                        "--state",
                        str(root / "state.json"),
                        "--output",
                        str(output),
                    ]
                )
            self.assertEqual(result, 1)
            self.assertEqual(mutations, [])
            self.assertEqual(list(output.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
