#!/usr/bin/env python3
"""Keep production targets platform independent and dependency direction explicit."""
import json
import pathlib
import re
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
allowed = {
    "SurfacePluginContracts": set(),
    "SurfacePluginConformance": {"SurfacePluginContracts"},
    "AgentPlugin": {"SurfacePluginContracts"},
    "SimulationContracts": {"SurfacePluginContracts"},
    "RobotPlugin": {"SurfacePluginContracts", "SimulationContracts"},
    "ChassisPlugin": {"SurfacePluginContracts", "SimulationContracts"},
}
errors = []
for path in (root / "Sources").rglob("*.swift"):
    text = path.read_text()
    target = path.relative_to(root / "Sources").parts[0]
    imports = re.findall(r"^\s*(?:@\w+\s+)?import\s+(\w+)", text, re.M)
    for imported in imports:
        if imported not in allowed.get(target, set()) | {"Foundation"}:
            errors.append(f"{path.relative_to(root)}: forbidden import {imported}")
    for forbidden in [r"BCR", r"XTouch", r"Behringer", r"CoreMIDI", r"Date\s*\.\s*now", r"Task\s*\.\s*sleep", r"Timer", r"precondition", r"fatalError"]:
        if re.search(forbidden, text, re.I):
            errors.append(f"{path.relative_to(root)}: forbidden pattern {forbidden}")
package = json.loads(subprocess.check_output(["swift", "package", "dump-package"], cwd=root))
if package["dependencies"]:
    errors.append("external package dependency")
for target in package["targets"]:
    if target["type"] == "test":
        continue
    name = target["name"]
    dependencies = {next(iter(d.values()))[0] for d in target["dependencies"]}
    if name not in allowed or dependencies != allowed[name]:
        errors.append(f"{name}: invalid dependency direction {dependencies}")
if errors:
    raise SystemExit("\n".join(errors))
print("Boundary checks passed")
