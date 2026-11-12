# Surface-driven device scenarios

`SurfaceDeviceScenarioTests` is an independent SwiftPM test target. Its resource is
`Tests/SurfaceDeviceScenarioTests/Fixtures/device-scenarios.json`, separate from the four
public host-protocol fixtures in `fixtures/`. Hosts must not package this resource as a
public surface protocol or a consumer role map. No production core or host mapping changes.

The test consumer gives neutral controls business meaning, then drives real AgentPlugin,
RobotPlugin, ChassisPlugin and ParameterOutputPlugin values. Every operator request goes
through `SurfaceControlTools.parse` and `SurfaceControlSession.validateInput`; a value copy
records the accepted/ignored event, applies its consumer mapping, and commits both states.
Feedback goes through the real feedback parser/session and never enters the input mapping.
Initialization, device grants, and output heartbeat/actual injection are trusted fixture setup
or explicitly named fixture operations, not remote control tools or display-derived telemetry.

The clock is injected. Before each operation the consumer advances real models and scheduled
surface expiries to that time; it stops at the lease boundary before integrating the remaining
interval. No sleeps, callbacks, I/O to devices, containers or consumer project code are involved.
After this clock advancement, `commands_unchanged` compares the operation's own effect with
`commands_before_operation`; model integration and periodic output evaluation remain visible
in the total command count. This keeps “display does not execute a command” separate from
normal clock-driven movement and output evaluation.

| Scenario | Steps | Evidence |
| --- | --- | --- |
| Agent | 8 | Surface primary → queued → injected advance → running; authoritative progress feedback; surface stop → interrupted; duplicate and old-epoch requests do not replay actions |
| Reference robot | 10 | Target differs from unchanged actual at command commit; actual advances; actual-derived display preserves input; stop revokes enable and brakes before actual becomes stationary |
| Chassis | 17 | Surface enable lease expires before the longer device grant/command TTL; system expiry restores rest and revokes enable; actual brakes to zero; blocked rearm until rest and centered axis; disconnect and duplicate events cannot resume movement |
| Output gate | 16 | Surface enable without actual refuses an enabled frame; forged display feedback does not supply actual; trusted samples alone cannot bypass off/on; centered rearm starts exactly at actual; limits bound motion; heartbeat loss/disconnect revoke output |

Run and emit a machine-readable report:

```sh
SURFACE_DEVICE_SCENARIO_REPORT="$PWD/build/device-scenarios.json" \
  swift test --build-path build/swiftpm --filter SurfaceDeviceScenarioTests
```

The report has simulation source, contract version, a result for each scenario and each step,
global/input highwaters, server time, target/actual values, model/safety status, and explicit
pass flags. Unknown actuals serialize as null. No grants, tokens, credentials or private
principal records are serialized. CI runs this target as part of `swift test` on macOS/Linux
and writes its report under ignored `build/`. The report's four scenario results cover 51 steps;
they are one XCTest case, not 51 separately counted tests.

These deterministic software scenarios verify a test consumer and the shared real device
models. They are not evidence of a host HTTP route, a Pipe Worker workflow, another project's
adoption, or physical device qualification. Host transport/fixture evidence and the consumer's
own integration report remain separate acceptance work.
