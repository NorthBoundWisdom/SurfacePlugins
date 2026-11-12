# Contract change history

This is an index of existing documented behavior, not a record of published tags or Releases.
The current contract is 1.3 and Python SDK is 1.3.0. Runtime and consumer guidance remains in
[the contract](docs/surface-control.md); adoption and version pins are described in
[versioning](docs/versioning.md).

## Contract 1.3 — SDK 1.3.0

- Optional independent input CAS adds input highwaters while retaining the single global
  journal and legacy global CAS. Accepted and ignored inputs, including expiry, advance input
  CAS; feedback does not. Reset clears both. SDK adds explicit CAS selection and input refresh.
  [Contract 1.3 changes, item 1](docs/surface-control.md#contract-13-changes).
- Optional trusted host-issued opaque writer IDs attribute remote, interface, and system
  events; callers cannot supply their ID. One shared credential still identifies one remote
  principal. Private principal files are excluded from deliveries.
  [Contract 1.3 changes, item 2](docs/surface-control.md#contract-13-changes).
- Optional independent input/feedback/renew/admin budgets preserve the legacy aggregate limit
  when not enabled. [Contract 1.3 changes, item 3](docs/surface-control.md#contract-13-changes).
- The v1.3 fixture adds independent CAS and writer evidence; the three older fixtures remain
  byte-identical. [Contract 1.3 fixture](docs/surface-control-scenarios.md#contract-13-fixture).

## Contract 1.2 — SDK 1.2.0

- Optional unsequenced feedback omits CAS but still consumes a journal sequence; explicit CAS
  retains prior behavior. `refresh_sequence()` reads state without retrying inputs.
  [Contract 1.2 changes, items 1–2](docs/surface-control.md#contract-12-changes).
- Event pages optionally expose current holds at read time; SDK cursors keep those separate
  from event freshness. [Contract 1.2 changes, item 3](docs/surface-control.md#contract-12-changes).
- Optional `accepts_input` declarations are capability-consistent, truthful, and included in
  mapping content; absent declarations preserve legacy meaning/hash.
  [Contract 1.2 changes, item 4](docs/surface-control.md#contract-12-changes).
- The v1.2 fixture adds feedback interleaving, explicit refresh, page holds and non-input
  control evidence. [Contract 1.2 fixture](docs/surface-control-scenarios.md#contract-12-fixture).

## Contract 1.1 — SDK 1.1.0

- Deterministic content-derived mapping revisions, mapping-before-epoch validation, and the
  shared capability vocabulary replace the earlier host declarations.
  [Contract 1.1 changes, items 1–3](docs/surface-control.md#contract-11-changes).
- Numeric normalization and `isUnchanged` align accepted input/feedback bookkeeping.
  [Contract 1.1 changes, item 4](docs/surface-control.md#contract-11-changes).
- Optional hold inputs, silent renewal, scheduled rest restoration, and pending-expiry
  fail-closed behavior add the seventh tool and optional response fields.
  [Contract 1.1 changes, items 5–6](docs/surface-control.md#contract-11-changes).
- The v1.1 fixture retains v1.0 scenarios and adds lease lifecycle/fail-closed evidence.
  [Fixture definitions](docs/surface-control-scenarios.md).

## Contract 1.0

- Initial optional simulation control discovery, profile identity, typed input, separate
  display feedback, bounded event journal and authorized reset. Global decimal CAS, monotonic
  clock fences and copy/validate/commit atomicity keep rejection paths from changing state.
  [Base contract](docs/surface-control.md).
- Initial standard-library SDK and software fixture distinguish input evidence from state
  snapshots and feedback. [Fixture definitions](docs/surface-control-scenarios.md).
