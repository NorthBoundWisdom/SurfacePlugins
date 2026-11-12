"""Pipe trial integration: import surface, profile assumptions, and no-retry reservation."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
import zipfile
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / "pipe_surface_trial.py"

# Same shape as the current Pipe checkout: tools/controller_trial.py is a thin entry point and the
# implementation is pipe_bcr_provider.controller.{trial,bridge}; trial imports names from bridge.
BRIDGE = '''
import json
COMMANDS = ("arm", "start", "pause", "cancel")
LOG = []
class JsonHTTP:
    pass
class ActionGate:
    def __init__(self):
        self.armed = False
        self.last = {name: 0 for name in COMMANDS}
    def sample(self, values):
        previous, self.last = self.last, dict(values)
        if not any(values.values()):
            self.armed = False
            return None
        if not self.armed:
            self.armed = bool(values["arm"]) and not any(values[n] for n in COMMANDS[1:])
            return None
        rising = [n for n in COMMANDS[1:] if values[n] and not previous[n]]
        if not rising:
            return None
        self.armed = False
        return rising[0]
class Journal:
    def __init__(self, path):
        LOG.append(("journal", path.name))
    def close(self):
        LOG.append(("journal-closed",))
def dispatch(cfg, flash, journal, action, sampled_snapshot, started, clock=None, before_submit=None):
    before_submit()
    flash.apply(action)
    LOG.append(("dispatch", action))
def feedback_values(cfg, snapshot, now):
    return {cfg["feedback"]["state"]: 64, cfg["feedback"]["progress"]: 127, cfg["feedback"]["link"]: 96}
'''
TRIAL = '''
import json
from .bridge import ActionGate, Journal, JsonHTTP, dispatch, feedback_values, LOG
STATUS = {"start": "running", "pause": "paused", "cancel": "canceled"}
class Flash:
    def __init__(self):
        self.status, self.head = "pending", 1
    def apply(self, action):
        self.status, self.head = STATUS[action], self.head + 1
    def snapshot(self):
        return {"execution": {"id": 7, "status": self.status, "version": self.head}, "head_event_id": self.head,
                "steps": [{"status": "ready", "start_gate": "released"}]}
def save(path, value):
    path.write_text(json.dumps(value))
def owned_mock(path):
    return {"unit": "A", "deployment_id": "d", "runtime_image_digest": "sha256:x"}
def prepare(http, state, output, mcp_url):
    output.mkdir(parents=True)
    LOG.append(("prepare", type(http).__name__))
    cfg = {"feedback": {"state": "f.state", "progress": "f.progress", "link": "f.link"}}
    return cfg, Flash(), None
def validate_trial(snapshot, cfg):
    return snapshot
def main(argv=None):
    return 0
'''
THIN = "from pipe_bcr_provider.controller.trial import main\n"


def control(ident, target, *, button=False, hold=False, feedback=None, maximum=127):
    row = {"id": ident, "mapping": {"kind": "parameter", "id": target}}
    if button:
        row.update(input_kind="button", encoding="boolean", feedback_kinds=["indicator"] if feedback is None else feedback)
        if hold:
            row["hold"] = {"rest_value": False, "max_hold_s": 5}
    else:
        row.update(input_kind="absolute", encoding="scalar", range={"minimum": 0, "maximum": maximum, "step": 1},
                   feedback_range={"minimum": 0, "maximum": maximum, "step": 1},
                   feedback_kinds=["value"] if feedback is None else feedback)
    return row


def host_profile(**overrides):
    """Shape of both hosts' 1.1 trial profiles: scalar commands/progress, indicator-only buttons."""
    rows = {name: control("enc." + name, "simulation." + name) for name in ("arm", "start", "pause", "cancel", "progress")}
    rows["state"] = control("btn.1", "simulation.state", button=True, hold=True)
    rows["link"] = control("btn.2", "simulation.link", button=True, hold=True)
    rows.update(overrides)
    return {"id": "fixture.profile", "version": "1.1", "controls": [row for row in rows.values() if row is not None],
            "capabilities": ["simulation", "controls.stable_ids", "input.absolute", "input.button", "input.hold",
                             "feedback.value", "feedback.indicator", "x.host.private"]}


class FakeSDK:
    """Records every call; binarizes like the SDK (range midpoint) without implementing it."""

    def __init__(self, profile):
        self.profile, self.calls, self.values, self.sequence = profile, [], {}, 0
        sdk = self

        class Client:
            def __init__(self, *args, **kwargs):
                sdk.calls.append(("client", kwargs))
                self.expected = {"epoch": "e"}

            def discover(self, **options):
                sdk.calls.append(("discover", options))
                return {"profile": sdk.profile, "contract_version": "1.1"}

            def reset(self):
                sdk.calls.append(("reset",))

            def input(self, ident, encoding, value):
                sdk.calls.append(("input", ident, encoding, value))
                sdk.sequence += 1
                row = next(r for r in sdk.profile["controls"] if r["id"] == ident)
                sdk.values[row["mapping"]["id"].split(".")[1]] = int(value >= row["range"]["maximum"] / 2)
                return {"sequence": str(sdk.sequence)}

            def feedback(self, ident, kind, value):
                sdk.calls.append(("feedback", ident, kind, value))
                sdk.sequence += 1
                return {"sequence": str(sdk.sequence)}

        class CommandCursor:
            def __init__(self, client, mapping, **options):
                self.seen, self.sequence = None, 0

            def current(self):
                return {name: sdk.values.get(name, 0) for name in ("arm", "start", "pause", "cancel")}

            def bootstrap(self):
                self.seen, self.sequence = self.current(), sdk.sequence
                return dict(self.seen)

            def poll(self):
                now, self.sequence = self.current(), sdk.sequence
                if now == self.seen:
                    return []
                self.seen = now
                return [{"values": dict(now), "expected": {"epoch": "e"}, "sequence": str(sdk.sequence),
                         "received_monotonic": 0.0}]

            def verify(self, sample):
                sdk.calls.append(("verify", sample["sequence"]))

        self.Client, self.CommandCursor = Client, CommandCursor


class PipeTrialTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("surface_example_under_test", SOURCE)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.path = list(sys.path)
        self.addCleanup(self.cleanup)

    def cleanup(self):
        sys.path[:] = self.path
        for name in [n for n in sys.modules if n.split(".")[0] in ("pipe_bcr_provider", "controller_trial", "controller_bridge")]:
            del sys.modules[name]
        self.temporary.cleanup()

    def package(self):
        base = self.root / "drivers/bcr_provider"
        controller = base / "pipe_bcr_provider/controller"
        controller.mkdir(parents=True)
        (base / "pipe_bcr_provider/__init__.py").write_text("")
        (controller / "__init__.py").write_text("")
        (controller / "bridge.py").write_text(BRIDGE)
        (controller / "trial.py").write_text(TRIAL)
        tools = self.root / "tools"
        tools.mkdir()
        (tools / "controller_trial.py").write_text(THIN)
        (tools / "controller_bridge.py").write_text(THIN.replace("trial", "bridge"))
        return base, tools

    def run_main(self, sdk, extra, output=None):
        output = output or self.root / "out"
        stderr, stdout = io.StringIO(), io.StringIO()
        with (
            patch.object(self.module, "delivery", return_value=(sdk, {"source_commit": "c", "surface_plugins_revision": "r"})),
            patch.object(self.module, "private_token", return_value="token"),
            contextlib.redirect_stderr(stderr),
            contextlib.redirect_stdout(stdout),
        ):
            code = self.module.main(["--artifact", str(self.root), "--manifest-sha256", "hash",
                                     "--url", "http://127.0.0.1:8787/mcp", "--instance-id", "A",
                                     "--token-file", str(self.root / "token"), "--state", str(self.root / "state.json"),
                                     "--output", str(output), *extra])
        return code, output, (json.loads(stderr.getvalue()) if stderr.getvalue() else None)

    def test_package_layout_runs_whole_trial_against_host_1_1_profile(self):
        base, _ = self.package()
        sdk = FakeSDK(host_profile())
        code, output, error = self.run_main(sdk, ["--pipe-package", str(base), "--profile", "fixture.profile",
                                                  "--provider-id", "p", "--provider-header", "X-Host-Id"])
        self.assertEqual((code, error), (0, None))
        report = json.loads((output / "surface-pipe-report.json").read_text())
        self.assertTrue(report["passed"])
        self.assertEqual(report["pipe_import"], "package")
        self.assertEqual(set(report["pipe_tool_hashes"]),
                         {"pipe_bcr_provider/controller/trial.py", "pipe_bcr_provider/controller/bridge.py"})
        self.assertEqual([row["action"] for row in report["observations"]], ["start", "pause", "cancel"])
        self.assertEqual(sdk.calls[0], ("client", {"protocol": "2025-11-25", "provider_id": "p", "provider_header": "X-Host-Id"}))
        self.assertEqual(sdk.calls[1], ("discover", {"profiles": ("fixture.profile",)}))
        self.assertEqual(sum(call[0] == "reset" for call in sdk.calls), 1)
        feedback = [call[1:] for call in sdk.calls if call[0] == "feedback"]
        # Buttons take indicator strings only; progress is a value on the declared range.
        self.assertEqual(feedback[:3], [("btn.1", "indicator", "on"), ("enc.progress", "value", 127), ("btn.2", "indicator", "on")])
        self.assertEqual([row[2] for row in feedback if row[0] == "btn.1"], ["on", "blink", "off"])
        self.assertTrue(all(call[3] in (0, 127) for call in sdk.calls if call[0] == "input"))
        bridge = sys.modules["pipe_bcr_provider.controller.bridge"]
        self.assertEqual(Path(bridge.__file__).resolve(), base / "pipe_bcr_provider/controller/bridge.py")
        self.assertEqual([entry for entry in bridge.LOG if entry[0] == "dispatch"],
                         [("dispatch", "start"), ("dispatch", "pause"), ("dispatch", "cancel")])
        self.assertIn(("prepare", "JsonHTTP"), bridge.LOG)

    def test_progress_is_rescaled_to_the_declared_feedback_range(self):
        base, _ = self.package()
        sdk = FakeSDK(host_profile(progress=control("enc.progress", "simulation.progress", maximum=16383)))
        code, _, error = self.run_main(sdk, ["--pipe-package", str(base)])
        self.assertEqual((code, error), (0, None))
        self.assertIn(("feedback", "enc.progress", "value", 16383), sdk.calls)
        self.assertEqual(self.module.scaled(0.5, {"minimum": 0, "maximum": 127, "step": 1}), 64)
        self.assertEqual(self.module.scaled(2, {"minimum": 0, "maximum": 1}), 1)

    def test_legacy_tools_on_a_thin_entry_point_checkout_fail_with_the_reason_and_no_mutation(self):
        _, tools = self.package()
        sdk = FakeSDK(host_profile())
        code, output, error = self.run_main(sdk, ["--pipe-tools", str(tools)])
        self.assertEqual(code, 1)
        self.assertIn("--pipe-package", error["reason"])
        self.assertEqual(sdk.calls, [])
        self.assertFalse(output.exists())

    def test_legacy_tools_with_the_functions_still_work(self):
        tools = self.root / "legacy"
        tools.mkdir()
        (tools / "controller_bridge.py").write_text(BRIDGE)
        (tools / "controller_trial.py").write_text(TRIAL.replace("from .bridge", "from controller_bridge"))
        sdk = FakeSDK(host_profile())
        code, output, error = self.run_main(sdk, ["--pipe-tools", str(tools)])
        self.assertEqual((code, error), (0, None))
        report = json.loads((output / "surface-pipe-report.json").read_text())
        self.assertEqual(report["pipe_import"], "legacy-tools")
        self.assertEqual(set(report["pipe_tool_hashes"]), {"controller_trial.py", "controller_bridge.py"})

    def test_import_source_arguments_are_exclusive_and_checked(self):
        base, tools = self.package()
        for extra in ([], ["--pipe-package", str(base), "--pipe-tools", str(tools)],
                      ["--pipe-package", str(self.root / "missing")],
                      ["--pipe-package", str(base), "--provider-id", "p"]):
            sdk = FakeSDK(host_profile())
            code, output, error = self.run_main(sdk, extra)
            self.assertEqual(code, 1)
            self.assertTrue(error["reason"])
            self.assertEqual(sdk.calls, [])
            self.assertFalse(output.exists())

    def test_profile_that_cannot_carry_the_roles_fails_before_reset(self):
        base, _ = self.package()
        for overrides in ({"link": None},
                          {"state": control("btn.1", "simulation.state", button=True, feedback=[])},
                          {"progress": control("enc.progress", "simulation.progress", feedback=["indicator"])}):
            self.cleanup_modules()
            sdk = FakeSDK(host_profile(**overrides))
            code, output, error = self.run_main(sdk, ["--pipe-package", str(base)])
            self.assertEqual(code, 1)
            self.assertTrue(error["reason"])
            self.assertFalse(any(call[0] in ("reset", "input", "feedback") for call in sdk.calls))
            self.assertFalse(output.exists())

    def cleanup_modules(self):
        sys.path[:] = self.path
        for name in [n for n in sys.modules if n.split(".")[0] == "pipe_bcr_provider"]:
            del sys.modules[name]

    def test_existing_output_causes_zero_provider_or_platform_mutations(self):
        base, _ = self.package()
        sdk = FakeSDK(host_profile())
        output = self.root / "already-reserved"
        output.mkdir()
        code, _, _ = self.run_main(sdk, ["--pipe-package", str(base)], output=output)
        self.assertEqual(code, 1)
        self.assertEqual([call for call in sdk.calls if call[0] in ("reset", "input", "feedback")], [])
        self.assertEqual(list(output.iterdir()), [])
        self.assertNotIn(("prepare", "JsonHTTP"), sys.modules["pipe_bcr_provider.controller.bridge"].LOG)


class DeliveryTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("surface_delivery_under_test", SOURCE)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.path = list(sys.path)
        self.saved_sdk = sys.modules.pop("surface_control", None)
        self.addCleanup(self.cleanup)

    def cleanup(self):
        sys.path[:] = self.path
        sys.modules.pop("surface_control", None)
        if self.saved_sdk is not None:
            sys.modules["surface_control"] = self.saved_sdk
        self.temporary.cleanup()

    def artifact(self, **fields):
        sdk_version = fields.get("surface_control_sdk", "1.1.0")
        sdk = self.root / ("surface-control-sdk-" + sdk_version + ".zip")
        with zipfile.ZipFile(sdk, "w") as archive:
            archive.writestr("surface_control/__init__.py", '__version__ = "' + sdk_version + '"')
        contract = self.root / "control-contract.json"
        contract.write_text("{}")
        manifest = {"schema_version": 1, "source": "simulation", "source_dirty": False,
                    "surface_control_contract": "1.1", "surface_control_sdk": "1.1.0",
                    "files_sha256": {sdk.name: self.module.digest(sdk), contract.name: self.module.digest(contract)},
                    **fields}
        (self.root / "manifest.json").write_text(json.dumps(manifest))
        return self.module.digest(self.root / "manifest.json")

    def test_common_manifest_accepts_both_sdk_generations_and_private_provider_fields(self):
        for contract, sdk_version in (("1.1", "1.1.0"), ("1.2", "1.2.0"), ("1.3", "1.3.0")):
            sys.modules.pop("surface_control", None)
            pin = self.artifact(surface_control_contract=contract, surface_control_sdk=sdk_version,
                                provider_version="1.0", provider_contract="private")
            sdk, manifest = self.module.delivery(self.root, pin)
            self.assertEqual(sdk.__version__, sdk_version)
            self.assertEqual(manifest["surface_control_contract"], contract)

    def test_common_manifest_fields_reject_before_sdk_import(self):
        for key, values in (("schema_version", (None, True, "1", 2)),
                            ("source", (None, "hardware", "mock")),
                            ("source_dirty", (None, True, 0, "false"))):
            for value in values:
                pin = self.artifact(**{key: value})
                with self.assertRaises(self.module.TrialError) as error:
                    self.module.delivery(self.root, pin)
                self.assertEqual(str(error.exception), "unsupported optional Surface delivery")
                self.assertNotIn("surface_control", sys.modules)
        pin = self.artifact()
        manifest = json.loads((self.root / "manifest.json").read_text())
        for key in ("schema_version", "source", "source_dirty"):
            bad = {k: v for k, v in manifest.items() if k != key}
            (self.root / "manifest.json").write_text(json.dumps(bad))
            with self.assertRaises(self.module.TrialError):
                self.module.delivery(self.root, self.module.digest(self.root / "manifest.json"))
            self.assertNotIn("surface_control", sys.modules)

    def test_manifest_pin_and_every_file_hash_are_checked_before_import(self):
        pin = self.artifact()
        with self.assertRaises(self.module.TrialError):
            self.module.delivery(self.root, "0" * 64)
        (self.root / "control-contract.json").write_text("tampered")
        with self.assertRaises(self.module.TrialError) as error:
            self.module.delivery(self.root, pin)
        self.assertEqual(str(error.exception), "artifact file hash/path mismatch")
        self.assertNotIn("surface_control", sys.modules)


if __name__ == "__main__":
    unittest.main()
