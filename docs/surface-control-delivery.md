# Host delivery manifest: common fields

A host that delivers a surface control simulator writes `manifest.json` at the root of the
delivery. The fields below have the same names and meanings in every host, so one consumer
loader works without host-specific cases. This is a documentation convention; the shared package
does not generate or check manifests. Hosts may add private fields, and consumers ignore fields
they do not know.

| Field | Type | Meaning |
| --- | --- | --- |
| `schema_version` | integer | Version of this field convention. Currently `1`. |
| `artifact` | string | Kind of delivery, for example `surface-control-simulator`. Not a host or product name. |
| `surface_control_contract` | string | Contract version the host serves, for example `"1.1"`. |
| `surface_control_sdk` | string | Version of the SDK in the delivery, for example `"1.1.0"`. |
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
  `fixtures/surface-control-software-v1.1.json`). Every copy in the delivery is byte-identical.
- `profile_id`, `profile_version`, and `mapping_revision` describe the configuration the delivery
  starts by default. A running instance is still pinned through `surface_control_discover`; a
  different configuration yields a different revision there.
- Consumers pin the SHA-256 of `manifest.json` itself out of band, then check every
  `files_sha256` entry before using any file.
- Integration examples (`integrations/`) and SDK tests are not part of a generic delivery.

Private fields in use today (not part of the convention, shown so consumers do not rely on them):
platform, architecture, build configuration, start/stop protocol notes, and a host's own
provider contract fields.
