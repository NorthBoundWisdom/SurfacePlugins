import Foundation
import SurfacePluginContracts
import RemoteToolContracts

public enum ControlToolRequest: Sendable {
    case discover
    case snapshot(instanceID: String)
    case input(ControlInput)
    case feedback(ControlFeedback)
    case events(instanceID: String, epoch: String, afterSequence: String, limit: Int)
    case reset(expected: ControlExpected, expectedSequence: String)
}

/// Optional contract 1.0. This namespace does not replace Provider 1.0 or plugin business tools.
public enum SurfaceControlTools {
    private static var expectedSchema: JSONValue {
        RemoteSchema.object(["instance_id": RemoteSchema.string, "epoch": RemoteSchema.string,
            "mapping_revision": RemoteSchema.string, "profile_id": RemoteSchema.string, "profile_version": RemoteSchema.string])
    }
    private static var valueSchema: JSONValue {
        .object(["anyOf": .array([RemoteSchema.number, RemoteSchema.boolean, RemoteSchema.string])])
    }
    private static var mapSchema: JSONValue { .object(["type": .string("object"), "additionalProperties": valueSchema]) }
    private static var profileSchema: JSONValue {
        let s = RemoteSchema.self
        return s.object(["id": s.string, "version": s.string, "capabilities": s.array(s.string), "controls": s.array(s.object([
            "id": s.string, "input_kind": s.string, "encoding": s.string,
            "range": s.object(["minimum": s.number, "maximum": s.number, "step": s.number], optional: ["step"]),
            "feedback_range": s.object(["minimum": s.number, "maximum": s.number, "step": s.number], optional: ["step"]),
            "feedback_kinds": s.array(s.string), "mapping": s.object(["kind": s.string, "id": s.string])
        ], optional: ["range", "feedback_range", "mapping"]))])
    }
    private static var discoverySchema: JSONValue {
        let s = RemoteSchema.self
        return s.object(["schema_version": s.integer, "contract_version": s.string, "source": s.string,
                         "expected": expectedSchema, "latest_sequence": s.string, "profile": profileSchema])
    }
    private static var eventSchema: JSONValue {
        let s = RemoteSchema.self
        return s.object(["expected": expectedSchema, "sequence": s.string, "time": s.number, "source": s.string,
            "origin": s.string, "kind": s.string, "control_id": s.string, "encoding": s.string,
            "value": valueSchema, "disposition": s.string, "mapped_value": valueSchema, "reason": s.string], optional: ["mapped_value", "reason"])
    }
    public static var descriptors: [RemoteToolDescriptor] {
        let s = RemoteSchema.self
        return [
            .init(name: "surface_control_discover", fields: [:], output: discoverySchema, isMutation: false),
            .init(name: "surface_control_snapshot", fields: ["instance_id": s.string], output: s.object([
                "discovery": discoverySchema, "server_time": s.number, "latest_sequence": s.string, "inputs": mapSchema,
                "feedback": .object(["type": .string("object"), "additionalProperties": mapSchema])]), isMutation: false),
            .init(name: "surface_control_input", fields: ["expected": expectedSchema, "expected_sequence": s.string, "control_id": s.string, "encoding": s.string, "value": valueSchema], output: eventSchema, isMutation: true),
            .init(name: "surface_control_feedback", fields: ["expected": expectedSchema, "expected_sequence": s.string, "control_id": s.string, "kind": s.string, "value": valueSchema], output: eventSchema, isMutation: true),
            .init(name: "surface_control_events", fields: ["instance_id": s.string, "epoch": s.string, "after_sequence": s.string, "limit": s.integer], output: s.object([
                "expected": expectedSchema, "server_time": s.number, "latest_sequence": s.string, "events": s.array(eventSchema)]), isMutation: false),
            .init(name: "surface_control_reset", fields: ["expected": expectedSchema, "expected_sequence": s.string], output: discoverySchema, isMutation: true)
        ]
    }
    public static func parse(_ name: String, arguments: JSONValue) throws -> ControlToolRequest {
        guard let tool = descriptors.first(where: { $0.name == name }) else { throw ControlContractError("unsupported_tool") }
        guard matches(arguments, schema: tool.inputSchema) else { throw ControlContractError("invalid_argument") }
        let values = arguments.objectValue!
        do {
            switch name {
            case "surface_control_discover": return .discover
            case "surface_control_snapshot": return .snapshot(instanceID: values["instance_id"]!.stringValue!)
            case "surface_control_input": return .input(try arguments.decoded(ControlInput.self))
            case "surface_control_feedback": return .feedback(try arguments.decoded(ControlFeedback.self))
            case "surface_control_reset": return .reset(expected: try values["expected"]!.decoded(ControlExpected.self), expectedSequence: values["expected_sequence"]!.stringValue!)
            default:
                let limit = values["limit"]!.exactIntValue!
                let after = values["after_sequence"]!.stringValue!
                guard limit > 0, limit <= 1024, after.utf8.allSatisfy({ (48...57).contains($0) }),
                      let cursor = UInt64(after), String(cursor) == after else { throw ControlContractError("invalid_argument") }
                return .events(instanceID: values["instance_id"]!.stringValue!, epoch: values["epoch"]!.stringValue!, afterSequence: after, limit: limit)
            }
        } catch let error as ControlContractError { throw error }
        catch { throw ControlContractError("invalid_argument") }
    }
    private static func matches(_ value: JSONValue, schema: JSONValue) -> Bool {
        guard let fields = schema.objectValue else { return false }
        if let choices = fields["anyOf"]?.arrayValue { return choices.contains { matches(value, schema: $0) } }
        switch fields["type"]?.stringValue {
        case "object":
            guard let object = value.objectValue, let properties = fields["properties"]?.objectValue,
                  Set(object.keys) == Set(properties.keys) else { return false }
            return properties.allSatisfy { key, spec in matches(object[key]!, schema: spec) }
        case "string": return value.stringValue.map { !$0.isEmpty && $0.utf8.count <= 4096 } ?? false
        case "number": return value.finiteNumber != nil
        case "boolean": return value.boolValue != nil
        case "integer": return value.exactIntValue != nil
        default: return false
        }
    }
}
