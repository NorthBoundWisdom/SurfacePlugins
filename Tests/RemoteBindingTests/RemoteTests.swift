import Foundation
import XCTest
import SurfacePluginContracts
import RemoteToolContracts
import AgentPlugin
import AgentRemoteBinding
import RobotPlugin
import RobotRemoteBinding
import ChassisPlugin
import ChassisRemoteBinding
import ParameterOutputPlugin
import OutputRemoteBinding

final class RemoteTests: XCTestCase {
    func agent(policy: AgentApprovalPolicy = .localOrigins) throws -> AgentRemoteBinding {
        var plugin = try AgentPlugin(slotCount: 2, approvalPolicy: policy)
        _ = try plugin.handle(.start, at: 0)
        return .init(instanceID: "agent", plugin: plugin)
    }
    func args(_ fields: [String: JSONValue] = [:], id: String = "agent") -> JSONValue { .object(fields.merging(["instance_id": .string(id)]) { _,new in new }) }
    func testUniqueValueClockHardwareRemoteAndPureSnapshot() throws {
        var r = try RemoteRegistry(epoch: "test"); try r.install(agent())
        _ = try r.call("surface_agent_primary", arguments: args(["slot": .number(1)]), context: .init(time: 0))
        _ = try r.handle(instanceID: "agent", input: .advance, at: 3)
        let before = try XCTUnwrap(r.binding("agent", as: AgentRemoteBinding.self))
        XCTAssertEqual(before.plugin.slots[0].state, .waitingApproval)
        let snapshot = try r.call("surface_agent_snapshot", arguments: args(), context: .init(time: 999))
        XCTAssertEqual(r.binding("agent", as: AgentRemoteBinding.self)?.plugin.slots, before.plugin.slots)
        XCTAssertThrowsError(try r.call("surface_agent_primary", arguments: args(["slot": .number(1)]), context: .init(time: 999)))
        _ = try r.handle(instanceID: "agent", input: .invoke(.init(pluginID: "agent", actionID: "agent.primary", index: 1), origin: .hardware), at: 4)
        XCTAssertEqual(r.binding("agent", as: AgentRemoteBinding.self)?.plugin.slots[0].state, .running)
        XCTAssertNotEqual(try r.call("surface_agent_snapshot", arguments: args(), context: .init(time: 4)), snapshot)
    }
    func testApprovalOriginMatrix() throws {
        for policy in [AgentApprovalPolicy.anyOrigin, .localOrigins, .interfaceOnly] {
            for origin in [InputOrigin.hardware, .interface, .remote] {
                var b = try agent(policy: policy)
                _ = try b.plugin.handle(.invoke(.init(pluginID: "agent", actionID: "agent.primary", index: 1), origin: .interface), at: 0)
                _ = try b.plugin.handle(.advance, at: 3)
                let input = PluginInput.invoke(.init(pluginID: "agent", actionID: "agent.primary", index: 1), origin: origin)
                let allowed = policy == .anyOrigin || (policy == .localOrigins && origin != .remote) || origin == .interface
                if allowed { XCTAssertNoThrow(try b.plugin.handle(input, at: 4)) }
                else { XCTAssertThrowsError(try b.plugin.handle(input, at: 4)); XCTAssertEqual(b.plugin.slots[0].state, .waitingApproval) }
            }
        }
    }
    func testRegistryConflictsAndInvalidInputsAreAtomic() throws {
        var r = try RemoteRegistry(epoch: "test"); try r.install(agent())
        let before = try r.capabilities()
        XCTAssertThrowsError(try r.install(agent())); XCTAssertEqual(try r.capabilities(), before)
        for invalid in [args(["slot": .number(1), "extra": .bool(true)]), args(["slot": .double(.nan)]), .object(["slot": .number(1)])] {
            XCTAssertThrowsError(try r.call("surface_agent_primary", arguments: invalid, context: .init(time: 99)))
        }
        XCTAssertThrowsError(try r.call("unknown", arguments: args(), context: .init(time: 99)))
        _ = try r.call("surface_agent_primary", arguments: args(["slot": .number(1)]), context: .init(time: 0))
        XCTAssertEqual(r.binding("agent", as: AgentRemoteBinding.self)?.plugin.slots[0].state, .queued)
        var replacement = try XCTUnwrap(r.binding("agent", as: AgentRemoteBinding.self))
        _ = try replacement.plugin.interrupt(1, at: 1); try r.replace(replacement, at: 1, event: .init(code: "local.interrupt"))
        XCTAssertEqual(r.binding("agent", as: AgentRemoteBinding.self)?.plugin.slots[0].state, .interrupted)
    }
    func testRobotAcquireUsesHostEntropyAndSnapshotNeverLeaksToken() throws {
        var r = try RemoteRegistry(epoch: "test")
        try r.install(RobotRemoteBinding(instanceID: "robot", plugin: RobotPlugin(instanceID: "robot")))
        _ = try r.handle(instanceID: "robot", input: .start, at: 0)
        let snapshot = try r.call("surface_robot_snapshot", arguments: args(id: "robot"), context: .init(time: 0))
        let generation = try XCTUnwrap(snapshot.objectValue?["metadata"]?.objectValue?["generation"])
        let initialized = try r.call("surface_robot_initialize", arguments: args(["generation": generation, "joints_rad": .array(Array(repeating: .number(0), count: 6))], id: "robot"), context: .init(time: 0))
        let nextGen = try XCTUnwrap(initialized.objectValue?["metadata"]?.objectValue?["generation"])
        let request = args(["generation": nextGen, "owner": .string("fixture"), "ttl_s": .number(1)], id: "robot")
        XCTAssertThrowsError(try r.call("surface_robot_acquire", arguments: request, context: .init(time: 0)))
        let grant = try r.call("surface_robot_acquire", arguments: request, context: .init(time: 0, controlToken: "host-opaque-secret"))
        XCTAssertEqual(grant.objectValue?["control_token"], .string("host-opaque-secret"))
        XCTAssertFalse(try r.call("surface_robot_snapshot", arguments: args(id: "robot"), context: .init(time: 0)).jsonText.contains("host-opaque-secret"))
    }
    func testOutputPermissionAndDisableProducesStopDecision() throws {
        var plugin = try ParameterOutputPlugin(limits: [.init(id: "x", minimum: 0, maximum: 1, maximumChange: 1, maximumVelocity: 1)])
        _ = try plugin.handle(.start, at: 0); plugin.setConnected(true, at: 0); plugin.receiveHeartbeat(at: 0)
        plugin.receiveActual([.init(id: "x", value: 0, receivedAt: 0)]); _ = plugin.evaluate(targets: [:], at: 0)
        var b = OutputRemoteBinding(instanceID: "output", plugin: plugin)
        XCTAssertThrowsError(try b.call("surface_output_enable", arguments: args(id: "output"), context: .init(time: 0)))
        _ = try b.call("surface_output_enable", arguments: args(id: "output"), context: .init(time: 0, permitsOutputEnable: true))
        _ = b.plugin.evaluate(targets: ["x": 1], at: 0)
        _ = try b.call("surface_output_disable", arguments: args(id: "output"), context: .init(time: 0))
        XCTAssertEqual(b.plugin.decision?.command, .init(enabled: false, values: [:]))
    }
    func testEventGapEpochAndPureReads() throws {
        var journal = try RemoteEventJournal(epoch: "session", capacity: 2)
        for i in 0..<3 { try journal.append(instanceID: "agent", event: .init(code: "updated"), at: Double(i)) }
        let page = try journal.read(epoch: "session", after: 0, limit: 2)
        XCTAssertTrue(page.gap); XCTAssertEqual(page.events.map(\.sequence), [2,3])
        XCTAssertEqual(try journal.read(epoch: "session", after: 0, limit: 2), page)
        XCTAssertTrue(try journal.read(epoch: "old", after: 3, limit: 2).gap)
        XCTAssertThrowsError(try journal.append(instanceID: "agent", event: .init(code: "bad"), at: .nan))
        XCTAssertEqual(try journal.read(epoch: "session", after: 0, limit: 2), page)
    }
}

final class DeviceRemoteLifecycleTests: XCTestCase {
    func testEverySimulationToolUsesTypedStateAndSchema() throws {
        for domain in ["robot", "chassis"] {
            var r = try RemoteRegistry(epoch: "test")
            if domain == "robot" { try r.install(RobotRemoteBinding(instanceID: domain, plugin: RobotPlugin(instanceID: domain))) }
            else { try r.install(ChassisRemoteBinding(instanceID: domain, plugin: ChassisPlugin(instanceID: domain))) }
            _ = try r.handle(instanceID: domain, input: .start, at: 0)
            func arguments(_ values: [String: JSONValue] = [:]) -> JSONValue { .object(values.merging(["instance_id": .string(domain)]) { _,new in new }) }
            let prefix = "surface_" + domain + "_"
            let unknown = try r.call(prefix+"snapshot", arguments: arguments(), context: .init(time: 0))
            let initialGeneration = try XCTUnwrap(unknown.objectValue?["metadata"]?.objectValue?["generation"])
            let initialized = try r.call(prefix+"initialize", arguments: arguments(["generation": initialGeneration, domain == "robot" ? "joints_rad" : "pose_m_rad": .array(Array(repeating: .number(0), count: domain == "robot" ? 6 : 3))]), context: .init(time: 0))
            let gen = try XCTUnwrap(initialized.objectValue?["metadata"]?.objectValue?["generation"])
            let grant = try r.call(prefix+"acquire", arguments: arguments(["generation": gen, "owner": .string("fixture"), "ttl_s": .number(5)]), context: .init(time: 0, controlToken: "opaque"))
            let token = try XCTUnwrap(grant.objectValue?["control_token"])
            func proof(_ sequence: Int) -> [String: JSONValue] { ["generation": gen, "control_token": token, "sequence": .number(sequence)] }
            _ = try r.call(prefix+"enable", arguments: arguments(proof(1)), context: .init(time: 0))
            var renewal = proof(2); renewal["ttl_s"] = .number(5)
            _ = try r.call(prefix+"renew", arguments: arguments(renewal), context: .init(time: 0))
            var motion = proof(3)
            motion["valid_for_s"] = .number(1)
            if domain == "robot" { motion["duration_s"] = .number(1); motion["target_joints_rad"] = .array([.double(0.1),.number(0),.number(0),.number(0),.number(0),.number(0)]) }
            else { motion["speed_m_s"] = .double(0.1); motion["steering_angle_rad"] = .double(0.1) }
            _ = try r.call(prefix+(domain == "robot" ? "move" : "drive"), arguments: arguments(motion), context: .init(time: 0))
            _ = try r.call(prefix+"advance", arguments: arguments(["dt_s": .double(0.1)]), context: .init(time: 0))
            _ = try r.call(prefix+"stop", arguments: arguments(proof(4)), context: .init(time: 0))
            for _ in 0..<15 { _ = try r.call(prefix+"advance", arguments: arguments(["dt_s": .double(0.1)]), context: .init(time: 0)) }
            let trace = try r.call(prefix+"trace", arguments: arguments(), context: .init(time: 0))
            XCTAssertFalse(trace.arrayValue?.isEmpty ?? true)
            _ = try r.call(prefix+"release", arguments: arguments(proof(5)), context: .init(time: 0))
            let reset = try r.call(prefix+"reset", arguments: arguments(["generation": gen]), context: .init(time: 0))
            XCTAssertEqual(reset.objectValue?["actual"], .null)
            let before = try r.capabilities()
            var extra = proof(6); extra["entropy"] = .string("client")
            XCTAssertThrowsError(try r.call(prefix+"enable", arguments: arguments(extra), context: .init(time: 0)))
            XCTAssertEqual(try r.capabilities(), before)
            XCTAssertTrue(r.tools.contains { $0.name == "surface_capabilities" })
        }
    }
}

private struct FixtureBinding: RemoteBinding {
    let instanceID: String
    let manifest: PluginManifest
    let surface: SurfaceDescriptor
    let tools: [RemoteToolDescriptor]
    func snapshot() -> PluginSnapshot { .init(isStarted: false) }
    mutating func handle(_ input: PluginInput, at time: PluginTime) throws -> PluginUpdate { .init() }
    mutating func call(_ name: String, arguments: JSONValue, context: RemoteCallContext) throws -> JSONValue { .null }
}
final class RegistryValidationTests: XCTestCase {
    func testBatchSurfaceAndDescriptorConflictsRollback() throws {
        var r = try RemoteRegistry(epoch: "fixture")
        func fixture(_ id: String, _ plugin: PluginID, _ action: ActionID, mutation: Bool = true) -> FixtureBinding {
            .init(instanceID: id, manifest: .init(id: plugin, version: "1", source: .simulation),
                  surface: .init(actions: [.init(id: action, nameKey: "action")]),
                  tools: [.init(name: "surface_fixture", fields: ["instance_id": RemoteSchema.string], output: RemoteSchema.boolean, isMutation: mutation)])
        }
        let a = fixture("a", "alpha", "alpha.beta.action")
        let b = fixture("b", "alpha.beta", "alpha.beta.action")
        XCTAssertThrowsError(try r.install([a,b]))
        XCTAssertTrue(try r.capabilities().objectValue?["instances"]?.arrayValue?.isEmpty == true)
        try r.install(a)
        XCTAssertThrowsError(try r.install(fixture("c", "alpha", "alpha.beta.action", mutation: false)))
        try r.install(fixture("second", "alpha", "alpha.beta.action"))
        XCTAssertEqual(try r.capabilities().objectValue?["instances"]?.arrayValue?.count, 2)
    }
    func testRegistryExposesEventGapAndErrorsDoNotAppend() throws {
        var r = try RemoteRegistry(epoch: "fixture", eventCapacity: 1)
        var p = try AgentPlugin(slotCount: 1)
        _ = try p.handle(.start, at: 0)
        try r.install(AgentRemoteBinding(instanceID: "agent", plugin: p))
        let args: JSONValue = .object(["instance_id": .string("agent"), "slot": .number(1)])
        for time in [0.0, 1.0] { _ = try r.call("surface_agent_primary", arguments: args, context: .init(time: time)) }
        let request: JSONValue = .object(["epoch": .string("fixture"), "after": .string("0"), "limit": .number(128)])
        let page = try r.call("surface_events", arguments: request, context: .init(time: 2))
        XCTAssertEqual(page.objectValue?["gap"], .bool(true))
        XCTAssertEqual(page.objectValue?["events"]?.arrayValue?.count, 1)
        _ = try r.call("surface_agent_snapshot", arguments: .object(["instance_id": .string("agent")]), context: .init(time: 999))
        XCTAssertThrowsError(try r.call("surface_agent_primary", arguments: .object([:]), context: .init(time: 999)))
        XCTAssertEqual(try r.call("surface_events", arguments: request, context: .init(time: 2)), page)
        let oldEpoch: JSONValue = .object(["epoch": .string("previous"), "after": .string("999"), "limit": .number(128)])
        XCTAssertEqual(try r.call("surface_events", arguments: oldEpoch, context: .init(time: 2)).objectValue?["gap"], .bool(true))
    }
}

final class IntegerPrecisionTests: XCTestCase {
    func testIntegerArgumentsPreserveAllIntBits() throws {
        let descriptor = RemoteToolDescriptor(name: "surface_integer", fields: ["instance_id": RemoteSchema.string, "sequence": RemoteSchema.integer], output: RemoteSchema.integer, isMutation: true)
        for integer in [9_007_199_254_740_993, Int.max, Int.min] {
            let args = try RemoteArguments(.object(["instance_id": .string("fixture"), "sequence": .number(integer)]), tool: descriptor, instanceID: "fixture")
            XCTAssertEqual(try args.integer("sequence"), integer)
        }
        for bad in [JSONValue.double(1.5), .double(.nan), .double(.infinity)] {
            XCTAssertThrowsError(try RemoteArguments(.object(["instance_id": .string("fixture"), "sequence": bad]), tool: descriptor, instanceID: "fixture"))
        }
    }
}

final class TrustedUpdateTests: XCTestCase {
    func testTypedMutationAndJournalCommitTogether() throws {
        var r = try RemoteRegistry(epoch: "fixture")
        var p = try AgentPlugin(slotCount: 1); _ = try p.handle(.start, at: 0)
        try r.install(AgentRemoteBinding(instanceID: "agent", plugin: p))
        var b = try XCTUnwrap(r.binding("agent", as: AgentRemoteBinding.self))
        _ = try b.plugin.handle(.invoke(.init(pluginID: "agent", actionID: "agent.primary", index: 1), origin: .interface), at: 1)
        try r.replace(b, at: 1, event: .init(code: "local.agent.primary"))
        let request: JSONValue = .object(["epoch": .string("fixture"), "after": .string("0"), "limit": .number(128)])
        let page = try r.call("surface_events", arguments: request, context: .init(time: 1))
        XCTAssertEqual(page.objectValue?["events"]?.arrayValue?.count, 1)
        XCTAssertEqual(page.objectValue?["events"]?.arrayValue?.first?.objectValue?["event"]?.objectValue?["code"], .string("local.agent.primary"))
        _ = try r.call("surface_agent_snapshot", arguments: .object(["instance_id": .string("agent")]), context: .init(time: 999))
        XCTAssertEqual(try r.call("surface_events", arguments: request, context: .init(time: 1)), page)
        _ = try b.plugin.interrupt(1, at: 2)
        XCTAssertThrowsError(try r.replace(b, at: .nan, event: .init(code: "local.interrupt")))
        XCTAssertThrowsError(try r.replace(b, at: 0, event: .init(code: "local.interrupt")))
        XCTAssertEqual(r.binding("agent", as: AgentRemoteBinding.self)?.plugin.slots[0].state, .queued)
        XCTAssertEqual(try r.call("surface_events", arguments: request, context: .init(time: 1)), page)
    }
    func testIdentifierGrammarRejectsWhitespaceEmptyPartsAndTrailingNewlines() throws {
        for id in ["", " ", "agent\n", "Agent", "agent.", "agent..primary", "agent. primary", "agent.primary\n", "agent/primary"] {
            XCTAssertFalse(RemoteRegistry.validIdentifier(id), id)
            var r = try RemoteRegistry(epoch: "fixture")
            let binding = FixtureBinding(instanceID: "fixture", manifest: .init(id: .init(rawValue: id), version: "1", source: .simulation), surface: .init(), tools: [])
            XCTAssertThrowsError(try r.install(binding), id)
        }
        for local in ["agent.", "agent..primary", "agent. primary", "agent.primary\n"] {
            var r = try RemoteRegistry(epoch: "fixture")
            let b = FixtureBinding(instanceID: "fixture", manifest: .init(id: "agent", version: "1", source: .simulation), surface: .init(actions: [.init(id: .init(rawValue: local), nameKey: "name")]), tools: [])
            XCTAssertThrowsError(try r.install(b), local)
        }
        XCTAssertTrue(RemoteRegistry.validIdentifier("agent.slot.1"))
        XCTAssertTrue(RemoteRegistry.validIdentifier("plugin-name_v1.state_2"))
    }
}

final class PublicModelConstructorTests: XCTestCase {
    func testCustomModelsHavePublicTypedConstructors() throws {
        let robot = RobotModel(id: "custom", minimum: [-1], maximum: [1], maximum_speed_rad_s: 1,
                               maximum_acceleration_rad_s2: 2, dh_a_m: [0.2], dh_d_m: [0.1], dh_alpha_rad: [0])
        let chassis = AckermannModel(id: "custom", wheelbase_m: 2, track_m: 1, wheel_radius_m: 0.2,
                                     maximum_speed_m_s: 2, maximum_acceleration_m_s2: 1,
                                     maximum_steering_rad: 0.4, maximum_steering_rate_rad_s: 0.5)
        XCTAssertEqual(try RobotSimulator(model: robot, instanceID: "robot").model.minimum, [-1])
        XCTAssertEqual(try ChassisSimulator(model: chassis, instanceID: "chassis").model.wheelbase_m, 2)
    }
}

final class RemoteLifecycleGateTests: XCTestCase {
    func testPendingAndCompletedStopRejectAllDeviceWrites() throws {
        for domain in ["robot", "chassis"] {
            var registry = try RemoteRegistry(epoch: "fixture")
            if domain == "robot" { try registry.install(RobotRemoteBinding(instanceID: domain, plugin: RobotPlugin(instanceID: domain))) }
            else { try registry.install(ChassisRemoteBinding(instanceID: domain, plugin: ChassisPlugin(instanceID: domain))) }
            _ = try registry.handle(instanceID: domain, input: .start, at: 0)
            func arguments(_ values: [String: JSONValue] = [:]) -> JSONValue { .object(values.merging(["instance_id": .string(domain)]) { _,new in new }) }
            let prefix = "surface_" + domain + "_"
            let initial = try registry.call(prefix+"snapshot", arguments: arguments(), context: .init(time: 0))
            let generation = try XCTUnwrap(initial.objectValue?["metadata"]?.objectValue?["generation"])
            let initialized = try registry.call(prefix+"initialize", arguments: arguments(["generation": generation, domain == "robot" ? "joints_rad" : "pose_m_rad": .array(Array(repeating: .number(0), count: domain == "robot" ? 6 : 3))]), context: .init(time: 0))
            let current = try XCTUnwrap(initialized.objectValue?["metadata"]?.objectValue?["generation"])
            let grant = try registry.call(prefix+"acquire", arguments: arguments(["generation": current, "owner": .string("fixture"), "ttl_s": .number(5)]), context: .init(time: 0, controlToken: "opaque"))
            let token = try XCTUnwrap(grant.objectValue?["control_token"])
            let proof: [String: JSONValue] = ["generation": current, "control_token": token, "sequence": .number(1)]
            _ = try registry.call(prefix+"enable", arguments: arguments(proof), context: .init(time: 0))
            var move = proof; move["sequence"] = .number(2); move["valid_for_s"] = .number(2)
            if domain == "robot" { move["target_joints_rad"] = .array([.number(1),.number(0),.number(0),.number(0),.number(0),.number(0)]); move["duration_s"] = .double(1.5) }
            else { move["speed_m_s"] = .double(0.8); move["steering_angle_rad"] = .double(0.3) }
            _ = try registry.call(prefix+(domain == "robot" ? "move" : "drive"), arguments: arguments(move), context: .init(time: 0))
            _ = try registry.handle(instanceID: domain, input: .advance, at: 0.5)
            _ = try registry.handle(instanceID: domain, input: .stop, at: 0.5)
            XCTAssertEqual(registry.snapshot(instanceID: domain)?.isStarted, true)
            let writes = registry.tools.filter { $0.name.hasPrefix(prefix) && $0.isMutation && $0.name != prefix+"advance" }
            func testWrites(_ r: inout RemoteRegistry) throws {
                for tool in writes {
                    let fields = try XCTUnwrap(tool.inputSchema.objectValue?["properties"]?.objectValue)
                    var input: [String: JSONValue] = [:]
                    for (key, schema) in fields {
                        let type = schema.objectValue?["type"]?.stringValue
                        input[key] = type == "array" ? .array(Array(repeating: .number(0), count: domain == "robot" ? 6 : 3)) : type == "string" ? .string("fixture") : .number(1)
                    }
                    input["instance_id"] = .string(domain)
                    XCTAssertThrowsError(try r.call(tool.name, arguments: .object(input), context: .init(time: 0.5, controlToken: "next-opaque"))) {
                        XCTAssertEqual(($0 as? RemoteFailure)?.code, "stopped", tool.name)
                    }
                }
            }
            try testWrites(&registry)
            for _ in 0..<20 { _ = try registry.call(prefix+"advance", arguments: arguments(["dt_s": .double(0.1)]), context: .init(time: 0.5)) }
            XCTAssertEqual(registry.snapshot(instanceID: domain)?.isStarted, false)
            try testWrites(&registry)
            let stopped = try registry.call(prefix+"snapshot", arguments: arguments(), context: .init(time: 0.5))
            XCTAssertEqual(stopped.objectValue?["stopped"], .bool(true))
            XCTAssertNoThrow(try registry.call(prefix+"trace", arguments: arguments(), context: .init(time: 0.5)))
        }
    }
}
