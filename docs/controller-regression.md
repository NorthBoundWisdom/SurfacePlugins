# H-10 neutral controller scenario interface

The sole scenario data is `fixtures/controller-regression-v1.json`: T01–T30 from
`reports/ARCH_MEMO_CONTROL_SURFACE_2026-11-14.md` 20.2. There are 30 scenarios and 78
ordered steps. Host-native executors drive each host's actual APIs and fake devices;
their implementation and execution evidence stay in the host repositories. Validating
this data or a report envelope does not mean that the host passed every scenario.

## Execution interface

Each scenario supplies instances, logical controls, parameters, page bindings, permissions
and a bounded journal capacity. IDs such as `axis.input` / `axis.display` are opaque endpoint
roles. Each adapter maps them to its real fake-device APIs and independently records the
actual effects. Naming an output `axis.display` is not evidence of independent hardware
addressing: T03 requires actual input/output map or emitted-byte evidence. A device whose
protocol fixes both directions to the same address can lack `independent_io_addresses`.

An executor constructs isolated real host runtime/fake-device objects from setup, then
executes each operation's arguments in order. It may retain an actual immutable output
plan until `flush`; it may not replace the host's policy with a new ideal state machine.
The fixture may only translate neutral IDs to existing local APIs, inject a fake clock or
device/transport failure, and collect real state and effects. It must not introduce its own
permission check, queue, deduplication rule, connection reducer or authority reducer to make
an expectation true. T21 must call the real GUI undo path: if there is no product motor-
permission entry point, a fixture Boolean must not intercept the call. Record actual output
as a failure when it violates the expectation. Missing product safety wiring is not NA.
T27 likewise cannot gain an ideal authority model inside the executor.
No operation invokes an old test by name. The fixture contains no host MIDI address or
Swift test name. All `source=hardware` instances are test doubles, never physical devices.

Operations cover input/batch input, absolute turning/relative repetition, parameter writes,
display/motor plans and transport results, touch, software pages/hardware contexts, route
replacement, permissions, preset transactions, save/restart/restore/undo, isolated simulation
feedback/reset, remote requests with response loss, journal overflow, touch continuity,
injected time, authority rejection and endpoint provenance. Closed argument shapes and
allowed metric names are in `docs/controller-regression.schema.json`.
Numeric arguments use the configured test parameter/display desired-value space; they are
not assumptions about device wire encoding. Adapters use the existing native projection API.
The real sent_value metric stays in the device's own cache/wire unit.

Motor setups keep both physical fader controls, but bind only fader1 to p1 by default.
Only T17 binds fader2 to that same parameter: shared-parameter propagation is its explicit
subject, not an implicit precondition for every touch case. T13 still checks global context
motion against a touched fader2 even when that control has no parameter binding.

Every expect entry selects a metric in the addressed instance's real before/after state.
An optional expect.instance_id checks another instance during that operation. Equality,
unchanged, increased, increased_by and at_least are checked by the shared validator. Count
metrics are cumulative fake-transport observations, not attempted logical plans. Received
but transport-rejected writes still count as calls; accepted_transport_count counts only
accepted calls. An effect can have multiple kinds, e.g. a context-selection command with
motor side effects has both `context` and `motor`. Output counters are recomputed against
the per-step effect trace whenever those metrics are present.

T14 retains desired value 64 in both operations, but sent_value uses the device's actual
local transmitted/cache unit. The second step requires that real sent_value remain unchanged
and value_projection_output_count increase. This new count includes only actual transport-
accepted value-projection messages; style-only messages and rejected attempts do not count.
Each such effect has both display and value_projection kinds. The existing call counters
keep their original semantics. The executor reads the real native cache and classifies real
effects; it must not construct a semantic sent-cache from the requested or expected value.

T07/T08 require prepared_motor_plan_count >= 1 before the race and, after the actual product
filter, revoked_motor_plan_count >= 1 plus zero motor output. The first count comes from
actual generated motor messages. The revoked count is the motor multiset difference between
actual filter input and returned output, preserving duplicate-message multiplicity. These
are plan observations, not I/O effects; do not add them to transport counters. Preserve raw
generated plans, filter input/output and final fake-device TX for independent supervision.

The validator checks these two plan metrics' structure and their declared expectations;
it does not reconstruct plans from the transport-only effects array. Its output explicitly
marks plan_evidence_verification=supervisor_raw_required. Supervision must compare the raw
plans and actual API calls before accepting these scenarios.

Semantic deferred intent is separate from the revoked concrete send plan. T07 no longer
requires pending_motor_count=0: the existing KRegressionTests.swift:15–33 asserts that T07/T08
produce no permitted motor feedback while isMotorPending remains true. ARCH_MEMO 9.2–9.3 and
INV-05 permit a still-valid deferred intent while blocking the touched motor; later release
must recheck its current context. Keep the real pending observation in the report. This
corrects the draft fixture's extra assumption, not a controller product defect. Preserve the
original X-Touch 9332…a319 report/raw (22 pass / 5 fail / 3 NA) as the pre-correction evidence. T21,
T27 and T30 retain their original failure expectations and real behavior evidence.

T29 alone starts p1 at 0 and p2 at 96, so reusing the old page cannot accidentally produce
the same display as the new page. Its existing expectations are unchanged: no hardware
context-selection output, the same observed hardware context, and a correct display plan.
display_plan_valid must verify the actual new axis-to-p2 binding, actual parameter value,
and a nonempty value projection produced by the existing product render path and codec.
An address-only check, a fixed zero write, or a vacuous allSatisfy on an empty list is not
evidence. Preserve the original 7a59 candidates; if the actual render path cannot produce
the correct new-page projection, report the real failure and do not add a fixture renderer.

T18 must compare real GUI/remote authorization paths and MIDI results; the value can still
change locally while output remains suppressed. authorization_rules_equal cannot be a
literal true. T24 uses an isolated simulation/mock instance so an action really executes before
the response is lost. The existing GUI/mock Agent remote tools are allowed; the surface-control
simulator need not grow action mapping. The companion host report must name the actual tool,
successful dispatch evidence, exact response-loss boundary and existing SDK low-level transport
API. Hardware refusal or unsupported_mapping is not successful action evidence. T24 checks
uncertainty, one action and no automatic replay. If T27
has no external-authority-to-UI connection, retain a real fail with current-state evidence;
do not fabricate an authority adapter merely to make the expected metric true.

## Applicability and results

Only missing physical/protocol features can justify not_applicable. The feature vocabulary
is closed. Missing executor code, GUI plumbing, authority integration or provenance handling
is a fail/unfinished implementation, not a missing physical feature. A host declares its
actual supported features once; the validator rejects unsupported NA claims.

T25 always executes journal overflow. Its separate touch-continuity step requires `motor`:
a device without motors records only that step as not_applicable and still must run the
journal step. A passing scenario can therefore have an explicit step-level NA reason; it
cannot mark all of T25 NA. T07–T17's motor-specific scenarios can be entirely NA on a device
without motors. Do not change product behavior to suppress a reported difference.

The result schema is `docs/controller-regression-results.schema.json`. A report identifies
the fixture SHA256, host revision, host ID, fake-only qualification and feature set. It has
exactly 30 ordered results. Every applicable result records all ordered steps with index,
operation, pass/not_applicable/fail, reason, observations before/after keyed by instance,
and actual fake-device effects. Pass records have null reasons; failures and physical-feature
NA records have explicit reasons. Missing metrics, skipped operations, wrong fixture hashes,
false pass assertions and output counts inconsistent with effects are rejected.

```sh
python3 -B scripts/validate_controller_regression.py
python3 -B scripts/validate_controller_regression.py --report PATH/TO/HOST-RESULTS.json
```

The checker uses only the Python standard library. The two closed schemas also pass the
existing development environment's Draft 2020-12 schema checker. CLI exit 0 means **report
validation** succeeded; the separate conformance field is fail whenever the result contains
failed scenarios. Reports and the final 30×2 table must preserve those failed rows. They are
not silently converted to success by a valid JSON envelope or a successful runner process.
