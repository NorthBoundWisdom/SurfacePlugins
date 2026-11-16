"""Preserve the exact pre-1.5 SDK version assertion against the complete original source."""
import hashlib
import importlib.util
from pathlib import Path
import unittest

SDK_PATH = Path(__file__).with_name("fixtures") / "sdk_1_4_0.py"
spec = importlib.util.spec_from_file_location("frozen_sdk_1_4_0", SDK_PATH)
legacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(legacy)
__version__ = legacy.__version__


class LegacyClientTests(unittest.TestCase):
    def test_version(self):
        self.assertEqual(__version__, "1.4.0")

    def test_original_source_is_complete_and_rejects_unknown_15_allowlist(self):
        self.assertEqual(hashlib.sha256(SDK_PATH.read_bytes()).hexdigest(), "13ef593f197a9036b6012e2796d213e1061605f211d2759c8bde3dd93d8dfc80")
        client = legacy.Client("http://127.0.0.1:8787/mcp", "test-only", "test")
        with self.assertRaises(legacy.SurfaceError) as error:
            client.discover(versions=("1.5",))
        self.assertEqual(error.exception.code, "unsupported_contract")
