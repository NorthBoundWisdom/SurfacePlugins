# Optional simulation control contract 1.0

`SurfaceControlContracts` is a Foundation-only value contract for public control discovery,
simulation inputs, feedback, and a separate bounded control journal. It does not replace
Provider 1.0, `surface_capabilities`, `surface_events`, or the plugin business tools.
This delivery identifies every control event as `source: simulation`; it grants no physical
controller qualification. The host injects the existing trusted `InputOrigin` separately.

Consumers discover `surface_control_discover({})`. Its result has `schema_version: 1`,
`contract_version: "1.0"`, `source`, `expected`, and `profile`. Profile IDs and versions are
explicit host declarations. Controls have stable string IDs, input kind, encoding, optional
numeric range/step, feedback kinds, and an optional mapping target. Coordinates, layers,
device ranges, and layout remain host declarations. Business operations and units belong
to consumer mappings. Unknown profiles or encodings never fall back to another profile.

Inputs use `absolute/scalar`, `relative/signedDelta`, or `button/boolean`. The contract
never rounds or clamps input. Numeric ranges include endpoints and use a zero-anchored
step grid when a step is declared. Current host profiles use native integer grids; this
release does not claim arbitrary decimal-step encodings. Relative input expresses a delta, not an absolute
position. Feedback `value` uses `feedback_range` when declared, otherwise the input numeric range (or boolean for a button);
`indicator` accepts `off`, `on`, or `blink`. Hosts render these values using their own
motor, touch, layer, lamp, and ring rules.

All writes carry a canonical decimal `expected_sequence` matching the current control journal highwater, plus `expected` with `instance_id`, `epoch`, `mapping_revision`, `profile_id`,
and `profile_version`. Discovery includes `latest_sequence`. Accepted and ignored input/feedback writes consume a sequence; stale CAS writes return `stale_sequence` and never replay. These values come from discovery and fence stale instances and
mappings. They do not grant permission. New tools do not bypass protected parameters.
The host must authorize simulation writes and simulation-admin reset independently.
No request accepts a source or an origin. Hosts change epoch whenever source, mapping,
configuration, mode, or any binding interpretation changes. Restart changes instance identity.
Hosts supply fresh opaque epochs; reusing a past identity is outside the contract.

`surface_control_snapshot({instance_id})` returns discovery, a decimal `latest_sequence`,
initial Mock raw seeds and last accepted input values, feedback values in separate dictionaries, and `server_time` from the injected current host clock. These input values are not current motor positions or actual observations: a feedback display change never updates them. Event pages also contain `server_time`; consumers conservatively subtract server-side event age and local request elapsed time from their freshness budget. Pure reads never advance the commit clock. Empty initial
input state is unknown; trusted hosts may call `seedInputs` once before the first event, using actual current Mock state and no event; it is not evidence that controls were observed off. Accepted events
may include `mapped_value`, committed with the host parameter change. Ignored events require
a stable reason and do not change accepted input/feedback state. Feedback produces a
`feedback` event and never an `input` event, parameter input, action, or approval.

Hosts first call `SurfaceControlTools.parse` and `validateInput(input, at: time)` or
`validateFeedback(update, at: time)`. Then they copy the host engine and contract session,
process the copied engine, and call `recordInput` or `recordFeedback` with the actual
accepted/ignored result. They commit both copies only after all checks succeed. This keeps
bad time, bad values, stale identities, and logging failures atomic with the engine operation.
The shared package does not execute a second mapping engine. Remote call origin is injected
as `.remote`; local UI origin is `.interface`. Host clock values are finite and monotonic.

`surface_control_events({instance_id,epoch,after_sequence,limit})` reads only this control
journal. Cursors and emitted sequence numbers use canonical decimal strings to preserve
UInt64 precision. Limits are 1...1024. Retention defaults to 1024 events, with a configurable
maximum of 65536. Old epochs return `stale_epoch`; a future or discarded cursor returns
`event_gap`. Consumers discard pending intentions and explicitly prepare again after any
continuity failure. Neither a snapshot nor a reset replays historical input.

`surface_control_reset({expected,expected_sequence})` is an admin operation. The host supplies a new epoch,
resets its Mock/session state, and returns discovery. The value session clears inputs,
feedback, history, and sequence. Reset validates the old write clock and carries reset time into the new session; it cannot bypass clock regression checks. A host must not reset a live hardware route through
this operation. Lost mutation responses are unknown outcomes: consumers inspect state and
prepare again, without retrying the operation.

Descriptors define exact request/result schemas. Parsing rejects unknown fields, including
nested identity fields, fractional integer limits, nonfinite values, and oversized strings.
Stable contract errors use `ControlContractError.code`: `invalid_argument`, `invalid_profile`,
`unsupported_tool`, `unsupported_profile`, `unsupported_control`, `unsupported_encoding`,
`unsupported_feedback`, `invalid_value`, `invalid_result`, `invalid_time`, `instance_mismatch`,
`stale_epoch`, `stale_mapping`, `stale_sequence`, `invalid_transition`, `event_gap`, and `sequence_exhausted`. Hosts preserve these
codes at their public transport boundary and add their own permission/engine errors.

Changes to required identity or input interpretation require a new contract major.
Optional capabilities remain explicitly discovered. An older consumer must reject unknown
profiles, versions, and encodings before submitting any input.

`swift run surface-control-schema` emits the published descriptors.
`swift run surface-control-schema --examples` emits real typed request/result examples
for all six tools, including accepted and ignored inputs. Hosts package the generated
schema; validation can use an external JSON Schema validator without a product dependency.
