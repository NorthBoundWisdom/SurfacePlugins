# Pipe integration example (not part of the generic SDK)

`pipe_surface_trial.py` drives a taskless Pipe trial from simulation inputs and writes display
feedback back. It is a consumer-side example: the role names (`arm/start/pause/cancel`) and the
`simulation.*` parameter targets are Pipe trial mappings, not shared contract names.

- It is never packaged into the Surface Control SDK zip or a host's generic delivery.
- The trial process is the owner of its simulation instance (R4-25). It calls
  `surface_control_reset` once, so its credential needs both simulation input permission and
  simulation-admin reset permission. Start a dedicated host instance per trial; never share it.
- It imports the SDK only from a pinned host artifact (`surface-control-sdk-1.1.0.zip`, manifest
  hash checked) and the Pipe tools only as a read-only optional dependency.
- Profile allowlist (`--profile`, repeatable) and host provider identity
  (`--provider-id` with `--provider-header`) are explicit arguments.

Test: `python3 -m unittest discover -s integrations/pipe/tests`.
