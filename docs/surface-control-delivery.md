# Host delivery manifest: common fields

A host that delivers a surface control simulator writes `manifest.json` at the root of the
delivery. The fields below have the same names and meanings in every host, so one consumer
loader works without host-specific cases. This is a documentation convention; the shared package
does not generate manifests. The optional integration loader checks the common version/source/dirty
fields and every delivery file hash before importing an SDK. Hosts may add private fields, and consumers ignore fields
they do not know.

| Field | Type | Meaning |
| --- | --- | --- |
| `schema_version` | integer | Version of this field convention. Currently `1`. |
| `artifact` | string | Kind of delivery, for example `surface-control-simulator`. Not a host or product name. |
| `surface_control_contract` | string | Contract version the host serves, for example `"1.3"`. |
| `surface_control_sdk` | string | Version of the SDK in the delivery, for example `"1.3.0"`. |
| `source` | string | Always `"simulation"` for these deliveries. |
| `source_commit` | string | Full 40-character host commit the delivery was built from. |
| `source_dirty` | boolean | True when the host tree had uncommitted changes. A release delivery has `false`. |
| `profile_id` | string | Profile ID of the delivered demonstration configuration. |
| `profile_version` | string | Its profile version. |
| `mapping_revision` | string | Its mapping revision (16 lowercase hex digits, see [surface-control.md](surface-control.md)). |
| `surface_plugins_revision` | string | Full commit of the locked shared package. |
| `files_sha256` | object | Delivery-relative path to SHA-256 for every delivered file except `manifest.json`. |
| `surface_plugins_files_sha256` | object | Shared-package path to SHA-256 for every shared source file the delivery copies. |

Rules:

- `files_sha256` must include the SDK zip `surface-control-sdk-<surface_control_sdk>.zip` and
  `control-contract.json`. Paths are relative, use `/`, and contain no `..`.
- The SDK zip holds `surface_control/__init__.py`, byte-identical to the shared
  `clients/python/surface_control/__init__.py`. Its hash is the
  `surface_plugins_files_sha256` entry for that shared path, so a consumer can verify the zip
  member without a separate field.
- `surface_plugins_files_sha256` keys are paths inside the shared package at
  `surface_plugins_revision` (for example `docs/surface-control-tools.json`,
  `fixtures/surface-control-software-v1.3.json`). Every copy in the delivery is byte-identical.
- `profile_id`, `profile_version`, and `mapping_revision` describe the configuration the delivery
  starts by default. A running instance is still pinned through `surface_control_discover`; a
  different configuration yields a different revision there.
- Consumers pin the SHA-256 of `manifest.json` itself out of band, then check every
  `files_sha256` entry before using any file.
- Integration examples (`integrations/`) and SDK tests are not part of a generic delivery.

Before selecting consumer hold and renewal periods, see
[Choosing hold and renewal periods](surface-control.md#choosing-hold-and-renewal-periods).

Private fields in use today (not part of the convention, shown so consumers do not rely on them):
platform, architecture, build configuration, start/stop protocol notes, and a host's own
provider contract fields.

A host may deliver another manifest for a separate consumer surface. The common fields must
still be present in root `manifest.json`. In particular, the BCR delivery's Provider 1.0
manifest includes them alongside its provider fields; `surface-control-manifest.json` is an
additional file. A generic consumer selects and pins `manifest.json` in either host.

Principal registry files are private host startup configuration. They must never be copied into
a delivery, `files_sha256`, SDK zip, or public manifest. Their writer IDs identify host-owned
principals, not credentials or individual clients sharing the same credential.

## Unified delivery root and index (convention 1)

Packagers accept a delivery root; this workspace uses `../deliveries/` (outside all three
repositories). A directory is named `<host>-surface-<contract>-<source_commit[:7]>`, where
`host` is the packager's stable lowercase ASCII identifier (`[a-z0-9-]+`), contract is the
served major.minor, and the commit is lowercase hexadecimal. A directory already owned by a
different **full** host commit must never be replaced, even if the seven-character prefix
collides. Build into a temporary sibling and publish only after all file hashes are complete.
A directory for the same full commit may be rebuilt atomically; readers must verify the
manifest hash and must fail closed during replacement rather than use partial files.

`INDEX.json` is a UTF-8 JSON object with `schema_version: 1` and `deliveries: [...]`. Each entry
has these required fields (no credentials, private principal files, or absolute paths):

| Field | Type | Meaning |
| --- | --- | --- |
| `host` | string | Stable packager identifier used in the directory name. |
| `path` | string | Directory name relative to this root; one component, no `..`. |
| `manifest_sha256` | string | 64 lowercase hex SHA-256 of the final root `manifest.json` bytes. |
| `contract_version` | string | Manifest `surface_control_contract`. |
| `sdk_version` | string | Manifest `surface_control_sdk`. |
| `source_commit` | string | Full 40-character host commit. |
| `surface_plugins_revision` | string | Full locked shared-package commit. |
| `profile_id` | string | Manifest profile ID. |
| `profile_version` | string | Manifest profile version. |
| `generated_at` | string | UTC RFC 3339 timestamp, ending in `Z`. |

The unique replacement key is `(host, source_commit, contract_version)`. Rebuilding that key
replaces its entry; never append a duplicate. Sort entries by that key. Preserve unrelated
entries, including another host's concurrent publication. Malformed indexes and duplicate
keys are errors, not an excuse to recreate an empty index.

All cooperating packagers use **the same exclusive directory lock** `<root>/.index.lock`,
acquired with atomic `mkdir` before reading INDEX or publishing a delivery. Wait a bounded
period, then report lock contention. Never remove a lock owned by another process or infer
that it is stale from age alone; crash recovery requires an operator to check its owner.
The lock holder checks directory ownership, publishes the complete directory, rereads and
updates the index, writes a temporary sibling index, flushes it, and uses atomic replacement
for `INDEX.json`. Release the lock in `finally`. This whole read/modify/publish sequence is
serialized across hosts; atomic index replacement alone does not prevent lost updates.
The shared package documents this convention; it neither generates nor validates the index.

## Conformance files in a generic delivery

In addition to the existing SDK, schema and fixtures, include:

- The byte-identical `clients/python/surface_conformance/` Python package beside
  `surface_control/` inside the SDK zip, so `python3 -m surface_conformance` works after extraction.
- `conformance-roles.json`, the host's public role mapping described in
  [surface-control-conformance.md](surface-control-conformance.md).
- The byte-identical report schema `docs/surface-control-conformance-report.schema.json` and
  usage document `docs/surface-control-conformance.md`.

Hash these copies through the same `files_sha256` and `surface_plugins_files_sha256` rules.
Role mappings are host-owned; their bytes belong in `files_sha256` only. Live checker reports
are verification evidence generated after packaging, kept outside the immutable delivery.
