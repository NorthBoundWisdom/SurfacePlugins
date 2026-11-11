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

The remote repository and version are planned, not yet published. Local integration:
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
