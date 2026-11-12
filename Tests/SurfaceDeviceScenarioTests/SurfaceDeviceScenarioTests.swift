import Foundation
import XCTest
import SurfacePluginContracts
import SurfaceControlContracts
import SimulationContracts
import AgentPlugin
import RobotPlugin
import ChassisPlugin
import ParameterOutputPlugin

private struct ScenarioFile: Decodable {
    let schema_version: Int
    let source: String
    let scenarios: [Scenario]
}
private struct Scenario: Decodable { let id: String; let domain: String; let steps: [Step] }
private struct Step: Decodable {
    let at: Double
    let op: String
    let control: String?
    let value: JSONValue?
    let hold_s: Double?
    let expect: [String: JSONValue]
}
private struct ScenarioFailure: Error { let code: String }

/// A test-only consumer, not a production host or second mapping engine. It owns business meaning,
/// model grants and command sequencing; the public control contract owns only accepted raw inputs.
private struct Consumer {
    let domain: String
    var session: SurfaceControlSession
    let initialExpected: ControlExpected
    var agent: AgentPlugin
    var robot: RobotPlugin
    var chassis: ChassisPlugin
    var output: ParameterOutputPlugin
    var grant: DeviceControlGrant?
    var commandSequence = 0
    var commandCount = 0
    var consumed: UInt64 = 0
    var latched = true
    var sawRest = false
    var axis = 0.0
    var now = 0.0
    var trustedActual: Double?
    var lastInput: ControlEvent?
    var expirySystemWriter = false
    var feedbackMatchesActual = false
    let outputID: ParameterID = "scenario.axis"

    init(domain: String) throws {
        self.domain = domain
        let profile = ControlProfile(id: "scenario.controls", version: "1.3", controls: [
            .init(id: "enable", inputKind: .button, encoding: .boolean, mapping: .init(kind: .parameter, id: "consumer.enable"), hold: .init(restValue: .bool(false), maxHoldSeconds: 2), acceptsInput: true),
            .init(id: "axis", inputKind: .absolute, encoding: .scalar, range: .init(minimum: -100, maximum: 100, step: 1), mapping: .init(kind: .parameter, id: "consumer.axis"), acceptsInput: true),
            .init(id: "primary", inputKind: .button, encoding: .boolean, mapping: .init(kind: .action, id: "consumer.primary"), acceptsInput: true),
            .init(id: "stop", inputKind: .button, encoding: .boolean, mapping: .init(kind: .action, id: "consumer.stop"), acceptsInput: true),
            .init(id: "display", inputKind: .absolute, encoding: .scalar, range: .init(minimum: -100, maximum: 100, step: 1), feedbackKinds: [.value, .indicator], acceptsInput: false)
        ], capabilities: ["simulation", "input.button", "input.absolute", "input.hold", "feedback.value", "feedback.indicator", "feedback.unsequenced", "controls.input_declared", "input.independent_sequence", "events.writer_id"])
        session = try SurfaceControlSession(instanceID: "scenario.instance", epoch: "scenario.epoch", profile: profile)
        initialExpected = session.expected
        // Enable is deliberately unknown: a snapshot seed must not count as a fresh rest edge.
        try session.seedInputs(["axis": .number(0), "primary": .bool(false), "stop": .bool(false)], at: 0)
        agent = try AgentPlugin(slotCount: 1)
        robot = try RobotPlugin(instanceID: "scenario.robot")
        chassis = try ChassisPlugin(instanceID: "scenario.chassis")
        output = try ParameterOutputPlugin(limits: [.init(id: "scenario.axis", minimum: -1, maximum: 1, maximumChange: 0.1, maximumVelocity: 1)])
        _ = try agent.handle(.start, at: 0)
        _ = try robot.handle(.start, at: 0)
        _ = try chassis.handle(.start, at: 0)
        _ = try output.handle(.start, at: 0)
        try robot.simulator.initialize(Array(repeating: 0, count: 6), generation: robot.simulator.control.generation)
        try chassis.simulator.initialize([0, 0, 0], generation: chassis.simulator.control.generation)
        output.setConnected(true, at: 0)
    }
    mutating func proof() throws -> DeviceCommandProof {
        guard let grant else { throw ScenarioFailure(code: "missing_grant") }
        commandSequence += 1
        return .init(generation: grant.generation, token: grant.control_token, sequence: commandSequence)
    }
    mutating func enable() throws {
        guard sawRest, axis == 0 else { return }
        latched = false; sawRest = false
        if domain == "robot" {
            grant = try robot.simulator.acquire(generation: robot.simulator.control.generation, owner: "scenario.consumer", ttl: 5, controlToken: "fixture.robot.\(commandCount)")
            commandSequence = 0
            let p = try proof(); try robot.simulator.enable(p); commandCount += 1
        } else if domain == "chassis" {
            grant = try chassis.simulator.acquire(generation: chassis.simulator.control.generation, owner: "scenario.consumer", ttl: 5, controlToken: "fixture.chassis.\(commandCount)")
            commandSequence = 0
            let p = try proof(); try chassis.simulator.enable(p); commandCount += 1
        } else if domain == "output" { try output.setEnabled(true); evaluateOutput() }
    }
    mutating func stop() throws {
        latched = true; sawRest = false; grant = nil
        switch domain {
        case "robot": robot.simulator.revokeControl()
        case "chassis": chassis.simulator.revokeControl()
        case "agent": _ = try agent.interrupt(1, at: now)
        case "output": try output.setEnabled(false); evaluateOutput()
        default: throw ScenarioFailure(code: "unknown_domain")
        }
        commandCount += 1
    }
    mutating func evaluateOutput() {
        let result = output.evaluate(targets: [outputID: axis / 100], at: now)
        if result.command?.enabled == true { commandCount += 1 }
    }
    mutating func consume(_ event: ControlEvent) throws {
        guard event.expected == session.expected else { throw ScenarioFailure(code: "stale_consumer_identity") }
        let n = UInt64(event.sequence)!
        if n <= consumed { return } // duplicates never replay an action or acquire authority
        guard n == consumed + 1 else { throw ScenarioFailure(code: "event_gap") }
        consumed = n
        guard event.kind == .input, event.disposition == .accepted else { return }
        if event.control_id == "enable", let value = event.value.boolValue {
            if value { try enable() }
            else {
                try stop()
                // A host expiry is a stop, not a new operator preparation edge.
                sawRest = event.reason != SurfaceControlSession.holdExpiredReason
            }
        } else if event.control_id == "axis", let value = event.value.finiteNumber {
            axis = value
            guard !latched else { return }
            if domain == "robot" {
                let p = try proof()
                try robot.simulator.move(p, target: [axis / 100, 0, 0, 0, 0, 0], duration: 2, validFor: 3)
                commandCount += 1
            } else if domain == "chassis" {
                let p = try proof()
                try chassis.simulator.drive(p, speed: axis / 200, steering: 0, validFor: 2)
                commandCount += 1
            } else if domain == "output" { evaluateOutput() }
        } else if event.control_id == "primary", event.value == .bool(true), domain == "agent" {
            _ = try agent.handle(.invoke(.init(pluginID: AgentPlugin.pluginID, actionID: AgentPlugin.primaryActionID, index: 1), origin: .remote), at: now)
            commandCount += 1
        } else if event.control_id == "stop", event.value == .bool(true) { try stop() }
    }
    mutating func input(control: String, value: JSONValue, hold: Double?, stale: Bool = false) throws {
        let arguments: JSONValue = .object([
            "expected": try .encoded(stale ? initialExpected : session.expected),
            "expected_input_sequence": .string(session.discovery().latest_input_sequence!),
            "control_id": .string(control), "encoding": .string(control == "axis" ? "scalar" : "boolean"), "value": value
        ].merging(hold.map { ["hold_s": .double($0)] } ?? [:]) { _, new in new })
        guard case .input(let request) = try SurfaceControlTools.parse("surface_control_input", arguments: arguments) else { throw ScenarioFailure(code: "wrong_tool") }
        // The real parser/session gate executes before any consumer effect. Commit both value copies.
        try session.validateInput(request, at: now, writerID: "scenario.operator")
        var next = self
        let ignored = next.session.isUnchanged(request)
        let event = try next.session.recordInput(request, disposition: ignored ? .ignored : .accepted,
                                                reason: ignored ? "no_change" : nil, origin: .remote, at: now, writerID: "scenario.operator")
        try next.consume(event); next.lastInput = event
        self = next
    }
    mutating func feedback(_ value: Double) throws {
        let update = ControlFeedback(expected: session.expected, controlID: "display", kind: "value", value: .number(Int(value)))
        guard case .feedback(let parsed) = try SurfaceControlTools.parse("surface_control_feedback", arguments: .encoded(update)) else { throw ScenarioFailure(code: "wrong_tool") }
        var next = self
        let event = try next.session.recordFeedback(parsed, origin: .remote, at: now, writerID: "scenario.feedback")
        try next.consume(event)
        self = next
    }
    var actual: Double {
        switch domain {
        case "robot": robot.simulator.snapshot().actual?.joints_rad[0] ?? .nan
        case "chassis": chassis.simulator.snapshot().actual?.speed_m_s ?? .nan
        case "output": trustedActual ?? .nan
        default: agent.slots[0].progress
        }
    }
    var target: Double {
        switch domain {
        case "robot": robot.simulator.snapshot().target_joints_rad?.first ?? actual
        case "chassis": chassis.simulator.snapshot().target_speed_m_s
        case "output": axis / 100
        default: actual
        }
    }
    mutating func publish() throws {
        let before = actual
        let value = Int((before * 100).rounded())
        try feedback(Double(value))
        feedbackMatchesActual = sessionSnapshotFeedback() == .number(value) && actual == before
    }
    func sessionSnapshotFeedback() -> JSONValue? { try? session.snapshot(at: now).feedback["display"]?["value"] }
    mutating func advance(to end: Double) throws {
        guard end >= now else { throw ScenarioFailure(code: "clock_rollback") }
        while now < end {
            let boundary = session.nextHoldDeadline.map { max(now, $0) } ?? end
            let nextTime = min(end, now + 0.05, boundary)
            let dt = nextTime - now
            if dt > 0 {
                if domain == "robot" { try robot.advanceSimulation(dt) }
                if domain == "chassis" { try chassis.advanceSimulation(dt) }
                now = nextTime
                if domain == "agent" { _ = try agent.handle(.advance, at: now) }
                if domain == "output" { evaluateOutput() }
            }
            for expiry in session.dueHoldExpiries(at: now) {
                var next = self
                let event = try next.session.recordHoldExpiry(controlID: expiry.controlID, at: now, writerID: "scenario.system")
                try next.consume(event)
                next.expirySystemWriter = event.writer_id == "scenario.system"
                self = next
            }
        }
    }
    mutating func run(_ step: Step) throws {
        if step.op == "advance" { try advance(to: step.at); return }
        // Non-advance operations carry injected monotonic time but do not fabricate model movement.
        now = step.at
        switch step.op {
        case "input": try input(control: step.control!, value: step.value!, hold: step.hold_s)
        case "stale": try input(control: "primary", value: .bool(true), hold: nil, stale: true)
        case "replay": if let lastInput { try consume(lastInput) }
        case "publish": try publish()
        case "display_override": try feedback(step.value!.finiteNumber!)
        case "heartbeat": output.receiveHeartbeat(at: now); evaluateOutput()
        case "actual":
            // The fixture stands for a trusted observation source, independent of all display writes.
            trustedActual = step.value!.finiteNumber!
            output.receiveHeartbeat(at: now)
            output.receiveActual([.init(id: outputID, value: trustedActual!, receivedAt: now)])
            evaluateOutput()
        case "disconnect":
            try stop()
            if domain == "output" { output.setConnected(false, at: now); evaluateOutput() }
        case "reset":
            try stop()
            let arguments: JSONValue = .object(["expected": try .encoded(session.expected), "expected_sequence": .string(session.discovery().latest_sequence)])
            guard case .reset(let expected, let sequence) = try SurfaceControlTools.parse("surface_control_reset", arguments: arguments) else { throw ScenarioFailure(code: "wrong_tool") }
            try session.reset(expected: expected, expectedSequence: sequence, epoch: "scenario.reset", at: now)
            consumed = 0
        default: throw ScenarioFailure(code: "unknown_operation")
        }
    }
    func observations(previousCommands: Int) throws -> [String: JSONValue] {
        let robotState = robot.simulator.snapshot(), chassisState = chassis.simulator.snapshot()
        let moving = domain == "robot" ? robotState.motion_active : domain == "chassis" ? !chassisState.stopped : false
        let enabled = domain == "robot" ? robotState.metadata.enabled : domain == "chassis" ? chassisState.metadata.enabled : output.requestedEnabled
        return ["commands_before_operation": .number(previousCommands), "command_count": .number(commandCount), "commands_unchanged": .bool(previousCommands == commandCount),
                "latched": .bool(latched), "enabled": .bool(enabled), "moving": .bool(moving), "stopped": .bool(!moving),
                "actual_zero": .bool(actual == 0), "actual_positive": .bool(actual > 0), "target_actual_distinct": .bool(target != actual),
                "agent_state": .string(agent.slots[0].state.rawValue), "status": .string(output.gate.status.rawValue),
                "frame_enabled": .bool(output.decision?.command?.enabled == true), "frame_zero": .bool(output.decision?.command?.values[outputID] == 0),
                "limited": .bool(output.decision?.limited == true), "feedback_matches_actual": .bool(feedbackMatchesActual),
                "input_axis": try session.snapshot(at: now).inputs["axis"] ?? .null,
                "expiry_system_writer": .bool(expirySystemWriter), "sequence": .string(session.discovery().latest_sequence),
                "input_sequence": .string(session.discovery().latest_input_sequence!),
                "server_time": .double(now), "actual": actual.isFinite ? .double(actual) : .null,
                "target": target.isFinite ? .double(target) : .null, "actual_source": .string("simulation") ]
    }
}

final class SurfaceDeviceScenarioTests: XCTestCase {
    func testSurfaceDrivenDeviceScenarios() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "device-scenarios", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(ScenarioFile.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.schema_version, 1); XCTAssertEqual(fixture.source, "simulation")
        var reports: [JSONValue] = []
        for scenario in fixture.scenarios {
            var consumer = try Consumer(domain: scenario.domain)
            var steps: [JSONValue] = []
            for (index, step) in scenario.steps.enumerated() {
                // Advance both device and control clocks before the step; input/display calls
                // never themselves synthesize elapsed model time or authoritative observations.
                try consumer.advance(to: step.at)
                let before = consumer.commandCount
                var errorCode: String?
                do { try consumer.run(step) }
                catch let error as ControlContractError { errorCode = error.code }
                catch let error as ScenarioFailure { errorCode = error.code }
                var observations = try consumer.observations(previousCommands: before)
                observations["error"] = errorCode.map(JSONValue.string) ?? .null
                var pass = errorCode == step.expect["error"]?.stringValue
                for (key, value) in step.expect where observations[key] != value { pass = false }
                XCTAssertTrue(pass, "\(scenario.id) step \(index) \(step.op): expected \(step.expect), observed \(observations)")
                steps.append(.object(["index": .number(index), "operation": .string(step.op), "pass": .bool(pass), "observations": .object(observations)]))
            }
            reports.append(.object(["scenario": .string(scenario.id), "domain": .string(scenario.domain), "pass": .bool(steps.allSatisfy { $0.objectValue?["pass"] == .bool(true) }), "steps": .array(steps)]))
        }
        let report: JSONValue = .object(["schema_version": .number(1), "source": .string("simulation"), "contract_version": .string(ControlDiscovery.contractVersion), "pass": .bool(reports.allSatisfy { $0.objectValue?["pass"] == .bool(true) }), "scenarios": .array(reports)])
        if let path = ProcessInfo.processInfo.environment["SURFACE_DEVICE_SCENARIO_REPORT"] {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
