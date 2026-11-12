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
