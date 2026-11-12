# Reproducible host simulation scenarios, versions 1, 1.1, 1.2 and 1.3

The [1.0 fixture](../fixtures/surface-control-software-v1.json) and the
[1.1 fixture](../fixtures/surface-control-software-v1.1.json) are neutral versioned test
specifications with one shared [JSON Schema](surface-control-scenario.schema.json).
The 1.0 file is kept byte-for-byte unchanged so existing host reports remain comparable. The 1.1
file is a superset: it declares `contract_version: "1.1"`, repeats every 1.0 scenario unchanged,
adds a `hold_input` role, and adds two lease scenarios. A host running contract 1.1 runs the 1.1
file; `scenario_schema` stays 1 because every 1.0 document remains valid. It drives a real
host Mock/session adapter using an injected monotonic clock. There is no second mapping or
business engine in this package. Consumers map logical roles to their own stable control IDs;
business meanings, tasks, authorization, and device models remain outside this fixture.

Each scenario starts with independent newly created host Mock state and identity. The runner
uses `initial_time_s + at_s` as operation time, never sleeps, and supplies current server-issued
expected identity and CAS to each write. `minimum` and `maximum` mean the mapped control's
declared input range endpoints; feedback value uses its separate feedback range when present.
Indicator strings are literal. Roles must satisfy the fixture's declared input/feedback kinds.
The four ordinary input roles start explicitly at their Mock minimum; they are not protected
production command parameters. Feedback roles use independent controls. Hosts expose stable
role mapping in the test report. No role name implies arm, task execution, or motion authority.

Operations have these runner meanings:

| Operation | Meaning |
| --- | --- |
| snapshot | Read real host state, current input/feedback session, and event highwater. Capture initial fences per instance on first read. |
| input | Submit the mapped control value with current identity/CAS, except an explicit `expected_scope: initial` substitutes the initial identity. `encoding` overrides the discovered encoding only for a negative case. |
| feedback | Submit feedback through the host's real feedback path; input values and accepted input evidence remain unchanged. |
| replay_last_write | Re-submit the exact saved prior mutating request. Do not update its identity or CAS. Expected rejection proves no replay. |
| events | Read the control journal with current instance/epoch and the stated decimal cursor. |
| reset | Use authorized simulation admin reset with current identity/CAS/time, rebuild actual Mock initial state, and bootstrap only known raw values. |
| restart | Recreate only the named host instance with fresh instance identity and initial Mock state; other instances continue unchanged. |
| renew (1.1) | Call `surface_control_renew` with current identity, the role's control, and `hold_s`. No sequence or event is expected. |
| advance (1.1) | Move the injected clock to the step time and let the host process every due lease exactly as its own scheduler would: apply the rest value to the engine, then `recordHoldExpiry`. No public request is made. |

Contract 1.1 additions. A role with `"hold": true` must map to a control whose descriptor has `hold`;
the host seeds it at its rest value. Value `rest` means the descriptor's `hold.rest_value`; value `active`
means one admissible non-rest input (for a button `true`; for a scalar the range endpoint that differs from
rest). `hold_s` on an `input` step is sent as the request field. `hold_deadline_at_s` is the expected
`hold_deadline` relative to `initial_time_s` (it equals step time plus `hold_s`) for an input event or a
renew result. `holds` lists the roles with an active lease in the snapshot after the step; `[]` means none.
`expired` lists the roles whose expiry events the `advance` step recorded, in order. `event_reasons` lists
the `reason` of each returned event, in order. An expiry event counts toward `accepted_input_delta`: it is
an accepted input with `origin: remote` and reason `hold_expired`. While a lease with deadline at or before
the operation time is unprocessed, every read and write fails with `hold_expiry_pending`; the
`hold_expiry_pending_fail_closed` scenario uses `scope: inprocess` because a real host scheduler would
normally process the expiry first. Its `atomic` expectation includes the still-pending lease.

`clock_override_s` and `invalid_value: nan` are in-process fault probes, not public tool fields.
The runner constructs the nonfinite Swift value directly and injects clock override into the
host adapter before engine processing. A JSON transport separately rejects invalid JSON/nonfinite
numbers; it must not accept a client clock field. `scope: host` cases can also run through a real
public transport when the isolated test server supports clock injection internally. `scope:
inprocess` is never reported as network/process validation. `event_capacity` configures the
isolated test session; it is not a new public mutation capability.

`expect.disposition` checks the actual host result; ignored reason strings may differ by host.
`accepted_input_delta` counts only `kind: input, disposition: accepted` events since the previous
step for that instance. `accepted_input_count` counts those events in the current epoch. Neither
counts feedback or ignored input. `known_inputs` compares fixture endpoint values to seeded or
last accepted raw input state, without treating snapshots as operation evidence.
`atomic` requires unchanged host engine state, input/feedback values, epoch, highwater, and
journal after a rejected operation; pure-read `server_time` may advance. Reset is checked for a
changed epoch and cleared history; restart for changed instance identity. Bounded journal gaps
fail closed and require new explicit preparation. No failure path automatically retries an input.

Reports include fixture scenario/version and SHA256, exact host/shared revision, profile ID and
version, role mapping, per-step normalized `pass`/`fail`/`skip`, actual disposition/error, accepted
input count, and relevant sequence/epoch-change evidence. An unavailable fault injection or
configuration is `skip` with reason, never a pass. Credentials and tokens are excluded. Concrete
instance/epoch entropy, wall clock times, and layout coordinates need not match across hosts;
normalized semantic results must match. Separate real HTTP/process tests cover disconnection,
unknown response outcomes, process replacement, and deployment isolation.

These fixtures establish software control behavior. Existing Agent/Robot/Chassis/Output tests
remain the deterministic device/safety baseline. This fixture does not implement a second device
simulator or claim a complete application workflow, physical qualification, or Pipe integration.

Development validation uses an isolated Python environment containing `jsonschema`:

```sh
swift run surface-control-schema --examples > /tmp/surface-control-examples.json
python scripts/validate_surface_control_schemas.py --examples /tmp/surface-control-examples.json
```

The validator checks published request/result schemas against actual typed examples (including a
lease, renewal, and `hold_expired` event) and both fixtures against the scenario schema; it also
checks that 1.1-only steps never appear in the 1.0 fixture. Its JSON `pass` result means schema validation;
host scenario execution results are separate.

## Contract 1.2 fixture

The [1.2 fixture](../fixtures/surface-control-software-v1.2.json) repeats every 1.1 scenario
unchanged and adds three scenarios (9 scenarios, 83 steps total). Both older fixture files
remain byte-for-byte unchanged. The scenario schema stays version 1 and accepts all three.

New runner fields and operation:

- `feedback.omit_sequence: true` omits `expected_sequence`; the feedback still consumes one
  journal sequence. This path requires `feedback.unsequenced`. Ordinary feedback retains CAS.
- `expected_sequence` on a step overrides the runner's current CAS with the given decimal.
  It deliberately models an input writer whose last known sequence predates a feedback event.
- `refresh_sequence` reads exactly one snapshot and updates only the runner's local CAS. It
  submits no mutation; the next input is a new, explicitly chosen request. `stale_sequence`
  proves the rejected input did not execute. Transport failure remains an unknown outcome.
- `expect.holds` on an events operation checks that page's current lease set, independently
  of which events the cursor returns. `hold_deadlines_at_s` checks the complete role-to-deadline
  map relative to `initial_time_s`, including an empty map after expiry. Renewal changes this
  map even when the page has zero events and an unchanged highwater.
- Role `blocked_input` requires a descriptor with `accepts_input: false`. It imposes no
  encoding: for this role `minimum` is `range.minimum` for a numeric control, or `false` for
  a boolean control. Its input must fail with shared error `permission_denied`, atomically.
  All other roles keep their previous constraints. Hosts declare `controls.input_declared`
  and supply truthful `accepts_input` on every descriptor.

The interleaving scenario serializes two logical writers at deterministic injected times:
input commits, unsequenced feedback commits despite its writer's old local sequence, stale
input is refused, then explicit refresh and a new input succeed. Separate host transport
tests cover actual concurrent connections; fixture execution alone does not claim concurrency.

## Contract 1.3 fixture

The [1.3 fixture](../fixtures/surface-control-software-v1.3.json) retains all 83 v1.2 steps and
adds `independent_input_cas_and_trusted_writers` (10 scenarios, 97 steps total). Older files are
byte-identical. Top-level `required_capabilities` requires independent input CAS and trusted
writer IDs. Legacy fixture steps always use global CAS, even when the host supports 1.3.

- `expected_input_sequence` selects the new CAS and suppresses the runner's default global
  field. The saved wire request must contain exactly that one field. Existing explicit
  `expected_sequence` keeps its old override meaning.
- `expect.latest_input_sequence` checks discovery/snapshot/event/page input highwater, as
  applicable; `sequence`/`latest_sequence` still refer to the single global journal.
- `expect.writer_kind` checks a returned event against the test host's trusted remote, interface,
  or system principal. `event_writer_kinds` checks those identities in returned event order.
  Fixture files never contain credentials, fingerprints, or a persisted private principal file.
- `expect.event_input_sequences` checks each event's historical input highwater; page latest
  highwaters refer to read time. New evidence covers feedback not consuming input CAS, old global
  CAS still failing after feedback, ignored inputs consuming input CAS, reset clearing both,
  and expiry using system identity and invalidating old input CAS.

Reports normalize principals to their trusted `writer_kind` for cross-host comparison; public
opaque ID entropy may differ. Independent-limit admission and credential/principal file security
need separate real-process tests, alongside the fixture's deterministic adapter evidence.
