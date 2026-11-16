# Synthetic status panel example

`surface_panel_demo` uses only a display credential and the existing discover, snapshot and
feedback tools. It sends no input, renew or reset request. It is separate from the runtime SDK
and has only Python standard-library dependencies. It works from an SDK zip containing this
example package and its JSON resources; no Swift runtime, Pipe service or real device is needed.

The data is **synthetic**, recorded from the existing `RobotSimulator` reference six-joint
model and `ChassisSimulator` reference Ackermann model. Joint angles, speed and steering are
their simulated **actuals**, not targets. `PanelReferenceTraceTests.swift` generates the checked-in
`surface_panel_demo/reference_actual.json` and compares it byte for byte in the normal Swift test
suite. Its display recording rounds to six decimal places only after reading actuals. The 4.4-second
recording starts and ends with zero joint angles, zero speed and zero steering; the replay loops
between those resting endpoints. Phase is a synthetic scene marker, never a real workflow state.
Replaying a frame publishes it with a new local monotonic timestamp; the original simulator time
remains in the recording. This recording does not claim any hardware observation or qualification.

Use a dedicated anonymous descriptor containing **only the display token**, with its writing
end closed after writing. The example rejects regular files, an empty value and a full three-role
JSON record. Do not put a credential in argv, the environment, a configuration file or a report.
A trusted launcher can create `read_fd, write_fd = os.pipe()`, write its display token to `write_fd`,
close it, then launch the following with `pass_fds=(read_fd,)`. `DISPLAY_FD` below means the public
descriptor number, not the token. `PYTHONPATH` points to the SDK zip or its extracted Python root.

```sh
python3 -B -m surface_panel_demo --url http://127.0.0.1:PORT/mcp \
  --instance-id INSTANCE --token-fd DISPLAY_FD --mapping bcr \
  --source simulation --duration 15 --hz 1
```

For Compact use `--mapping compact`. Both bundled mapping files have separate, exact
source/profile/version pins; a caller-owned JSON mapping path is also accepted. No mapping has
MIDI addresses. Each numeric row specifies a source field and range, an output range and a rest
value; indicator rows specify an equality condition or freshness. Output uses the discovered
feedback range and step. The entire mapping and each complete frame are validated before any
part of that frame is written. The target tables in the host delivery explain qualification and
the current implementation's display styles; the example does not infer a device preset.

| Mapping | Fields and targets |
|---|---|
| BCR | Six joints → `pushEncoder.1.1..6`, speed → `.1.7`, steering → `.1.8`, phase → the always-visible lower `encoder.1.1`, freshness → `button.1.1` (indicator on/off). All top rings belong to group 1; select that group locally in the attended setup, never through this example. |
| Compact | Six joints, speed and steering → `a.encoder.1..8`; phase markers → `a.button.1..7`, freshness → `a.button.8`. Simulation values use 0..127; hardware uses only steady positions 1..13, with 0 for cleanup. No fader target is present. |

Only changed values are sent. The default 1 Hz is deliberately modest; choose 5–10 Hz only with
the explicit display budget and recommendations documented by that host's H-2 measurements.
One numeric update can encode multiple device messages; request rate is not USB MIDI capacity.
Two clients sharing a target remain subject to the host's last-write behavior and writer journal;
the example does not reserve targets or arbitrate with another panel. Use disjoint mappings.

Hardware is opt-in through `--source hardware`, and still requires the host's write policy and
display permission. **The default BCR hardware profile has no qualified button feedback, and
its ring value 0 is not dark in the existing one-dot/twelve-dot modes.** Therefore this mapping
refuses that profile before any write. It requires the already-existing explicit candidate profile
with `button.1.1` indicator feedback, plus the candidate's separate readiness prerequisites;
the candidate is not made default or awarded attended qualification. A fake candidate can be
used for software rehearsal. A numeric ring's rest position is never called an extinguished
freshness indicator. For Compact, an already established trusted observation of layer A is also
required; the example cannot select a layer or create that observation. Unknown/mismatched layer
evidence fails normally. Establishing it belongs to an explicit local attended step or the test
fixture. This round runs only simulation and fake-device paths, never physical hardware.

Normal duration expiry, SIGINT, SIGTERM and data-source staleness restore every attempted target
to its mapped rest value and extinguish freshness first. An attempted write is included because a
lost response may already have changed the display. Cleanup is an intentional rest write, not
a retry of the previous update. Targets whose last acknowledged value is already rest need no
redundant write. It retains the original instance/epoch/mapping pin and never
rediscovers/reconnects. If permissions, connection or epoch have changed, cleanup can be refused;
`cleanup_failed > 0` and exit 1 report that rest was not proved. No client can guarantee physical
cleanup after USB removal or process termination with SIGKILL.

Use `--source-stops-after 2 --max-age 1 --hz 5 --duration 10` to stop publication and observe
freshness go dark when the last publication is more than one second old. Source publication
timestamps, not the continued availability of the last value, control freshness. The final JSON
reports reason, frames, accepted/ignored writes and cleanup counts. It contains no credentials or
untrusted remote error text. `complete` and a clean `interrupted` exit 0; stale data, a rejected or
unknown update, and failed cleanup exit 1; invalid CLI/configuration exits 2.

Maintainers can regenerate the recording explicitly:

```sh
SURFACE_PANEL_TRACE_OUTPUT="$PWD/clients/python/surface_panel_demo/reference_actual.json" \
  swift test --build-path build/swiftpm --filter PanelReferenceTraceTests
```

Regeneration is a development action, not a demo runtime dependency. Existing simulation discovery,
published tool schemas, frozen fixtures and Provider 1.0 remain unchanged.
