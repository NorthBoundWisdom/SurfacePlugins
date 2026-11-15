# TEST DOUBLE ONLY — not a physical device

This separate test package cannot be used as acceptance or qualification evidence. It never
loads a device driver. Scripts are trusted test setup; no public tool injects hardware input.
It is delivered in a separate test-only ZIP or directory, never in the runtime SDK ZIP.
Extract both archives into separate directories and explicitly add the test-support path only
for a test process:

```sh
PYTHONPATH=/path/to/extracted-test-support:/path/to/extracted-sdk python3 -B -m surface_control_testing \
  --token-file /private/test-token --ready-file /tmp/test-double-ready.json \
  --script /tmp/test-script.json
```

The token file is private and is never copied into a delivery. Startup prints the test-only
warning. The ready document carries `artifact: surface-control-test-only-hardware-double`,
`qualification: test-only`, URL, instance ID, hardware source and contract 1.4; the source is a
protocol test declaration, not device provenance. This ready file must never select a live route.

A script is a JSON array of timed steps, for example:

```json
[
  {"at_s": 1, "operation": "input", "control_id": "axis", "value": 64},
  {"at_s": 2, "operation": "input", "control_id": "delta", "value": -1},
  {"at_s": 3, "operation": "input", "control_id": "button", "value": true},
  {"at_s": 4, "operation": "input", "control_id": "button", "value": false},
  {"at_s": 5, "operation": "input", "control_id": "touch", "value": true},
  {"at_s": 6, "operation": "disconnect"},
  {"at_s": 7, "operation": "reconnect"},
  {"at_s": 8, "operation": "endpoint"},
  {"at_s": 9, "operation": "gap"}
]
```

`at_s` is monotonic script time, scheduled relative to process start. `input` also accepts
`disposition: ignored` with a nonempty `reason`. Unknown values are omitted initially and after
every generation change. In process, use `TestOnlyHardwareHost(token)` as a context manager;
its `.url`, `.instance_id` and trusted `.apply_step(step)` support deterministic E2E tests.
`profile`, `capacity` and `allow_feedback` are constructor-only test configuration. This test
double advertises standard budgets but does not model concurrent rate-limit enforcement or
production parser hardening; it cannot qualify a host transport implementation.

For trusted failure-atomicity tests, call `host.reject_next_feedback()` in the test process.
The next authorized, valid display request raises the test-only `test_transport_rejected`
before a feedback event or value commits. No HTTP tool can enable this hook. Compare complete
snapshots and journals before/after; it does not model a real device's transport or prove
physical delivery. Runtime SDK version and interfaces remain unchanged.
