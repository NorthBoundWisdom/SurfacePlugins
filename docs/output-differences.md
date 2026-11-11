# Output consolidation decisions

| Concern | Existing full gate | Existing scalar gate | Shared decision |
| --- | --- | --- | --- |
| Re-arm | Observe disabled then enabled after startup/reconnect/failure | Off then on, heartbeat seeded at enabling | Require off/on and independently received heartbeat |
| Actual | Fresh per-parameter finite actual required; seed output from actual | No actual feedback; initial clamp(0) | Require fresh actual; no invented initial observation |
| Timeout | Default .3 s, maximum .45 s; equality expired | Default 1 s; equality accepted | .3 s default and .45 cap; equality expired |
| Limits | Soft bounds, per-cycle delta, velocity, float-wire quantization | Bounds and velocity only | Full conservative gate |
| OSC | ASCII, packet/nesting bounds, bundles and typed args | UTF-8 float encoding; address <=512 bytes | Full codec plus 512-byte address bound |
| Clock | Date injection; negative interval faults | Monotonic Double; nonfinite trips | Monotonic Double, nonfinite/regression fail closed |
| Transport | Host owns sockets, credentials, source trust | Host owns sockets | Same; output request never becomes actual |

Scalar hosts intentionally gain fresh-actual, independent heartbeat, shorter timeout, cycle
caps, strict ASCII, and fail-closed rearm requirements. Full-gate hosts retain behavior with
Double timestamps, stable reason keys, and an explicit OSC address prefix supplied by adapter.
JSONParameterLink retains session/epoch/sequence freshness with caller-supplied session ID.
ExampleParameterSets is opt-in data, including protected arm.enabled; layouts and legacy
migration protection remain host responsibilities. No device control bindings are included.

A late or equal-timeout heartbeat resets arming even if it arrives before evaluation. Fresh
actual and heartbeat may be stored, but cannot erase the outage: evaluate remains waitingRearm
until the host observes disabled then enabled. This intentionally strengthens the old full gate.
