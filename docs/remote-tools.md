# Shared remote bindings

Each binding product imports only its own plugin and RemoteToolContracts. The registry owns
one value per instance. Hosts send clock/hardware/UI inputs through
`registry.handle(instanceID:input:at:)`; trusted typed operations use
`binding(id, as: AgentRemoteBinding.self)` (or Robot/Chassis/OutputRemoteBinding), mutate its
public `plugin`, then `replace(binding, at: hostTime, event: PluginEvent(code: stableOperationCode))`. Never keep a second mutable plugin in a GUI model.
Registry installation accepts one binding or an array and commits atomically. Same-plugin
instances require identical manifest/surface/tool descriptors; all identifiers remain instance
scoped. Different plugins cannot collide even through nested namespaces. Contract 1.0 is required.

Initialize with `try RemoteRegistry(epoch: hostSessionUUID, eventCapacity: 256)`.
`tools` includes capabilities/events and only installed plugin tools. Every descriptor contains
explicit inputSchema/outputSchema/isMutation. Hosts register these descriptors with their
transport and forward calls to the shared binding, without duplicating parsing or domain switches.

All instance tools require a nonempty `instance_id` string. Input schemas reject extra keys,
wrong types, fractional integers, nonfinite numbers, and oversized vectors. Integers retain all
Int bits. Output schemas describe typed result fields and nullable observations. Stable errors
are RemoteFailure(code, fields); simulation errors retain legacy code with reasonKey in fields.

| Tools | Additional required fields |
| --- | --- |
| surface_capabilities | none; arguments must be empty object |
| surface_events | epoch:string, after:decimal cursor string, limit:integer 1...65536 |
| surface_agent_snapshot | none |
| surface_agent_primary / surface_agent_interrupt | slot:integer |
| surface_robot_snapshot / surface_robot_trace | none |
| surface_robot_initialize | generation:string, joints_rad:number array |
| surface_robot_acquire | generation:string, owner:string, ttl_s:number |
| surface_robot_enable / release / stop | generation:string, control_token:string, sequence:integer |
| surface_robot_renew | proof fields above, ttl_s:number |
| surface_robot_move | proof fields, target_joints_rad:number array, duration_s:number, valid_for_s:number |
| surface_robot_advance | dt_s:number in (0,.1] |
| surface_robot_reset | generation:string |
| surface_chassis_snapshot / trace | none |
| surface_chassis_initialize | generation:string, pose_m_rad:number array |
| surface_chassis_acquire / enable / renew / release / stop / advance / reset | same as robot equivalents |
| surface_chassis_drive | proof fields, speed_m_s:number, steering_angle_rad:number, valid_for_s:number |
| surface_output_snapshot / surface_output_enable / surface_output_disable | none |

Robot/chassis mutations return the complete typed snapshot, except acquire which returns its
new grant. Snapshot never contains tokens; trace returns bounded simulation samples. Remote
advance is explicit simulation stepping, not physical observation. Fault injection is not exposed.
Agent responses contain slots with id/state/progress/status_key/last_updated. Remote primary
uses origin.remote; localOrigins refuses remote approval while retaining hardware/UI approval.
interfaceOnly remains available for true UI-only approval. No call starts a plugin implicitly.

RemoteCallContext(time, controlToken, permitsOutputEnable) is supplied by authenticated hosts.
Only acquire needs a fresh host-generated opaque token; request JSON cannot supply that entropy.
Only authorized output enable sets permitsOutputEnable. Disable immediately evaluates a stop
frame; enable still requires fresh trusted heartbeat/actual and observed off/on. No remote
heartbeat or actual tool exists. Output requests never impersonate observations.

Registry mutation and handle append bounded journal records after successful commit; failed
operations and read-only calls append nothing. Events contain operation codes or explicit state
update codes, never control proofs/tokens. surface_events returns epoch/gap/events/latestSequence.
A cursor older than retained history, from an old epoch, or beyond the newest sequence reports
gap. Slow readers refetch snapshots. Reading events/snapshots never advances clock or replays
inputs. Trusted typed replace commits canonical state and an event atomically. There is no eventless replacement API; trusted typed writes always provide time and event. Failed replacement
commits neither state nor journal. Identifier grammar is `[a-z][a-z0-9_-]*(\.[a-z0-9_-]+)*`
with a complete match, as provided by RemoteRegistry.validIdentifier.

No retry engine is included. If a mutation response is lost, the host reports outcomeUnknown
and clients recover from snapshot/control state; reconnect must not replay side effects.
Transport listeners, authentication, credentials, request identity, and retry policy belong to hosts.
