# Read-only surface diagnostics

This independent standard-library package captures a bounded software observation window and
verifies it offline. It interprets no business roles, opens no device driver and makes no claim
of physical-device qualification. The runtime SDK remains a separate, unchanged package.

```sh
PYTHONPATH=/path/to/extracted-sdk python3 -B -m surface_control_diagnostics capture \
  --url http://127.0.0.1:8787/mcp --token-file /private/token \
  --instance-id instance --profile-id explicit.profile --profile-version 1.4 \
  --accept-hardware --max-polls 1 --output /tmp/capture.json --report /tmp/report.json

PYTHONPATH=/path/to/extracted-sdk python3 -B -m surface_control_diagnostics verify \
  --capture /tmp/capture.json --report /tmp/offline-report.json
```

`capture` needs explicit instance, profile ID and profile version. Hardware requires
`--accept-hardware`; omission retains SDK simulation-only acceptance. A fresh SDK client is
created for this single context. No automatic rediscovery, reconnect, epoch handoff, reset or
replay is performed. Only `surface_control_discover`, `surface_control_snapshot` and
`surface_control_events` are called, plus the SDK's protocol initialization handshake.
The client rejects every other tool before HTTP, including display feedback and mutation probes.

Default bounds are `--duration-s 10`, `--max-polls 100`, `--max-events 1024`,
`--max-bytes 8388608`, `--interval-s 0.1`, `--max-age-s 2`. All are finite and bounded by
implementation limits; capture input to verify is at most 16 MiB. The duration is checked
between reads, with the SDK timeout reduced to the remaining budget for event requests;
initial SDK initialization and an in-flight request can finish after that nominal duration.
This is a bounded diagnostic, not a hard real-time deadline. A single SDK response is also
bounded by the SDK's existing 8 MiB transport limit. No read or write is retried automatically.

Snapshots omit unknown values. Accepted new inputs can make them known; ignored inputs cannot.
By default, every profile control must become known for a zero exit. Repeat `--require-control`
to explicitly restrict that check to a selected subset; the report labels that scope. An ignored
button may remain unknown indefinitely. Scope selection does not turn an unknown unselected
control into known input, or make a snapshot value evidence of fresh operator intent.
Historical events before the initial snapshot highwater are deliberately discarded.

Exit codes are the same for capture and verify:

- **0**: the recorded bounded window is consistent, at least one event page was validated,
  required controls are known and no unconsumed page backlog remains. This is software data
  consistency only, not an assertion that a device, operator action or business workflow was tested.
- **1**: a structurally valid artifact is incomplete or records failure: unknown controls,
  initial disconnected link, old epoch, gap, stale data, transport failure, byte bound or pending
  events. Valid initial disconnected capture has `snapshot.link.state: disconnected`, empty
  pages and `end.reason: link_disconnected`; capture and verify both return 1.
- **2**: configuration, file I/O, malformed artifact or an offline invariant check failed.
  Nothing is labeled verified on this path. Diagnostics print fixed codes, never exception text.

`capture` publishes only an artifact that its offline verifier can account for. Captures and
optional reports are written as private 0600 temporary files and atomically replaced. The token
file cannot also be an output/report. Credentials, endpoint URLs and HTTP headers are excluded.
Known credential reflection is rejected recursively in both values and keys before storage;
unknown response fields are rejected, and error codes use a fixed allowlist with the existing
checker anti-reflection policy. Do not put credentials in public profile IDs or other host data.

The capture has schema_version 1, artifact `surface-control-diagnostic-capture`, qualification
`software-diagnostic-only`, SDK version, requested source/identity/profile/scope, bounds,
discovery, initial snapshot, bounded pages, local monotonic clock origin/elapsed time and `end`.
Each page stores exact SDK poll tick values (`started_s`, `received_s`, local monotonic domain),
the bounded page response, result and a fixed error code. `end` records stop trigger, reason,
exit_code, captured accepted/ignored event count, retained page count, unknown required controls
and whether a captured page still advertised unread backlog. A final SDK-rejected page is
labeled error; its entries do not count as validated events. Failed requests without a response
retain only the earlier validated prefix and an explicitly unverified termination cause.

`verify` has no network path. It feeds saved discovery/snapshot/pages through an in-memory SDK
client and `EventCursor`, checking identity, profile, content-derived mapping revision, link,
continuous global/input counters, origins, value ranges, monotonic times and SDK freshness
bounds. It also checks limits, selected required controls, complete stop metadata and unknown
state. Duplicate JSON keys, nonfinite JSON, changed sequences/identity/values and inconsistent
status/counters are rejected. It does not authenticate a capture or detect edits that preserve
all recorded invariants; callers can pin a file hash out of band if provenance is needed.

Reports separate `capture_integrity: verified_recorded_invariants` from `diagnostic_status`
(`bounded_complete` or `incomplete_or_failed`). `checked` lists evidenced checks; `unavailable`
explicitly lists absent discovery, snapshot, successful pages or new events, and termination
errors without response evidence. `validated_page_count` excludes a terminal rejected page.
`authenticity_verified` and `physical_qualification` are always false. No skipped/uncollected
step is counted as a successful test. Unknown/disconnected/failed captures remain exit 1 even
when their recorded structure is valid. A rejection page is verified as a rejection, never as a
successful page or successful operation. Reports intentionally omit the raw profile and events.

This package can be included beside `surface_control/`, `surface_conformance/` and
`surface_control_testing/` in a delivery SDK zip. All three diagnostics files must be copied
byte-identically from the pinned shared revision and hashed as shared source. The test-double
package is needed only for tests; capture/verify themselves never import it.
