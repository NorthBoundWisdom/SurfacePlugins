# SurfacePlugins

Foundation-only Swift 6 value-state plugins. Each product can be imported independently;
there is no umbrella product. Production plugins depend only on SurfacePluginContracts.
SurfacePluginConformance is opt-in test support and has no testing-framework dependency.

```swift
// In the host Package.swift:
import Foundation
let plugins: Package.Dependency = ProcessInfo.processInfo.environment["SURFACE_PLUGINS_PATH"]
    .map { .package(path: $0) }
    ?? .package(url: "https://github.com/NorthBoundWisdom/SurfacePlugins.git", exact: "0.1.0")
// Add plugins to package.dependencies. A host target selects a single product:
// .product(name: "SurfacePluginContracts", package: "SurfacePlugins")
```

The remote repository exists, but this implementation has not been pushed and the exact
`0.1.0` version has not been published. A local override is still required for integration:
`SURFACE_PLUGINS_PATH=../SurfacePlugins swift test`. Keep overrides in the shell or an
ignored host build.local.json; never commit absolute paths. Product independence can be
checked with `swift build --target SurfacePluginContracts` (no plugin gets compiled).

The host owns parameter values and validates its write policy. ParameterDefinition validates
both constructors and JSON decoding; defaultValue is required and may be clamped by the host.
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
explicitly declines/interupts one slot without accidentally approving or stopping other slots.
`stop` interrupts every active slot and cancels all schedules; `start` does not resume them.
AgentStateMachine exposes typed transition/updateProgress for host backend adapters, with
finite, nondecreasing per-slot time validation and structured errors.

RobotPlugin and SimulationContracts provide the reference joint-chain simulator and shared
lease/generation/proof values. Each simulator requires an explicit, host-owned unique
`instanceID`; use a fresh host UUID per independent instance/session if no stable identity
exists. The pure core derives deterministic generations within that namespace. Each acquire requires
a fresh opaque `controlToken` supplied by the trusted host (for example a new host UUID),
never by a remote request. Tokens cannot be reused within the same instance.
The namespace is not a credential: transport authentication remains a host responsibility.
`RobotPlugin` implements the semantic surface while its typed `simulator` exposes motion APIs.
After a moving instance receives stop it remains started while braking, rejects new surface
writes, and reports stopped only after advance completes braking. Legacy error codes remain;
`docs/simulation-error-mapping.md` records key-to-message compatibility translations for hosts.
