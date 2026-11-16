# Versions and consumer pins

These rules collect the existing [control contract](surface-control.md), its
[1.1](surface-control.md#contract-11-changes), [1.2](surface-control.md#contract-12-changes),
and [1.3](surface-control.md#contract-13-changes) changes, and the
[delivery convention](surface-control-delivery.md). They do not create a release or add a
compatibility guarantee beyond those documents.

| Identifier | Meaning and owner | When it changes |
| --- | --- | --- |
| `contract_version` | Wire behavior, declared by the shared contract; currently default simulation `1.3`, default hardware `1.4`, or explicit capability mode `1.5`. Hosts adopt the shared revision explicitly. | Optional, capability-discovered additions use a new minor. Required identity or input interpretation changes require a new major. |
| `schema_version` | The schema/envelope convention of the document carrying it, owned by that document's specification. Discovery and protocol scenario schemas remain `1`. | It is independent of contract minor versions: additive 1.1–1.3 changes did not change it. A manifest, scenario, role map, or report's schema number must be interpreted in its own context. |
| SDK version | Python client implementation version, owned by this package; currently `1.5.0`. | Changes to the SDK are versioned separately from a host profile. SDK 1.3.0 explicitly supports contract 1.0/1.1/1.2/1.3; this is an allowlist, not permission to accept unknown future versions. |
| Profile `id` / `version` | Host-owned declaration of a concrete layout and interpretation. | Hosts deliberately version their profiles when adopting interpretation/capability changes. The 1.3 adoption explicitly updates profile versions and capability allowlists. There is no universal profile shared by all hosts. |
| `mapping_revision` | Content-derived 16-hex FNV-1a mapping digest, computed by the shared algorithm and verified by SDK 1.1+. | Mapping-relevant control fields change it. Profile ID/version, capabilities, and control order do not. A changed context still rotates epoch even if its mapping hash stays the same. |
| Instance / epoch | Host-issued runtime identity fences, not release versions. | Restart changes instance identity. Source, mapping, configuration, mode, or binding interpretation changes rotate epoch. Reset also changes epoch and clears counters/history. |

The mapping algorithm and exact field serialization are defined in
[Contract 1.1 changes](surface-control.md#contract-11-changes). Contract 1.2 adds optional
`accepts_input` to that content: omission retains the prior mapping hash. Hash equality does
not establish profile identity or permission; consumers pin all expected identity fields.
Independent CAS and writer capabilities alone do not change the hash.

An optional addition is gated by a discovered capability and preserves previous requests'
meaning. Examples are hold leases in 1.1, omitted feedback CAS in 1.2, and independent input
CAS in 1.3. New requests/fields sent to an older host are rejected by its strict parser.
An older SDK can reject a newer host at discovery even when the wire addition preserves old
requests: its contract allowlist must be deliberately upgraded. In particular, frozen SDK
1.1.0 and 1.2.0 rejecting contract 1.3 is their actual version gate; do not rewrite a host's
advertised version or alter a frozen SDK to claim a successful compatibility round trip.

Consumers should explicitly allowlist contract versions, profile IDs and versions, encodings,
required capabilities and role mappings, then pin discovery's complete identity for writes.
For delivered programs, pin the root manifest SHA-256 out of band, verify its file hashes,
and record the full host commit, locked shared commit, SDK version, profile version and
mapping revision. A moving branch name, a matching layout name, or an input snapshot alone
is insufficient evidence of an accepted fresh input. Follow the existing
[consumer guidance](surface-control.md#consumer-guidance) for cursors, clock conversion,
unknown outcomes, and explicit recovery; version upgrades never authorize replaying a write.

## Contract 1.4 / SDK 1.4.0

Hardware sessions use 1.4; simulation sessions continue using 1.3. SDK 1.4.0 keeps the existing
1.0–1.3 simulation allowlists and behavior and accepts hardware only through explicit opt-in.
It never sends input, renew or reset methods on hardware. Prior SDKs reject hardware / 1.4.
Profile IDs and versions remain host-owned, and hardware qualification remains per delivery.

| SDK | Simulation contracts | Hardware contracts |
| --- | --- | --- |
| 1.4.0 | 1.0, 1.1, 1.2, 1.3 | 1.4 with explicit hardware opt-in |

## Provider 1.0 frozen tool set and additive tools

Provider 1.0 freezes the names, schemas and error semantics of its existing tools.
Adding registered tools preserves compatibility; a change in the total number returned by
`tools/list` does not by itself change the frozen tools or require a new Provider version.
Tools for an optional capability must appear only when that capability is explicitly enabled.
The default startup catalog and the increment from each capability must have black-box tests.

The BCR host owns the exact frozen set of 25 tools and the registry of additions. Its delivery
must include the frozen descriptors and their SHA-256 hashes, the registered additions and
their activation conditions, and a read-only catalog check. That check compares the frozen
descriptors byte for byte using the documented deterministic JSON encoding and refuses any
unregistered tool or unexpected optional increment. Consumers pin the delivery manifest and
run this check before replacing a previous Provider delivery. Schema and SDK ZIP equality
alone does not verify the runtime catalog or error semantics; existing error regression tests
remain required.

The workspace compatibility ruling is:

> Provider 1.0 的冻结范围是已有工具的名字、Schema、错误语义；新增工具属于加法，不破坏兼容。
> 加法须登记且可核对，仅对应显式开启能力的工具在该能力启用时才出现。

This ruling does not permit changing an existing tool's behavior, hiding a changed descriptor
behind the same name, or changing any already published attachment.

## Explicit contract 1.5 / SDK 1.5.0

Only profiles explicitly enabling `events.input_retention` and/or hardware-only
`session.owned_virtual_rehearsal` declare 1.5. Default discovery, tools and behavior stay
simulation1.3/hardware1.4. Schema1 and mapping content rules remain unchanged. Hosts explicitly
adopt a profile version and new epoch; an old client can reject1.5 without changing old requests.

| SDK | Simulation contracts | Hardware contracts |
| --- | --- | --- |
| 1.5.0 | 1.0, 1.1, 1.2, 1.3, explicit 1.5 | 1.4, explicit 1.5; both require hardware source opt-in |

`InputEventCursor` is explicit and capability-gated; it does not replace `EventCursor` or relax
`BinaryRoleCursor`. SDK1.4's complete source and original version assertion are retained as
test-only fixtures, excluded from runtime SDK archives. New1.5 tests supplement the unchanged
old version behavior matrix and hardware tests. Old published SDK ZIPs/tags/fixtures/attachments
are never rewritten to advertise support for1.5. A main commit is not a tag or release.
