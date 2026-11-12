# SurfacePlugins

Foundation-only Swift 6 value-state plugins. Each product can be imported independently;
there is no umbrella product. Production plugins depend on SurfacePluginContracts and, for device simulations, the
Foundation-only SimulationContracts utility. Plugins never import one another.
SurfacePluginConformance is opt-in test support and has no testing-framework dependency.

Host builds commit a `configs/surface_plugins.lock.json` containing the repository URL and
one complete 40-character commit revision. A host-owned Python stdlib + Git manager materializes
that committed revision into `build/dependencies/SurfacePlugins`. Its Package.swift selects only
needed products from that managed path, after read-only ownership/revision/dirty verification:

```swift
.package(path: "build/dependencies/SurfacePlugins")
// In the chosen host target's dependencies:
.product(name: "SurfacePluginContracts", package: "SurfacePlugins")
```

The remote repository exists, but this implementation has not been pushed and `0.1.0` has not
been published. Before publishing, obtain committed objects from the local Git checkout:

```sh
export SURFACE_PLUGINS_SOURCE=../SurfacePlugins
python3 configs/surface_plugins_dependency.py ensure
swift test --build-path build/swiftpm
```

These manager commands run inside a host repository. After a deliberate lock update, use its
`update` command for an existing clean manager-owned cache. `SURFACE_PLUGINS_SOURCE` is only a
Git fetch source: uncommitted worktree edits are never compiled. Legacy `SURFACE_PLUGINS_PATH`
is accepted only as the same fetch-source override, not a direct dependency path. Different
SOURCE/PATH overrides are an error. Keep local source overrides in the shell or ignored host
build.local.json; never commit absolute paths. The hosts share manager implementation and lock
format while each builds independently from its own managed cache. No branch/tag resolution or
second host checkout is required. Publication remains a separate user decision.

Inside this package, product independence can be checked with
`swift build --target SurfacePluginContracts` (no plugin gets compiled).

The host owns parameter values and validates its write policy. ParameterDefinition validates
both constructors and JSON decoding; defaultValue is required and finite but may lie outside the range for old configurations.
The host must clamp/canonicalize it before storing or applying it.
`clamp` rejects nonfinite inputs; continuous grids use zero as anchor, include both endpoints,
and resolve equal distances toward the lower value. Toggle selects its maximum at midpoint.

Call `handle(.start, at: monotonicSeconds)` before writes. Inputs are synchronous and time is
caller-injected, finite and nondecreasing; a failed input must leave state unchanged. Stop
rejects subsequent writes until explicitly restarted. Snapshots are pure reads. InputOrigin
is the entry path, not identity or authorization. Namespace every declared surface ID as
`pluginID.localName`; action indices are one-based and optional only for unindexed actions.
No physical layout or presentation value is part of the contract.

Run `swift build --build-path build/swiftpm`, `swift test --build-path build/swiftpm`, and
`python3 configs/check_boundaries.py`. CI is configured for macOS and Linux; local checks do
not claim Linux or real-device qualification. The two layout examples exist only in tests.

AgentPlugin is an independent product (`.product(name: "AgentPlugin", package: "SurfacePlugins")`).
It provides AgentRunState, AgentSlot, AgentStateMachine, AgentApprovalPolicy, and AgentPlugin.
Initialize with `try AgentPlugin(slotCount: 8, approvalPolicy: .anyOrigin, at: 0)` and invoke
`agent.primary` with a one-based index. The default count is configuration, not a contract limit.
Use `.interfaceOnly` for instances that must refuse hardware/remote approvals. This plugin's
backend is mock; real backend I/O and identity checks remain host responsibilities.

The host drives `.advance` using a monotonic clock. Absolute deadlines preserve the original
0.45 / 0.55-second startup stages and 0.60 / 0.45-second post-approval stages. A large jump emits
every due stage in order and waits for explicit approval. Plugin events carry stable status
keys and numeric progress; snapshots carry only semantic indicators. `interrupt(_:at:)`
explicitly declines/interrupts one slot without accidentally approving or stopping other slots.
`stop` interrupts every active slot and cancels all schedules; `start` does not resume them.
AgentStateMachine exposes typed transition/updateProgress for host backend adapters, with
finite, nondecreasing per-slot time validation and structured errors.

RobotPlugin and SimulationContracts provide the reference joint-chain simulator and shared
lease/generation/proof values. Each simulator requires an explicit, host-owned unique
`instanceID`; use a fresh host UUID per independent instance/session if no stable identity
exists. The pure core derives deterministic generations within that namespace. Each acquire requires
a fresh opaque `controlToken` supplied by the trusted host (for example a new host UUID),
never by a remote request. The core rejects reuse of the most recent 256 tokens in the current generation; generation
changes clear that bounded guard. Global fresh opaque tokens remain the trusted host
responsibility; the core does not promise unlimited historical reuse detection.
The namespace is not a credential: transport authentication remains a host responsibility.
`RobotPlugin` implements the semantic surface while its typed `simulator` exposes motion APIs.
After a moving instance receives stop it remains started while braking, rejects new surface
writes, and reports stopped only after advance completes braking. Legacy error codes remain;
`docs/simulation-error-mapping.md` records key-to-message compatibility translations for hosts.

ParameterOutputPlugin provides the shared MotionSafetyGate, OSCCodec and JSONParameterLink;
ExampleParameterSets is an independent opt-in data product. Output differences and intentional
conservative changes are recorded in docs/output-differences.md. Time is monotonic Double,
JSON sessions are supplied by hosts, and OSC prefixes are explicit adapter configuration.
Heartbeat and actual-state delivery are trusted host APIs, never unauthenticated remote tools.

RemoteToolContracts and the independent AgentRemoteBinding / RobotRemoteBinding /
ChassisRemoteBinding / OutputRemoteBinding products provide one shared strict tool catalog
and implementation for both hosts. See docs/remote-tools.md for operation schemas, ownership,
trusted context, event gaps, and response-loss recovery. Registry owns the sole mutable value;
clock, hardware and remote entry paths use that same instance. Agent localOrigins policy keeps
hardware/UI approval available while rejecting remote approval.

JSONValue.intValue is the legacy roundedIntValue alias (Double nearest integer, ties away
from zero); it is retained without a deprecation warning for old provider behavior. New strict
command parsing uses exactIntValue, which preserves number(Int) and rejects fractional or
nonfinite Double values. The simulator event/catch-up limits and timed silent commit contract
are documented in docs/remote-tools.md.
