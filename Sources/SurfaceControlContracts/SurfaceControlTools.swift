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
    /// Contract 1.1.
    case renew(ControlRenew)
}

/// Optional contract 1.1 (additive over 1.0). This namespace does not replace Provider 1.0 or plugin business tools.
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
            "feedback_kinds": s.array(s.string), "mapping": s.object(["kind": s.string, "id": s.string]),
            "hold": s.object(["rest_value": valueSchema, "max_hold_s": s.number]),
            "accepts_input": s.boolean
        ], optional: ["range", "feedback_range", "mapping", "hold", "accepts_input"]))])
    }
    private static var writeLimitsSchema: JSONValue {
        let s = RemoteSchema.self
        let limit: JSONValue = .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(10000)])
        return s.object(["window_s": .object(["type": .string("integer"), "enum": .array([.number(1)])]),
                         "input_per_window": limit, "feedback_per_window": limit, "renew_per_window": limit, "admin_per_window": limit])
    }
    private static var inputSchema: JSONValue {
        let s = RemoteSchema.self
        var fields = s.object(["expected": expectedSchema, "expected_sequence": s.string, "expected_input_sequence": s.string,
            "control_id": s.string, "encoding": s.string, "value": valueSchema, "hold_s": s.number],
            optional: ["hold_s", "expected_sequence", "expected_input_sequence"]).objectValue!
        fields["oneOf"] = .array(["expected_sequence", "expected_input_sequence"].map {
            .object(["required": .array([.string($0)])])
        })
        return .object(fields)
    }
    private static var discoverySchema: JSONValue {
        let s = RemoteSchema.self
        return s.object(["schema_version": s.integer, "contract_version": s.string, "source": s.string,
                         "expected": expectedSchema, "latest_sequence": s.string, "profile": profileSchema,
                         "latest_input_sequence": s.string, "write_limits": writeLimitsSchema], optional: ["latest_input_sequence", "write_limits"])
    }
    private static var eventSchema: JSONValue {
        let s = RemoteSchema.self
        return s.object(["expected": expectedSchema, "sequence": s.string, "input_sequence": s.string, "writer_id": s.string, "time": s.number, "source": s.string,
            "origin": s.string, "kind": s.string, "control_id": s.string, "encoding": s.string,
            "value": valueSchema, "disposition": s.string, "mapped_value": valueSchema, "reason": s.string, "hold_deadline": s.number],
            optional: ["mapped_value", "reason", "hold_deadline", "input_sequence", "writer_id"])
    }
    public static var descriptors: [RemoteToolDescriptor] {
        let s = RemoteSchema.self
        return [
            .init(name: "surface_control_discover", fields: [:], output: discoverySchema, isMutation: false),
            .init(name: "surface_control_snapshot", fields: ["instance_id": s.string], output: s.object([
                "discovery": discoverySchema, "server_time": s.number, "latest_sequence": s.string, "latest_input_sequence": s.string, "inputs": mapSchema,
                "feedback": .object(["type": .string("object"), "additionalProperties": mapSchema]),
                "holds": .object(["type": .string("object"), "additionalProperties": s.number])], optional: ["holds", "latest_input_sequence"]), isMutation: false),
            .init(name: "surface_control_input", inputSchema: inputSchema, output: eventSchema, isMutation: true),
            .init(name: "surface_control_feedback", fields: ["expected": expectedSchema, "expected_sequence": s.string, "control_id": s.string, "kind": s.string, "value": valueSchema], optional: ["expected_sequence"], output: eventSchema, isMutation: true),
            .init(name: "surface_control_events", fields: ["instance_id": s.string, "epoch": s.string, "after_sequence": s.string, "limit": s.integer], output: s.object([
                "expected": expectedSchema, "server_time": s.number, "latest_sequence": s.string, "latest_input_sequence": s.string, "events": s.array(eventSchema),
                "holds": .object(["type": .string("object"), "additionalProperties": s.number])], optional: ["holds", "latest_input_sequence"]), isMutation: false),
            .init(name: "surface_control_reset", fields: ["expected": expectedSchema, "expected_sequence": s.string], output: discoverySchema, isMutation: true),
            // Silent lease renewal: consumes no sequence and writes no event, but needs input permission and write budget.
            .init(name: "surface_control_renew", fields: ["expected": expectedSchema, "control_id": s.string, "hold_s": s.number],
                  output: s.object(["control_id": s.string, "hold_deadline": s.number, "server_time": s.number]), isMutation: true)
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
            case "surface_control_renew": return .renew(try arguments.decoded(ControlRenew.self))
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
        if let choices = fields["oneOf"]?.arrayValue, choices.filter({ matches(value, schema: $0) }).count != 1 { return false }
        if fields["type"] == nil, let required = fields["required"]?.arrayValue?.compactMap(\.stringValue) {
            return value.objectValue.map { Set(required).isSubset(of: Set($0.keys)) } ?? false
        }
        switch fields["type"]?.stringValue {
        case "object":
            guard let object = value.objectValue, let properties = fields["properties"]?.objectValue,
                  let required = fields["required"]?.arrayValue?.compactMap(\.stringValue),
                  Set(object.keys).isSubset(of: Set(properties.keys)), Set(required).isSubset(of: Set(object.keys)) else { return false }
            return object.allSatisfy { key, item in matches(item, schema: properties[key]!) }
        case "string": return value.stringValue.map { !$0.isEmpty && $0.utf8.count <= 4096 } ?? false
        case "number": return value.finiteNumber != nil
        case "boolean": return value.boolValue != nil
        case "integer": return value.exactIntValue != nil
        default: return false
        }
    }
}
