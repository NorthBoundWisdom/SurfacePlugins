# Optional simulation control contract 1.1

`SurfaceControlContracts` is a Foundation-only value contract for public control discovery,
simulation inputs, feedback, and a separate bounded control journal. It does not replace
Provider 1.0, `surface_capabilities`, `surface_events`, or the plugin business tools.
This delivery identifies every control event as `source: simulation`; it grants no physical
controller qualification. The host injects the existing trusted `InputOrigin` separately.

Consumers discover `surface_control_discover({})`. Its result has `schema_version: 1`,
`contract_version: "1.1"` (see "Contract 1.1 changes" below), `source`, `expected`, and `profile`. Profile IDs and versions are
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
`stale_epoch`, `stale_mapping`, `stale_sequence`, `invalid_transition`, `event_gap`, and `sequence_exhausted`;
contract 1.1 adds `unsupported_hold`, `hold_expired`, and `hold_expiry_pending`. Hosts preserve these
codes at their public transport boundary and add their own permission/engine errors.

Changes to required identity or input interpretation require a new contract major.
Optional capabilities remain explicitly discovered. An older consumer must reject unknown
profiles, versions, and encodings before submitting any input.

`swift run surface-control-schema` emits the published descriptors.
`swift run surface-control-schema --examples` emits real typed request/result examples
for all seven tools, including accepted and ignored inputs, a held input, a renewal, a snapshot
with `holds`, and a `hold_expired` event. Hosts package the generated
schema; validation can use an external JSON Schema validator without a product dependency.

## Contract 1.1 changes

Version policy. `contract_version` is now `"1.1"`; `schema_version` stays `1`. All changes are
optional and additive: every 1.0 request is still accepted with 1.0 meaning, and responses only
gain optional fields (`hold`, `hold_deadline`, `holds`) when a 1.1 feature is used. New request
fields (`hold_s`) and the new tool are rejected by a 1.0 host's strict parser, so a 1.1 consumer
fails closed against an old host. Consumers allowlist contract versions explicitly.

Behavior changes, each intentional:

1. Mapping revision. `ControlProfile.mappingRevision` is derived from the profile: for each
   control, the fields `id`, `input_kind`, `encoding`, `range`, `feedback_range`,
   `feedback_kinds`, `mapping`, and `hold` (absent optional fields omitted, `feedback_kinds`
   sorted) form an object; the objects are ordered by control ID (Unicode scalar order) and
   serialized as a JSON array with sorted keys and no whitespace. Numbers that are integral and
   below 2^53 in magnitude print as integers (`-0` prints `0`), other finite numbers print as
   the shortest round-trip decimal (Swift `Double.description`, equal to Python `repr(float)`);
   strings use JSON escapes for `"`, `\`, `\b`, `\f`, `\n`, `\r`, `\t` and `\u00XX` for other
   control characters, with all other characters as UTF-8. The revision is the FNV-1a 64-bit
   hash of those UTF-8 bytes as 16 lowercase hex digits. Profile ID, version, capabilities, and
   control order do not affect it. Hosts must use it; random or constant values are no longer
   conforming. `SurfaceControlSession(instanceID:epoch:profile:)` and
   `reset(expected:expectedSequence:epoch:profile:at:)` apply it automatically; the explicit
   `mappingRevision:` initializers stay for source compatibility. The Python SDK verifies it.
2. Validation order. `validateExpected` now checks instance, profile, mapping, then epoch. A
   request whose mapping changed returns `stale_mapping` even though the epoch also changed;
   `stale_epoch` now means "same mapping, new epoch". Hosts still change epoch on every change.
3. Capability vocabulary. Registered values: `simulation`, `controls.stable_ids`,
   `controls.layered`, `input.absolute`, `input.relative`, `input.button`, `input.hold`,
   `feedback.value`, `feedback.indicator`. Host-private values use `x.<host>.<name>` (for example
   `x.bcr.indicator_blink_as_on`). `ControlProfile.validate()` rejects any other value and requires
   consistency: each input kind present needs `input.<kind>`, each feedback kind present needs
   `feedback.<kind>`, a `hold` descriptor needs `input.hold`, and `input.hold` needs at least one
   control with `hold`. **This deliberately makes the current host profiles invalid** (for example
   `stable_control_ids`, `display_only_feedback`, `absolute_input`, `layered_controls`); hosts adopt the
   vocabulary when they lock this revision (P2). Until then they must stay on the previous lock.
4. Numeric normalization. The session stores and emits numbers in one form: integral values
   representable as `Int` become `.number`, others `.double`, recursively. This applies to
   `seedInputs`, accepted inputs, feedback values, event `value`, `mapped_value`, and snapshots.
   `.double(80)` and `.number(80)` are therefore the same state. `isUnchanged(_:)` returns true when
   accepting the input would change neither the stored value nor any lease (a relative input is
   unchanged only for a zero delta; an unknown, unseeded value is never unchanged). Hosts use it
   for `ignored/no_change` instead of comparing `JSONValue`s themselves. Validation is unchanged:
   off-grid values are still rejected, never rounded.
5. `input.hold` leases (S5 deadman prerequisite).
   - Descriptor `hold: {rest_value, max_hold_s}` is allowed on absolute/scalar and button/boolean
     controls; `rest_value` must be a valid input and `max_hold_s` lies in (0, 10]. Relative
     controls cannot declare it.
   - `surface_control_input` accepts optional `hold_s` in (0, max_hold_s]. On a control without
     `hold` it fails with `unsupported_hold`; a bad duration fails with `invalid_argument`.
   - An accepted non-rest input with `hold_s` sets `hold_deadline = time + hold_s` (returned in the
     event). Any other accepted input on that control, including the rest value or a value without
     `hold_s`, clears the lease. Ignored input leaves the lease unchanged.
   - `surface_control_renew({expected, control_id, hold_s})` sets the deadline to `time + hold_s`.
     It takes no `expected_sequence`, consumes no sequence, and writes no event (like D14 silent
     bookkeeping), but it advances the session write clock. It succeeds only for a held,
     unexpired lease; otherwise `hold_expired`. Hosts require simulation input permission and count
     it against the write budget. Returns `{control_id, hold_deadline, server_time}`.
   - Expiry. `dueHoldExpiries(at:)` is pure and lists leases with deadline <= t (ordered by
     deadline, then ID) with their rest value. The host applies the rest value to its own engine,
     then calls `recordHoldExpiry(controlID:mappedValue:at:)`, which writes
     `kind input / disposition accepted / origin remote / reason "hold_expired"` and stores the
     rest value. This is the only accepted event with a reason defined by the contract; ordinary
     `recordInput` keeps its existing reason rules. `nextHoldDeadline` helps hosts schedule.
   - Fail closed. While any lease with deadline <= t is unprocessed, every session read or write at
     time t (snapshot, events, input, feedback, renew, reset) fails with `hold_expiry_pending`.
     Hosts must advance expiries on their own monotonic clock even without requests.
   - Snapshots include `holds: {control_id: deadline}` when any lease is active. Reset clears all
     leases (and is itself rejected while an expiry is pending).
6. Tools. Seven descriptors (adds `surface_control_renew`). Input schemas may now list optional
   fields; the strict parser still rejects unknown fields and requires every required one.

The SDK (`clients/python/surface_control`, version 1.1.0), schemas (`docs/`), and fixtures
(`fixtures/`) in this repository are the single source. Hosts copy them from their managed
dependency into deliveries and do not keep their own copies.

## Consumer guidance

These points describe contract 1.1 as published. Items marked "open topic" would need a schema
change and are not provided in this version.

**Clock conversion.** `server_time`, event `time`, and `hold_deadline` are readings of the
host's monotonic clock. Their absolute values mean nothing to a client; only differences do.
To place a deadline on the local monotonic clock, record `t_send` immediately before sending the
request and `t_recv` when the response arrives. The host read `server_time` somewhere between
those two instants, so the deadline lies in
`[t_send + (hold_deadline - server_time), t_recv + (hold_deadline - server_time)]`.
A consumer that must stop before the host does (a deadman) uses the lower bound,
`t_send + (hold_deadline - server_time)`; it is early by at most the round trip `t_recv - t_send`.
Use the same rule for event freshness: an event is at least `server_time - time` old at `t_send`.
Renew well before the lower bound and never extend a local deadline from a response whose
`server_time` did not come from the request being measured. Clock rate difference over a lease
of at most 10 s is negligible next to the round trip.

**Writers and readers.** The contract does not identify remote callers. `origin: remote` covers
every remote caller with input permission and also the host's own `hold_expired` event, which is
told apart only by `reason: "hold_expired"`. Any number of clients may read (discover, snapshot,
events) at once. Writes are serialized by `expected_sequence`: of two concurrent writers one
gets `stale_sequence`, so the instance behaves as a single-writer journal, but the contract does
not stop a second authorized client from writing. Run one writer per instance. A read-only
follower beside the instance owner is allowed; when the owner resets, the epoch changes, the
follower gets `stale_epoch`, and it must discover and bootstrap again, discarding pending
intentions. A stable writer identity in events is not provided (open topic).

**Controls without a mapping.** Whether an unmapped control accepts input is a host
declaration, not a contract rule, and the profile does not mark it. Consumers must not assume
either way and follow the host's document. At this revision: the BCR host accepts input only on
a control mapped to a writable, unprotected parameter and otherwise returns `permission_denied`;
the XTouch host accepts input on unassigned controls and returns `unsupported_mapping` for
controls bound to an action. A profile field marking which controls accept input is an open topic.

**Renewals and read-only observers.** `surface_control_renew` writes no event and consumes no
sequence, so an event reader does not see a lease being extended. The `hold_deadline` in the
acquiring event is only the first deadline. An observer that needs current deadlines reads
`holds` in the snapshot; the end of a lease is always visible as an input event (a rest input,
any other accepted input on the control, or `hold_expired`). Carrying leases on event pages is
an open topic.

The fields of a host delivery manifest are described in
[surface-control-delivery.md](surface-control-delivery.md).
