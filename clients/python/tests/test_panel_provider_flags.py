"""Optional caller-specified provider header pin; no host-specific defaults."""
import contextlib
import io
import os
import unittest
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from unittest.mock import patch
from surface_panel_demo.__main__ import main


class PanelProviderFlagTests(unittest.TestCase):
    def test_cli_forwards_explicit_provider_pin_for_both_protocols(self):
        for protocol in ("2025-11-25", "2026-07-28"):
            read, write = os.pipe(); os.write(write, b"test-display-only"); os.close(write)
            with patch("surface_panel_demo.__main__.DisplayClient") as client, patch("surface_panel_demo.__main__.run", return_value={"exit_code": 0}), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                code = main(["--url", "http://127.0.0.1:8787/mcp", "--instance-id", "test", "--mapping", "bcr", "--token-fd", str(read),
                             "--provider-id", "caller-pinned-provider", "--provider-header", "X-Caller-Provider", "--protocol", protocol])
                try:
                    self.assertEqual(code, 0)
                    self.assertEqual(client.call_args.kwargs["provider_id"], "caller-pinned-provider")
                    self.assertEqual(client.call_args.kwargs["provider_header"], "X-Caller-Provider")
                    self.assertEqual(client.call_args.kwargs["protocol"], protocol)
                finally:
                    try: os.close(read)
                    except OSError: pass
