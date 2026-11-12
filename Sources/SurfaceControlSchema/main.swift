import Foundation
import SurfaceControlContracts
import SurfacePluginContracts

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.isEmpty || arguments == ["--examples"] else { throw ControlContractError("invalid_argument") }
let schema: JSONValue
if arguments.isEmpty {
    schema = .object([
    "schema_version": .number(1),
    "contract_version": .string("1.0"),
    "tools": try .encoded(SurfaceControlTools.descriptors)
    ])
} else {
    let profile = ControlProfile(id: "example.scalar", version: "1", controls: [
        .init(id: "dial.1", inputKind: .absolute, encoding: .scalar, range: .init(minimum: 0, maximum: 100, step: 1),
              feedbackKinds: [.value, .indicator], mapping: .init(kind: .parameter, id: "example.input")),
        .init(id: "button.1", inputKind: .button, encoding: .boolean, feedbackKinds: [.indicator])
    ], capabilities: ["simulation", "input.absolute", "input.button"])
    var session = try SurfaceControlSession(instanceID: "example-instance", epoch: "example-epoch", mappingRevision: "1", profile: profile)
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
    let reset = JSONValue.object(["expected": try .encoded(session.expected), "expected_sequence": .string("3")])
    try session.reset(expected: session.expected, expectedSequence: "3", epoch: "example-reset", mappingRevision: "1", at: 3)
    examples.append(try sample("surface_control_reset", reset, session.discovery()))
    schema = .array(examples)
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
FileHandle.standardOutput.write(try encoder.encode(schema))
FileHandle.standardOutput.write(Data([10]))
