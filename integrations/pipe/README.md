# Pipe integration example (not part of the generic SDK)

`pipe_surface_trial.py` drives a taskless Pipe trial from simulation inputs and writes display
feedback back. It is a consumer-side example: the role names (`arm/start/pause/cancel`) and the
`simulation.*` parameter targets are Pipe trial mappings, not shared contract names.

- It is never packaged into the Surface Control SDK zip or a host's generic delivery.
- The trial process is the owner of its simulation instance (R4-25). It calls
  `surface_control_reset` once, so its credential needs both simulation input permission and
  simulation-admin reset permission. Start a dedicated host instance per trial; never share it.
- It imports the SDK only from a pinned host artifact (`surface-control-sdk-1.1.0.zip`, manifest
  hash checked) and the Pipe controller modules only as a read-only optional dependency.

## Usage

```sh
python3 -B integrations/pipe/pipe_surface_trial.py \
  --artifact <host delivery directory containing manifest.json> \
  --manifest-sha256 <sha256 of that manifest.json> \
  --url http://127.0.0.1:<port>/mcp \
  --instance-id <surface control instance id> \
  --token-file <owned 0600 token file> \
  --pipe-package <Pipe checkout>/drivers/bcr_provider \
  --state <owned independent Mock>/state.json \
  --output <fresh directory that does not exist yet> \
  [--protocol 2025-11-25|2026-07-28] \
  [--profile <allowed profile id>]... \
  [--provider-id <id> --provider-header <header name>]
```

- `--pipe-package` is the directory that contains the installable `pipe_bcr_provider` package.
  The script imports `pipe_bcr_provider.controller.trial` and `.bridge`, checks both files were
  loaded from that directory, and records their SHA-256 in the report (rechecked after the trial).
  `ROBIMWELD_PIPE_ROOT` may be needed by Pipe itself if the package is not inside its checkout.
- `--pipe-tools <dir>` is the legacy layout, where `controller_trial.py` itself defines the trial
  functions. On a Pipe checkout whose tools are thin entry points it fails with that reason and
  makes no change. Give exactly one of `--pipe-package` / `--pipe-tools`.
- `--provider-id` and `--provider-header` go together. BCR: `--provider-header BCR-Provider-Id`
  with the provider id from its ready file. XTouch has no provider identity header: omit both.
- `--profile` is the caller's allowlist; omitted, any well-formed profile is accepted.
- `-B` (or `PYTHONDONTWRITEBYTECODE=1`) keeps the Pipe checkout free of `__pycache__` writes; the
  script also sets `sys.dont_write_bytecode`.

## What the profile must provide

Checked after discovery and before the output directory is reserved or anything is reset:

- one control mapped (`mapping.kind: parameter`) to each of `simulation.arm`, `.start`, `.pause`,
  `.cancel` (absolute/scalar or button/boolean), `.state`, `.progress`, `.link`;
- `simulation.state` and `simulation.link` controls declare `indicator` feedback (host 1.1
  profiles give buttons indicator feedback only; the script sends `off`/`on`/`blink`);
- `simulation.progress` declares `value` feedback with a numeric range. Pipe reports progress on
  0..127; the script rescales it to the declared `feedback_range`.

Command inputs use the control's range endpoints (or `true`/`false`). The script does not use
`hold_s`. Failures print a JSON object on stderr; `reason` is present only for this script's own
fixed messages, never for text from a transport or an imported module.

Test: `python3 -m unittest discover -s integrations/pipe/tests`.
