# Live conformance checker

The standard-library checker is packaged beside the SDK. Its command and role mapping are
specified here; it validates public transport observations and explicitly skips unavailable
injected-clock or process-local probes. Skips do not count as passes.

```sh
PYTHONPATH=/path/to/extracted-sdk python3 -m surface_conformance \
  --url http://127.0.0.1:8787/mcp --token-file /private/token \
  --instance-id instance --fixture surface-control-software-v1.3.json \
  --roles conformance-roles.json --report /tmp/conformance-report.json
```

The host must be an isolated simulation with write and reset permissions. No write is retried.
The report excludes token contents and endpoint headers. Exit status is 1 if any step fails,
0 for a report containing only pass/skip, and 2 for invalid invocation or configuration.
A zero exit status with skips does not establish complete fixture conformance.

Role map version 1 is a JSON object:

```json
{
  "schema_version": 1,
  "roles": {"input_a": "axis.1", "feedback_state": "lamp.1"},
  "writer_ids": {"remote": "public.remote.principal"}
}
```

`roles` maps fixture role names to discovered control IDs. Omit unavailable roles, or use
`null`; never map a declared non-input role to an input-enabled descriptor. Descriptor kinds,
encodings, feedback kinds, hold support, and input declarations are checked against the fixture.
Mappings must use separate controls for separate roles. `writer_ids` is optional and maps
fixture writer kinds to host-issued **public opaque writer IDs**, obtained from trusted host
configuration. These IDs are not credentials. Without a trusted mapping a writer expectation
is skipped, never inferred from event origin. Extra role names and unknown map fields are errors.

`--protocol` selects `2025-11-25` (default) or `2026-07-28`. Optional paired
`--provider-id` / `--provider-header` pins a host response identity header. The fixture version
may be older than the serving host version. Reports record both versions; older fixture writes
always keep global CAS even when the host also offers independent input CAS.

Every scenario is independently reset before execution. If admin reset is denied, the entire
scenario is skipped: these fixtures all require newly initialized state. `scope: inprocess`
scenarios and non-default journal capacities are skipped because public tools cannot establish
their prerequisites. Exact deadline expectations require injected time and are skipped before
issuing a hold write. Restart, clock override, nonfinite-value injection, and `advance` are also
skipped. The checker never sleeps to approximate an injected clock. A skipped successful mutation taints later steps because their state/history prerequisites
were not established; an explicit successful reset can restore clean state. A skipped
`error` + `atomic` rejection probe submits no request and leaves the expected poststate
unchanged, so later independent public checks can still execute. A failed step stops the
scenario. A new scenario can proceed after its own reset.

Every expectation in a passing step is checked; an unknown expectation fails rather than being
ignored. Snapshots and full journal reads before/after each executed step supply observable
state evidence and accepted input counts. Tests and integration evidence must be interpreted
with these extra read requests in mind; they do not establish arbitrary concurrent-writer or
retention-capacity behavior. Use an isolated server without other writers or scheduled effects.

The JSON report follows [surface-control-conformance-report.schema.json](surface-control-conformance-report.schema.json).
Step indexes are zero based. `actual` contains checked expectation values (symbolic endpoint
values and writer kinds are resolved to public control values and public writer IDs); the
`error` and `disposition` fields retain the operation's actual outcome. `counts` partitions
all fixture steps into pass/fail/skip. A failure stops that scenario without retrying the write.
A transport or invalid-response failure remains an unknown outcome; subsequent scenarios begin
with an explicit admin reset rather than replaying that request.

`atomic` includes private host engine state, which public tools cannot read. Such a step is
always skipped **before submitting its request**, even when snapshot and journal comparisons
could establish the observable subset. The process-local runner supplies the private-engine
evidence; a live report never labels that partial observation as a complete atomic pass.
Skipped steps have `executed: false` and contain no fabricated actual result. For executed
steps this field means the public operation was attempted, not that a mutation is known to
have committed (a transport failure still leaves its outcome unknown).
