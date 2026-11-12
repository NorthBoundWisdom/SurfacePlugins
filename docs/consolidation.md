# Consolidation assessment

The shared products now contain plugin contracts, deterministic Agent state, robot/chassis
simulation, common device control, output codecs and motion gate, explicit example data,
independent remote bindings, a value registry and a bounded event journal. No umbrella product
or inter-plugin import is present. Hosts preserve compatibility through adapters and own their
configuration, layout, bindings, device feedback, transports, credentials and physical protection.

One registry owns each live plugin instance. Its generic handle path serves clocks, hardware,
UI and semantic actions; trusted typed writes commit both state and events atomically. There
is no untimed replace API, hidden remote shadow, or implicit retry engine. Explicit event:nil
commits keep an independent monotonic write clock without filling history with bookkeeping. Simulation stop
preserves pending braking and remote writes honor the same lifecycle. Actual and heartbeat
remain authenticated host inputs, never motion-request echoes.

Further console-engine sharing is not justified by this migration. The hosts retain materially
different input interpretation, layouts, feedback scheduling and protection rules. Moving those
systems would add compatibility risk without a demonstrated common implementation. Any future
extraction should begin with separately evidenced duplicate behavior and a separate plan.

Remaining host-specific adapters are intentional compatibility boundaries, not plugin forks.
The small robot/chassis semantic wrappers retain explicit typed stop and observation rules;
there is no reason to introduce another public abstraction solely to remove their few repeated
lines. Shared device control, schemas, registry and event behavior already have both consumers.

Release preparation uses exact Git commit locks and managed build inputs. The reviewed implementation has been pushed to all three main branches under explicit user authorization. Version tags and releases remain a separate decision. Local
macOS software checks do not qualify physical devices; Linux and cross-host integration have
separate evidence maintained by supervision and each host's handoff records.
