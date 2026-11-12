# Optional simulation control contract 1.3

`SurfaceControlContracts` is a Foundation-only value contract for public control discovery,
simulation inputs, feedback, and a separate bounded control journal. It does not replace
Provider 1.0, `surface_capabilities`, `surface_events`, or the plugin business tools.
This delivery identifies every control event as `source: simulation`; it grants no physical
controller qualification. The host injects the existing trusted `InputOrigin` separately.

Consumers discover `surface_control_discover({})`. Its result has `schema_version: 1`,
`contract_version: "1.3"` (see "Contract 1.3 changes" below), `source`, `expected`, and `profile`. Profile IDs and versions are
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

Input writes carry exactly one canonical decimal CAS: legacy `expected_sequence` compares the current control journal highwater; optional `expected_input_sequence` compares only the input highwater when `input.independent_sequence` is advertised. Reset always uses the legacy global CAS. Feedback may omit it when `feedback.unsequenced` is advertised; an explicit sequence retains the same CAS check. All writes carry `expected` with `instance_id`, `epoch`, `mapping_revision`, `profile_id`,
and `profile_version`. Discovery includes `latest_sequence`. Accepted and ignored input/feedback writes consume a sequence, including feedback without a sequence comparison. Stale CAS writes return `stale_sequence`: the request was definitely not executed, and is never replayed. These values come from discovery and fence stale instances and
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
codes at their public transport boundary and add their own permission/engine errors. Contract 1.2 also uses `permission_denied` when a descriptor declares `accepts_input: false`.

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

The SDK (`clients/python/surface_control`, now version 1.2.0), schemas (`docs/`), and fixtures
(`fixtures/`) in this repository are the single source. Hosts copy them from their managed
dependency into deliveries and do not keep their own copies.

## Contract 1.2 changes

`contract_version` is `"1.2"`; `schema_version` remains `1`. These changes are optional and
additive: 1.0/1.1 requests remain valid with their previous meaning. Profiles that omit the new
fields retain the exact 1.1 mapping revision. Hosts advertise new behavior through capabilities;
consumers allowlist the contract and profile versions. Old hosts strictly reject new fields or
requests they cannot parse. An omitted feedback sequence requires the new capability and cannot
be sent to a 1.1 host.

1. **Unsequenced feedback.** `ControlFeedback.expected_sequence` is now optional (`String?`;
   initializer `expectedSequence: String? = nil`). A host advertising `feedback.unsequenced`
   accepts `surface_control_feedback` without it. The session validates instance, profile,
   mapping, epoch, value, monotonic time, and pending lease expiry exactly as before, but skips
   sequence comparison. It still records one feedback event and consumes one sequence for an
   accepted or ignored write. Feedback remains display-only and never changes accepted inputs,
   a parameter, action, approval, or lease. A supplied sequence always gets the 1.1 CAS check;
   no capability plus no sequence returns `invalid_argument`. Input and reset still require CAS.
2. **Explicit input recovery.** Feedback can invalidate another writer's input CAS.
   `stale_sequence` means that input **was not executed**. The SDK's `refresh_sequence()` reads
   one snapshot, checks the pinned identity and monotonic clock/highwater, updates local CAS,
   and returns the decimal highwater. It never resends a request or prepares an intent. The
   caller decides whether the current intention warrants a new input after the refresh.
   Transport failure remains an unknown outcome and is never automatically retried.
3. **Current leases on event pages.** `ControlEventPage.holds` is an optional control-ID to
   deadline dictionary, with the same meaning as snapshot `holds`. It describes the page's
   **read time**, alongside `server_time`, even if the page is empty or contains old events.
   Silent renewal changes this map without changing sequence or events. No active leases means
   the field is omitted. A due, unprocessed lease still rejects the read with
   `hold_expiry_pending`; no read expires or renews a lease.
4. **Input declarations.** `ControlDescriptor.accepts_input` is an optional boolean (Swift
   initializer `acceptsInput: Bool? = nil`). With `controls.input_declared`, every control must
   declare it. Without the capability no control may declare it; `ControlProfile.validate()`
   rejects either partial form as `invalid_profile`. `false` inputs fail with
   `permission_denied` before the host engine runs. `true` means input is supported when its
   layer is active and host permissions/protections are satisfied; it grants no authority.
   Absent means legacy undeclared policy. Feedback permissions and kinds are independent.
   Trusted host bootstrap may seed a non-input control's known raw state; that is no input
   event and does not grant permission. The optional boolean is included in each mapping row
   in canonical JSON and FNV-1a; omission preserves the old hash. Capabilities themselves,
   profile ID and version still do not affect the hash.

SDK 1.2.0 accepts contracts 1.0/1.1/1.2. `Client.feedback()` omits CAS by default only when
`feedback.unsequenced` is advertised; `sequenced=True` explicitly keeps legacy CAS.
`sequenced=False` requires that capability. An unsequenced success may have a sequence greater
than the client's previous highwater plus one because another writer committed first.
`accepts_input(descriptor)` and `Client.accepts_input(id)` return `True`, `False`, or `None`;
`validate_input_declarations(profile)` checks profile consistency and is called by discovery.
The helpers do not infer a legacy policy from mapping presence.

`EventCursor.poll()` keeps returning only actual events. Its `holds`, `holds_server_time`,
`holds_request_started_monotonic`, and `holds_received_monotonic` expose the latest successfully
read page's leases and timing. Use the clock conversion below; a conservative local deadline
is `holds_request_started_monotonic + (deadline - holds_server_time)`. These values are set by
poll, do not turn a snapshot into input evidence, and do not extend any prior input's freshness.
An absent page field clears `holds` to `{}`. The v1.2 scenario fixture covers interleaved
feedback/input, explicit refresh, current leases, and declared non-input controls; v1/v1.1
files remain byte-for-byte unchanged.

## Contract 1.3 changes

`contract_version` is `"1.3"`, `schema_version` stays `1`, and SDK is `1.3.0`.
All new behaviors are capability-gated optional additions. A 1.2 input with
`expected_sequence` still compares the full journal, including feedback, with exactly its old
meaning. Older SDK version allowlists fail closed until deliberately upgraded. New SDKs keep
using legacy CAS against a host without the new input capability. Old v1/v1.1/v1.2 fixtures
remain byte-identical; [v1.3](../fixtures/surface-control-software-v1.3.json) adds new evidence.

1. **Independent input CAS (`input.independent_sequence`).** Discovery, snapshots, and event
   pages include `latest_input_sequence`; every event includes `input_sequence`, its input
   highwater just after that historical commit. These are canonical UInt64 decimal strings.
   Accepted **and ignored** inputs, including host `hold_expired`, increment it. Feedback leaves
   it unchanged; renewal remains silent. The single journal `sequence` remains continuous and
   still includes feedback. No second journal or feedback counter is introduced.

   An input has exactly one of `expected_sequence` and `expected_input_sequence`; both or neither
   is `invalid_argument` in both schema and strict parser. New CAS is accepted only with the
   capability and returns `stale_input_sequence` if it does not match: the input definitely did
   not execute. A feedback committed in between does not invalidate it, but any input, ignored
   input, or expiry does. Both identity/CAS checks and required-counter exhaustion checks run
   before host engine execution, including preflight calls without an explicit time. Hosts
   retain monotonic time and pending-expiry fences, copy/validate/commit atomicity, and permission
   checks. Reset still uses global CAS, changes epoch, and clears both counters. Changing the
   optional capabilities alone does not change `mapping_revision`; hosts still rotate context.

   SDK `Client.input(..., cas="auto")` selects independent CAS when supported; `cas="global"`
   retains old CAS and `cas="input"` requires the new capability. `latest_sequence` and
   `latest_input_sequence` are stored separately. `refresh_sequence()` still returns global
   highwater, and `refresh_input_sequence()` returns input highwater; each reads one snapshot
   without writing or replaying an input. Unknown transport outcomes are never retried.
   Mutation responses may jump global sequence while observing one input increment. Existing
   `EventCursor` positions do not move on mutation or refresh. Poll checks contiguous global
   events and kind-consistent input increments, keeps historical page values separate from the
   latest CAS, and never rolls a client's input CAS back during pagination.

   `BinaryRoleCursor` retains its conservative **global** superseded/verify rule: later feedback
   can still supersede an intent for that consumer. Independent input writing does not silently
   relax that safety check. Consumers needing a different verification policy require separate
   design and evidence.

2. **Trusted principals (`events.writer_id`).** Every event includes `writer_id` only when the
   profile declares this capability. The host authenticates a credential, resolves its own
   opaque principal record, and passes the public ID through trusted `writerID:` parameters on
   `validateInput`, `validateFeedback`, `recordInput`, `recordFeedback`, and `recordHoldExpiry`.
   Missing/invalid IDs fail before record/state changes; no remote request accepts a writer ID.
   IDs use 1–128 ASCII letters/digits/`_`/`.`/`-`. The host issues random IDs with at least 128
   bits of entropy; the shared contract neither signs identities nor reads/hashes credentials.
   Never publish raw credentials, their plain hashes, or short credential fingerprints.

   Remote, interface, and system-expiry principals are distinct. Expiry retains
   `origin: remote / reason: hold_expired` and uses the system ID, never the last remote caller's
   ID. `writer_id` is attribution, not authorization, a replay token, or lease ownership.
   With today's single bearer credential, all remote clients belong to one principal; it does
   **not** distinguish clients using that same credential. Any number of read-only clients can
   coexist. Readers filtering principals still advance over the complete journal.

   By default host IDs are stable across connections for the current instance/process and no
   file is written. Hosts may explicitly persist their own record with
   `--surface-principal-file PATH`: strict schema_version 1 and three different
   `remote_writer_id`, `interface_writer_id`, `system_writer_id`, no credential or fingerprint.
   Existing records must be current-user-owned regular non-symlink files with mode 0600;
   creation is safe create-only/atomic with 0600, never overwrites or follows a raced path.
   Reusing a validated record may retain principals over restart/explicit credential rotation,
   while instance/epoch fences still change normally. These private files never enter a public
   delivery or manifest. IDs have no cross-host identity meaning.

3. **Independent write limits (`writes.independent_limits`).** In explicit independent mode,
   discovery includes `write_limits`: `window_s: 1`, `input_per_window`, `feedback_per_window`,
   `renew_per_window`, `admin_per_window` (integers 1–10000). It must be absent without the
   capability. The shared `ControlWriteLimits` is only a value description; hosts own timing,
   permission checks, accounting, and existing rate-limit errors.

   Hosts opt in with `--write-limits input=60,feedback=20,renew=60,admin=5` (all four keys required,
   no duplicates/unknowns). This conflicts with explicit `--write-limit N`, whose original
   aggregate meaning remains unchanged. Without the new option, default aggregate60/s remains.
   Independent fixed 1s windows are per instance/category and shared by all clients, without
   borrowing. Input/feedback/renew/admin(reset) each use their own quota. Validation failure
   does not consume quota, and time regression does not create fresh quota. System expiry
   never consumes an external write budget. Feedback exhaustion cannot consume input/renew
   quota; renewal exhaustion cannot consume rest/stop input quota. A rejected call has not
   executed and is not automatically queued/replayed; an expired lease is never locally extended.

Hosts adopting 1.3 lock the same shared SHA and explicitly update profile version, SDK/schema,
capability allowlists, and delivery pins. If control mapping content stays unchanged, its hash
stays unchanged. Pipe's own parser/SDK/role pins must be upgraded by its maintainers; this
contract does not claim its Worker workflow has been verified.

## Consumer guidance

These points apply to the legacy aggregate mode and CAS as indicated; the optional 1.3 modes
above refine writing and attribution without changing clock, expiry, or permission rules.

**Shared write budget (legacy mode).** Input, feedback, renewal, and reset calls share the host's per-second
write limit; both current hosts default to 60 calls/s. A silent renewal still uses that budget,
and unsequenced feedback does not bypass it. Treat the limit as a ceiling, not a target, and
leave capacity for operator input and lease renewal. Start display feedback at a fixed 2–5 Hz
per value, emit only changed values, and reduce the rate when many controls share an instance.
For example, three changing values at 5 Hz already use 15 calls/s before input or renewal.
Renew at about one third of the lease duration, well before the conservative local deadline;
account for every concurrently held control. These rates are recommendations, not additional
protocol guarantees. If the budget is exhausted, do not automatically replay a lost input or
extend a lease locally; use the host's result and the existing fail-closed recovery rules.

**Feedback and legacy input CAS.** Unsequenced feedback still consumes the shared journal sequence.
An input prepared before that feedback can therefore receive `stale_sequence`; this response
means the input definitely did not execute. Call `refresh_sequence()` to read the current
highwater, then let the caller decide whether the intention is still current and submit a new
input explicitly. The SDK never replays the rejected input. More frequent feedback increases
the chance of these conflicts; change-only, low-frequency feedback reduces them. A feedback
success may jump the client's CAS highwater over other writers' events. It does not advance an
existing `EventCursor`: the next poll still reads every event after its own cursor. A transport
failure instead leaves the mutation outcome unknown and requires reconciliation.

**When hosts declare hold.** A host may advertise a control's `hold` only when the control
accepts input and restoring its declared `rest_value` makes the bound effect stationary.
Momentary parameter bindings can satisfy this rule; a toggle whose release does not restore
the effect, or a control that rejects input, cannot. Consumers may rely on this restoration
meaning when requesting a lease with `hold_s`, while still observing layer, permission, and
protection rules. The descriptor alone does not acquire a lease: it is the accepted held input
that starts one. Expiry restores the simulated bound effect; it is not qualification of a
physical controller or a replacement for a consumer's own deadman and stop handling.

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

**Writers and readers without `events.writer_id`.** These events do not identify remote callers. `origin: remote` covers
every remote caller with input permission and also the host's own `hold_expired` event, which is
told apart only by `reason: "hold_expired"`. Any number of clients may read (discover, snapshot,
events) at once. Input/reset writes and sequenced feedback use `expected_sequence`: of two concurrent CAS
writers one gets `stale_sequence`. Unsequenced feedback bypasses comparison, but still increments
the same journal, so it may cause an input CAS conflict. Use one input writer per instance and
explicit sequence refresh after a confirmed conflict; a display-feedback writer may coexist.
The contract does not stop another authorized input client from writing. A read-only
follower beside the instance owner is allowed; when the owner resets, the epoch changes, the
follower gets `stale_epoch`, and it must discover and bootstrap again, discarding pending
intentions. A stable writer identity is available only through the explicit 1.3 `events.writer_id` capability.

**Controls without a mapping.** On a profile declaring `controls.input_declared`, inspect
`accepts_input` instead of inferring permission from a mapping. The BCR host declares input only
for controls bound to writable, unprotected parameters. The XTouch host declares input for
unassigned controls and parameter bindings, and rejects action bindings. For a layered profile,
the declaration means "when its layer is active"; the active layer remains runtime state. On
legacy profiles without this capability, policy is undeclared: follow the host's documentation.

**Renewals and read-only observers.** `surface_control_renew` writes no event and consumes no
sequence. The acquiring event's `hold_deadline` is only the first deadline. A 1.2 observer reads
current `holds` directly on each events page, including an empty page; a 1.1 observer reads them
from a snapshot. Rest input or `hold_expired` still provides accepted input evidence for the
end of a lease. Neither renewal nor the page's lease map alone creates a fresh input intent.

The fields of a host delivery manifest are described in
[surface-control-delivery.md](surface-control-delivery.md).
