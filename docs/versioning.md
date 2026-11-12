# Versions and consumer pins

These rules collect the existing [control contract](surface-control.md), its
[1.1](surface-control.md#contract-11-changes), [1.2](surface-control.md#contract-12-changes),
and [1.3](surface-control.md#contract-13-changes) changes, and the
[delivery convention](surface-control-delivery.md). They do not create a release or add a
compatibility guarantee beyond those documents.

| Identifier | Meaning and owner | When it changes |
| --- | --- | --- |
| `contract_version` | Wire behavior, declared by the shared contract; currently `1.3`. Hosts adopt the shared revision explicitly. | Optional, capability-discovered additions use a new minor. Required identity or input interpretation changes require a new major. |
| `schema_version` | The schema/envelope convention of the document carrying it, owned by that document's specification. Discovery and protocol scenario schemas remain `1`. | It is independent of contract minor versions: additive 1.1–1.3 changes did not change it. A manifest, scenario, role map, or report's schema number must be interpreted in its own context. |
| SDK version | Python client implementation version, owned by this package; currently `1.3.0`. | Changes to the SDK are versioned separately from a host profile. SDK 1.3.0 explicitly supports contract 1.0/1.1/1.2/1.3; this is an allowlist, not permission to accept unknown future versions. |
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
