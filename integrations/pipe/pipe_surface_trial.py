#!/usr/bin/env python3
"""Explicit simulation inputs -> owned taskless Pipe trial -> authoritative display feedback.

Pipe-specific integration example. It is NOT part of the generic Surface Control SDK and is
never packaged into the SDK zip or a host's generic delivery. Source of truth:
SurfacePlugins `integrations/pipe/`.

Ownership (R4-25): this trial process is the owner of the simulation instance it targets. It
calls `surface_control_reset` once to start a fresh context, so its credential needs the
host's simulation input permission AND simulation-admin reset permission. Never point it at an
instance shared with another consumer; start a dedicated host instance for each trial.

It runs the SDK from a pinned host artifact. The Pipe controller modules are an explicit
read-only optional dependency: `--pipe-package` names the directory that contains the installable
`pipe_bcr_provider` package (Pipe `drivers/bcr_provider`). `--pipe-tools` is the legacy layout
(a `controller_trial.py` that itself defines the trial functions) and fails with an explicit
message on a Pipe checkout whose tools are thin entry points. No Worker/device task is created.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib
import json
import os
from pathlib import Path
import sys
import time

sys.dont_write_bytecode = True

SDK_VERSIONS = ("1.1.0", "1.2.0", "1.3.0")
SUPPORTED_CONTRACTS = ("1.0", "1.1", "1.2", "1.3")
# Consumer-side mapping: these parameter targets are Pipe trial roles, not shared contract names.
ROLE_TARGETS = {name: "simulation." + name for name in ("arm", "start", "pause", "cancel")}
FEEDBACK_TARGETS = ("simulation.state", "simulation.progress", "simulation.link")
# Feedback kind each role needs. Buttons declare only `indicator` (contract 1.1 host profiles).
FEEDBACK_KINDS = {"simulation.state": "indicator", "simulation.progress": "value", "simulation.link": "indicator"}


# Symbols this trial uses, by the Pipe module that defines them.
TRIAL_SYMBOLS = ("owned_mock", "save", "prepare", "validate_trial")
BRIDGE_SYMBOLS = ("JsonHTTP", "ActionGate", "Journal", "dispatch", "feedback_values")
PACKAGE = "pipe_bcr_provider"
PACKAGE_FILES = {"trial": "pipe_bcr_provider/controller/trial.py", "bridge": "pipe_bcr_provider/controller/bridge.py"}
LEGACY_FILES = ("controller_trial.py", "controller_bridge.py")


class TrialError(ValueError):
    """A failure with a fixed message written by this script (safe to print)."""


def require(condition, message):
    if not condition:
        raise TrialError(message)


def pipe_modules(package=None, tools=None):
    """Import the Pipe trial/bridge modules from exactly one explicit location.

    Returns (trial, bridge, hashes, layout). Module files must be the ones under the given
    directory; their SHA-256 values are recorded before import and rechecked after the trial.
    """
    require((package is None) != (tools is None), "give exactly one of --pipe-package or --pipe-tools")
    if package is not None:
        root = package.resolve()
        files = {name: root / relative for name, relative in PACKAGE_FILES.items()}
        require(all(path.is_file() for path in files.values()),
                "--pipe-package must contain pipe_bcr_provider/controller/trial.py and bridge.py")
        require(not any(name == PACKAGE or name.startswith(PACKAGE + ".") for name in sys.modules),
                "Pipe package import collision")
        hashes = {relative: digest(root / relative) for relative in PACKAGE_FILES.values()}
        sys.path.insert(0, str(root))
        try:
            trial = importlib.import_module(PACKAGE + ".controller.trial")
            bridge = importlib.import_module(PACKAGE + ".controller.bridge")
        except ImportError:
            raise TrialError("Pipe package could not be imported from --pipe-package") from None
        require(Path(trial.__file__).resolve() == files["trial"] and Path(bridge.__file__).resolve() == files["bridge"],
                "Pipe package path mismatch: modules were not loaded from --pipe-package")
        layout = "package"
    else:
        root = tools.resolve()
        require(all((root / name).is_file() for name in LEGACY_FILES),
                "--pipe-tools must contain controller_trial.py and controller_bridge.py")
        require("controller_trial" not in sys.modules and "controller_bridge" not in sys.modules,
                "Pipe tools import collision")
        hashes = {name: digest(root / name) for name in LEGACY_FILES}
        sys.path.insert(0, str(root))
        try:
            trial = importlib.import_module("controller_trial")
        except ImportError:
            raise TrialError(
                "legacy --pipe-tools could not be imported: this Pipe checkout uses the installable "
                "package; use --pipe-package <.../drivers/bcr_provider>"
            ) from None
        require(Path(trial.__file__).resolve() == root / "controller_trial.py", "Pipe tools path mismatch")
        bridge = trial  # The legacy single module re-exported the bridge symbols.
        require(all(hasattr(trial, name) for name in TRIAL_SYMBOLS + BRIDGE_SYMBOLS),
                "legacy --pipe-tools is a thin entry point without the trial functions: this Pipe "
                "checkout uses the installable package; use --pipe-package <.../drivers/bcr_provider>")
        layout = "legacy-tools"
    require(all(hasattr(trial, name) for name in TRIAL_SYMBOLS) and all(hasattr(bridge, name) for name in BRIDGE_SYMBOLS),
            "Pipe modules lack a function this trial needs; the Pipe consumer interface changed")
    return trial, bridge, {"root": root, "files": hashes}, layout


def profile_rows(discovery):
    """Resolve the consumer mapping against the discovered profile before any mutation."""
    by_mapping = {}
    for row in discovery["profile"]["controls"]:
        mapping = row.get("mapping") or {}
        key = mapping.get("id")
        if mapping.get("kind") == "parameter" and (key in ROLE_TARGETS.values() or key in FEEDBACK_TARGETS):
            require(key not in by_mapping, "mapping aliases are not supported")
            by_mapping[key] = row
    require(all(key in by_mapping for key in (*ROLE_TARGETS.values(), *FEEDBACK_TARGETS)),
            "profile does not map every trial role (simulation.arm/start/pause/cancel/state/progress/link)")
    for key, kind in FEEDBACK_KINDS.items():
        require(kind in by_mapping[key].get("feedback_kinds", []),
                "profile control for " + key + " does not declare " + kind + " feedback")
    span = by_mapping["simulation.progress"].get("feedback_range") or by_mapping["simulation.progress"].get("range")
    require(isinstance(span, dict) and span.get("minimum", 0) < span.get("maximum", 0),
            "profile progress control has no numeric feedback range")
    return by_mapping


def scaled(fraction, span):
    """Map 0..1 onto the declared feedback range, on its step grid, never outside the endpoints."""
    low, high, step = span["minimum"], span["maximum"], span.get("step")
    value = low + max(0.0, min(1.0, fraction)) * (high - low)
    if step:
        value = round(value / step) * step
    value = max(low, min(high, value))
    return int(value) if float(value).is_integer() else value


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def delivery(root, expected):
    manifest_path = root / "manifest.json"
    require(digest(manifest_path) == expected, "artifact manifest pin mismatch")
    manifest = json.loads(manifest_path.read_text())
    require(
        type(manifest.get("schema_version")) is int
        and manifest["schema_version"] == 1
        and manifest.get("source") == "simulation"
        and manifest.get("source_dirty") is False
        and manifest.get("surface_control_contract") in SUPPORTED_CONTRACTS
        and manifest.get("surface_control_sdk") in SDK_VERSIONS,
        "unsupported optional Surface delivery",
    )
    for name, wanted in manifest["files_sha256"].items():
        path = root / name
        require(
            not Path(name).is_absolute()
            and ".." not in Path(name).parts
            and path.is_file()
            and not path.is_symlink()
            and path.resolve().is_relative_to(root)
            and digest(path) == wanted,
            "artifact file hash/path mismatch",
        )
    sdk_version = manifest["surface_control_sdk"]
    sdk = root / ("surface-control-sdk-" + sdk_version + ".zip")
    require(sdk.name in manifest["files_sha256"], "Surface SDK is not in manifest")
    require("surface_control" not in sys.modules, "another Surface SDK is already loaded")
    sys.path.insert(0, str(sdk))
    module = importlib.import_module("surface_control")
    require(str(module.__file__).startswith(str(sdk) + "/"), "SDK import is not from pinned artifact")
    require(getattr(module, "__version__", None) == sdk_version, "SDK version mismatch")
    return module, manifest


def private_token(path):
    info = path.stat()
    require(
        path.is_file() and not path.is_symlink() and info.st_uid == os.geteuid() and not info.st_mode & 0o077,
        "token must be an owned private regular file",
    )
    return path.read_text().strip()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact", type=Path, required=True)
    parser.add_argument("--manifest-sha256", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--instance-id", required=True)
    parser.add_argument("--token-file", type=Path, required=True)
    parser.add_argument("--pipe-package", type=Path,
                        help="Directory containing the installable pipe_bcr_provider package (Pipe drivers/bcr_provider)")
    parser.add_argument("--pipe-tools", type=Path,
                        help="Legacy: tools directory whose controller_trial.py defines the trial functions")
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--protocol", choices=("2025-11-25", "2026-07-28"), default="2025-11-25")
    parser.add_argument("--profile", action="append", help="Allowed profile ID (repeatable); default accepts any")
    parser.add_argument("--provider-id", help="Expected host provider identity (requires --provider-header)")
    parser.add_argument("--provider-header", help="Host-specific provider identity header name")
    args = parser.parse_args(argv)
    try:
        root = args.artifact.resolve()
        sdk, manifest = delivery(root, args.manifest_sha256)
        require((args.provider_id is None) == (args.provider_header is None),
                "--provider-id and --provider-header must be given together")
        trial, bridge, pipe, layout = pipe_modules(args.pipe_package, args.pipe_tools)
        hashes = pipe["files"]
        state = trial.owned_mock(args.state.resolve())
        client = sdk.Client(
            args.url,
            private_token(args.token_file),
            args.instance_id,
            protocol=args.protocol,
            provider_id=args.provider_id,
            provider_header=args.provider_header,
        )
        profiles = tuple(args.profile) if args.profile else None
        discovery = client.discover(profiles=profiles)
        by_mapping = profile_rows(discovery)  # Fails before the output reservation or any reset.
        args.output.mkdir(parents=True, mode=0o700, exist_ok=False)
        trial.save(
            args.output / "phase-provider-reset-pending.json", {"phase": "provider-reset-pending", "retry": False}
        )
        client.reset()  # Explicit new simulation context; no restart/recovery of an old arm.
        trial.save(args.output / "phase-provider-reset-completed.json", {"phase": "provider-reset-completed"})
        mapping = dict(ROLE_TARGETS)
        cursor = sdk.CommandCursor(client, mapping, discover={"profiles": profiles})
        initial = cursor.bootstrap()
        require(not any(initial.values()), "new trial requires all-off controls")
        trial_name = "taskless-" + hashlib.sha256(str(args.output.resolve()).encode()).hexdigest()[:16]
        cfg, flash, _ = trial.prepare(bridge.JsonHTTP(), state, args.output / trial_name, args.url)
        gate = bridge.ActionGate()
        require(gate.sample(initial) is None, "initial snapshot cannot command")
        observations = []
        inputs = []
        journal = bridge.Journal(args.output / "platform-journal.jsonl")
        try:

            def send(name, on):
                row = by_mapping[mapping[name]]
                if row["encoding"] == "boolean":
                    raw = bool(on)
                else:
                    # Range endpoints are unambiguous on either side of the SDK's midpoint threshold.
                    raw = row["range"]["maximum"] if on else row["range"]["minimum"]
                event = client.input(row["id"], row["encoding"], raw)
                inputs.append(event)
                selected = []
                for sample in cursor.poll():
                    action = gate.sample(sample["values"])
                    if action:
                        selected.append((action, sample))
                return selected

            for action, target in (("start", "running"), ("pause", "paused"), ("cancel", "canceled")):
                for name in mapping:
                    require(not send(name, False), "all-off cannot dispatch")
                require(not send("arm", True), "arm-alone cannot dispatch")
                selected = send(action, True)
                require(len(selected) == 1 and selected[0][0] == action, "single action was not selected")
                sample = selected[0][1]
                before = trial.validate_trial(flash.snapshot(), cfg)
                # Existing consumer owns target/version checks and durable reserve-before-send.
                bridge.dispatch(
                    cfg,
                    flash,
                    journal,
                    action,
                    before,
                    sample["received_monotonic"],
                    before_submit=lambda: cursor.verify(sample),
                )
                after = trial.validate_trial(flash.snapshot(), cfg)
                require(
                    after["execution"]["status"] == target and after["head_event_id"] > before["head_event_id"],
                    "authoritative platform result mismatch",
                )
                values = bridge.feedback_values(cfg, after, time.monotonic())
                progress_row = by_mapping["simulation.progress"]
                # The Pipe bridge reports progress on 0..127; rescale to the control's declared range.
                progress = scaled(values[cfg["feedback"]["progress"]] / 127,
                                  progress_row.get("feedback_range") or progress_row["range"])
                feedback = []
                for role, value in (
                    ("state", "blink" if target == "paused" else ("off" if target == "canceled" else "on")),
                    ("progress", progress),
                    ("link", "on"),
                ):
                    row = by_mapping["simulation." + role]
                    feedback.append(client.feedback(row["id"], FEEDBACK_KINDS["simulation." + role], value))
                require(not cursor.poll(), "display feedback created a business intent")
                observations.append(
                    {
                        "action": action,
                        "input_sequence": sample["sequence"],
                        "input_expected": sample["expected"],
                        "before": {
                            "execution_version": before["execution"]["version"],
                            "head_event_id": before["head_event_id"],
                        },
                        "after": {
                            "execution_id": after["execution"]["id"],
                            "status": target,
                            "execution_version": after["execution"]["version"],
                            "head_event_id": after["head_event_id"],
                            "step_status": after["steps"][0]["status"],
                            "start_gate": after["steps"][0]["start_gate"],
                        },
                        "feedback": feedback,
                    }
                )
        finally:
            journal.close()
        # Verify the optional imported dependency stayed byte-identical during the trial.
        require(
            all(digest(pipe["root"] / name) == wanted for name, wanted in hashes.items()),
            "Pipe modules changed during trial",
        )
        report = {
            "scenario": "surface-pipe-taskless-v1",
            "passed": True,
            "scope": "simulation-inputs-real-taskless-platform",
            "physical_input_verified": False,
            "worker_or_device_execution_verified": False,
            "artifact_manifest_sha256": args.manifest_sha256,
            "artifact_source_commit": manifest["source_commit"],
            "shared_revision": manifest.get("surface_plugins_revision"),
            "protocol": args.protocol,
            "unit": state["unit"],
            "deployment_id": state["deployment_id"],
            "runtime_image_digest": state["runtime_image_digest"],
            "pipe_import": layout,
            "pipe_tool_hashes": hashes,
            "profile_id": discovery["profile"]["id"],
            "contract_version": discovery["contract_version"],
            "inputs": inputs,
            "observations": observations,
        }
        trial.save(args.output / "surface-pipe-report.json", report)
        print(
            json.dumps(
                {
                    "passed": True,
                    "scenario": report["scenario"],
                    "report": str(args.output / "surface-pipe-report.json"),
                }
            )
        )
        return 0
    except Exception as error:
        code = getattr(error, "code", type(error).__name__)
        # Never log exception strings returned by arbitrary transports or imported modules;
        # only this script's own fixed TrialError messages are printed.
        reason = str(error) if type(error) is TrialError else None
        print(
            json.dumps(
                {
                    "passed": False,
                    "code": code,
                    "reason": reason,
                    "retry": False,
                    "message": "Reconcile existing output before starting a new context",
                }
            ),
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
