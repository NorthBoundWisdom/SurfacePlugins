import Foundation
import SurfacePluginContracts
import RemoteToolContracts

/// A bounded historical log of immutable input event records, not parameter state.
public struct ControlInputEventPage: Equatable, Codable, Sendable {
    public let expected: ControlExpected
    public let server_time: Double
    public let latest_sequence: String
    public let latest_input_sequence: String
    public let input_event_capacity: Int
    public let events: [ControlEvent]
    public let holds: [String: Double]?
    public let link: ControlLink?
}

public struct ControlInputEventsRequest: Equatable, Codable, Sendable {
    public let expected: ControlExpected
    public let after_input_sequence: String
    public let limit: Int
    public init(expected: ControlExpected, afterInputSequence: String, limit: Int = 128) {
        self.expected = expected; after_input_sequence = afterInputSequence; self.limit = limit
    }
}

/// Register only when events.input_retention was explicitly enabled. The seven frozen tools
/// and their parser do not know this tool; hosts authenticate and authorize before parsing it.
public enum SurfaceControlInputEventsTools {
    public static let name = "surface_control_input_events"
    public static func descriptors(source: PluginSource) -> [RemoteToolDescriptor] {
        let s = RemoteSchema.self
        let expected = s.object(["instance_id": s.string, "epoch": s.string, "mapping_revision": s.string, "profile_id": s.string, "profile_version": s.string])
        let decimal: JSONValue = .object(["type": .string("string"), "pattern": .string("^(0|[1-9][0-9]*)$"), "maxLength": .number(20)])
        let limit: JSONValue = .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(1024)])
        var eventFields = SurfaceControlTools.descriptors.first { $0.name == "surface_control_input" }!.outputSchema.objectValue!
        var properties = eventFields["properties"]!.objectValue!
        properties["kind"] = .object(["type": .string("string"), "enum": .array([.string("input")])])
        properties["input_sequence"] = decimal
        properties["sequence"] = decimal
        eventFields["properties"] = .object(properties)
        eventFields["required"] = .array((eventFields["required"]!.arrayValue! + [.string("input_sequence")]).sorted { $0.stringValue! < $1.stringValue! })
        var fields: [String: JSONValue] = ["expected": expected, "server_time": s.number, "latest_sequence": decimal, "latest_input_sequence": decimal,
            "input_event_capacity": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(65536)]),
            "events": s.array(.object(eventFields)), "holds": .object(["type": .string("object"), "additionalProperties": s.number])]
        if source == .hardware { fields["link"] = s.object(["state": .object(["type": .string("string"), "enum": .array([.string("connected"), .string("disconnected")])])]) }
        return [.init(name: name, inputSchema: s.object(["expected": expected, "after_input_sequence": decimal, "limit": limit]),
                      output: s.object(fields, optional: ["holds"]), isMutation: false)]
    }
    public static func parse(_ tool: String, arguments: JSONValue) throws -> ControlInputEventsRequest {
        guard tool == name else { throw ControlContractError("unsupported_tool") }
        guard let fields = arguments.objectValue, Set(fields.keys) == ["expected", "after_input_sequence", "limit"],
              let identity = fields["expected"]?.objectValue,
              Set(identity.keys) == ["instance_id", "epoch", "mapping_revision", "profile_id", "profile_version"],
              identity.values.allSatisfy({ $0.stringValue.map { !$0.isEmpty && $0.utf8.count <= 4096 } ?? false }),
              let after = fields["after_input_sequence"]?.stringValue, let value = UInt64(after), String(value) == after,
              let limit = fields["limit"]?.exactIntValue, (1...1024).contains(limit) else { throw ControlContractError("invalid_argument") }
        do { return try arguments.decoded(ControlInputEventsRequest.self) }
        catch { throw ControlContractError("invalid_argument") }
    }
}
