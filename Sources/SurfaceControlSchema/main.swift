import Foundation
import SurfaceControlContracts
import SurfacePluginContracts

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.isEmpty || arguments == ["--examples"] else { throw ControlContractError("invalid_argument") }
let schema: JSONValue
if arguments.isEmpty {
    schema = .object([
    "schema_version": .number(1),
    "contract_version": .string(ControlDiscovery.contractVersion),
    "tools": try .encoded(SurfaceControlTools.descriptors)
    ])
} else {
    let profile = ControlProfile(id: "example.scalar", version: "1.2", controls: [
        .init(id: "dial.1", inputKind: .absolute, encoding: .scalar, range: .init(minimum: 0, maximum: 100, step: 1),
              feedbackKinds: [.value, .indicator], mapping: .init(kind: .parameter, id: "example.input"), acceptsInput: true),
        .init(id: "button.1", inputKind: .button, encoding: .boolean, feedbackKinds: [.indicator],
              hold: .init(restValue: .bool(false), maxHoldSeconds: 2), acceptsInput: true)
    ], capabilities: ["simulation", "controls.stable_ids", "input.absolute", "input.button", "input.hold", "feedback.value", "feedback.indicator", "feedback.unsequenced", "controls.input_declared"])
    var session = try SurfaceControlSession(instanceID: "example-instance", epoch: "example-epoch", profile: profile)
    try session.seedInputs(["dial.1": .number(0), "button.1": .bool(false)], at: 0)
    var examples: [JSONValue] = []
    func sample<T: Encodable>(_ tool: String, _ arguments: JSONValue, _ result: T) throws -> JSONValue {
        .object(["tool": .string(tool), "arguments": arguments, "result": try .encoded(result)])
    }
    examples.append(try sample("surface_control_discover", .object([:]), session.discovery()))
    let input = ControlInput(expected: session.expected, expectedSequence: "0", controlID: "dial.1", encoding: "scalar", value: .number(80))
    examples.append(try sample("surface_control_input", .encoded(input), session.recordInput(input, disposition: .accepted, mappedValue: .double(0.8), origin: .remote, at: 1)))
    let feedback = ControlFeedback(expected: session.expected, expectedSequence: "1", controlID: "button.1", kind: "indicator", value: .string("on"))
    examples.append(try sample("surface_control_feedback", .encoded(feedback), session.recordFeedback(feedback, origin: .remote, at: 2)))
    let ignored = ControlInput(expected: session.expected, expectedSequence: "2", controlID: "dial.1", encoding: "scalar", value: .number(80))
    examples.append(try sample("surface_control_input", .encoded(ignored), session.recordInput(ignored, disposition: .ignored, reason: "no_change", origin: .remote, at: 2)))
    examples.append(try sample("surface_control_snapshot", .object(["instance_id": .string("example-instance")]), session.snapshot(at: 2)))
    examples.append(try sample("surface_control_events", .object(["instance_id": .string("example-instance"), "epoch": .string("example-epoch"), "after_sequence": .string("0"), "limit": .number(128)]), session.events(instanceID: "example-instance", epoch: "example-epoch", afterSequence: "0", at: 2)))
    // Contract 1.1 lease: acquire, renew silently, let it expire, then record the host's rest value.
    let held = ControlInput(expected: session.expected, expectedSequence: "3", controlID: "button.1", encoding: "boolean", value: .bool(true), holdSeconds: 1)
    examples.append(try sample("surface_control_input", .encoded(held), session.recordInput(held, disposition: .accepted, origin: .remote, at: 3)))
    let renew = ControlRenew(expected: session.expected, controlID: "button.1", holdSeconds: 1)
    examples.append(try sample("surface_control_renew", .encoded(renew), session.renew(renew, at: 3.5)))
    examples.append(try sample("surface_control_snapshot", .object(["instance_id": .string("example-instance")]), session.snapshot(at: 4)))
    examples.append(try sample("surface_control_events", .object(["instance_id": .string("example-instance"), "epoch": .string("example-epoch"), "after_sequence": .string("4"), "limit": .number(128)]), session.events(instanceID: "example-instance", epoch: "example-epoch", afterSequence: "4", at: 4)))
    for expiry in session.dueHoldExpiries(at: 4.5) { try session.recordHoldExpiry(controlID: expiry.controlID, at: 4.5) }
    examples.append(try sample("surface_control_events", .object(["instance_id": .string("example-instance"), "epoch": .string("example-epoch"), "after_sequence": .string("3"), "limit": .number(128)]), session.events(instanceID: "example-instance", epoch: "example-epoch", afterSequence: "3", at: 4.5)))
    let unsequenced = ControlFeedback(expected: session.expected, controlID: "button.1", kind: "indicator", value: .string("off"))
    examples.append(try sample("surface_control_feedback", .encoded(unsequenced), session.recordFeedback(unsequenced, origin: .remote, at: 5)))
    let reset = JSONValue.object(["expected": try .encoded(session.expected), "expected_sequence": .string("6")])
    try session.reset(expected: session.expected, expectedSequence: "6", epoch: "example-reset", at: 5)
    examples.append(try sample("surface_control_reset", reset, session.discovery()))
    schema = .array(examples)
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
FileHandle.standardOutput.write(try encoder.encode(schema))
FileHandle.standardOutput.write(Data([10]))
