import Foundation
import SurfaceControlContracts
import SurfacePluginContracts

func inputRetentionSchema(hardware: Bool, examples: Bool) throws -> JSONValue {
    if !examples {
        return .object(["schema_version": .number(1), "contract_version": .string("1.5"),
            "tools": try .encoded(SurfaceControlInputEventsTools.descriptors(source: hardware ? .hardware : .simulation))])
    }
    var caps = [hardware ? "hardware" : "simulation", "controls.input_declared", "input.button", "feedback.indicator", "feedback.unsequenced", "input.independent_sequence", "events.input_retention", "events.writer_id"]
    if !hardware { caps.append("input.hold") }
    let profile = ControlProfile(id: hardware ? "example.retained.hardware" : "example.retained.simulation", version: "1.5", controls: [
        .init(id: "button", inputKind: .button, encoding: .boolean, feedbackKinds: [.indicator],
              hold: hardware ? nil : .init(restValue: .bool(false), maxHoldSeconds: 2), acceptsInput: !hardware)
    ], capabilities: caps)
    var session = try SurfaceControlSession(instanceID: "example-instance", epoch: "initial", profile: profile, eventCapacity: 2, inputEventCapacity: 4)
    if hardware { try session.transitionHardware(epoch: "connected", linkState: .connected, at: 0) }
    var result: [JSONValue] = []
    func page(after: String = "0", limit: Int = 128, at: Double = 0) throws -> JSONValue {
        .object(["tool": .string(SurfaceControlInputEventsTools.name),
            "arguments": try .encoded(ControlInputEventsRequest(expected: session.expected, afterInputSequence: after, limit: limit)),
            "result": try .encoded(session.inputEvents(expected: session.expected, afterInputSequence: after, limit: limit, at: at))])
    }
    result.append(try page())
    if hardware {
        try session.recordHardwareInput(.init(expected: session.expected, controlID: "button", encoding: "boolean", value: .bool(true)), disposition: .accepted, at: 0, writerID: "device")
        try session.recordHardwareInput(.init(expected: session.expected, controlID: "button", encoding: "boolean", value: .bool(true)), disposition: .ignored, reason: "no_change", at: 0, writerID: "device")
    } else {
        try session.recordInput(.init(expected: session.expected, expectedInputSequence: "0", controlID: "button", encoding: "boolean", value: .bool(true), holdSeconds: 1), disposition: .accepted, origin: .remote, at: 0, writerID: "operator")
        try session.recordInput(.init(expected: session.expected, expectedInputSequence: "1", controlID: "button", encoding: "boolean", value: .bool(true)), disposition: .ignored, reason: "no_change", origin: .interface, at: 0, writerID: "interface")
    }
    for _ in 0..<4 { try session.recordFeedback(.init(expected: session.expected, controlID: "button", kind: "indicator", value: .string("on")), origin: .remote, at: 0, writerID: "display") }
    result.append(try page(limit: 1)); result.append(try page(after: "1"))
    if !hardware {
        try session.recordHoldExpiry(controlID: "button", at: 1, writerID: "system")
        result.append(try page(at: 1))
    }
    return .array(result)
}
