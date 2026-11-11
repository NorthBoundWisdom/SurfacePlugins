import Foundation
import SurfacePluginContracts

public struct RemoteToolDescriptor: Equatable, Codable, Sendable {
    public let name: String
    public let inputSchema: JSONValue
    public let outputSchema: JSONValue
    public let isMutation: Bool
    public init(name: String, fields: [String: JSONValue], output: JSONValue, isMutation: Bool) {
        self.name = name; self.inputSchema = RemoteSchema.object(fields); self.outputSchema = output; self.isMutation = isMutation
    }
}
public enum RemoteSchema {
    public static var string: JSONValue { .object(["type": .string("string"), "minLength": .number(1)]) }
    public static var number: JSONValue { .object(["type": .string("number")]) }
    public static var integer: JSONValue { .object(["type": .string("integer")]) }
    public static var boolean: JSONValue { .object(["type": .string("boolean")]) }
    public static func array(_ item: JSONValue) -> JSONValue { .object(["type": .string("array"), "items": item]) }
    public static func nullable(_ item: JSONValue) -> JSONValue { .object(["anyOf": .array([item, .object(["type": .string("null")])])]) }
    public static func object(_ fields: [String: JSONValue], optional: Set<String> = []) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(fields), "required": .array(fields.keys.filter { !optional.contains($0) }.sorted().map(JSONValue.string)), "additionalProperties": .bool(false)])
    }
    public static var proof: [String: JSONValue] { ["generation": string, "control_token": string, "sequence": integer] }
    public static var grant: JSONValue { object(["generation": string, "control_token": string, "expires_at_s": number]) }
    public static var metadata: JSONValue {
        object(["schema_version": integer, "device_id": string, "model_id": string, "frame_id": string, "source": string,
                "generation": string, "sequence": integer, "simulated_time_s": number, "state": string,
                "initialized": boolean, "enabled": boolean, "fault": nullable(string), "control_owner": nullable(string),
                "control_expires_at_s": nullable(number), "last_command_sequence": integer], optional: ["fault", "control_owner", "control_expires_at_s"])
    }
}
/// All authority here comes from the authenticated host, never from request arguments.
public struct RemoteCallContext: Sendable {
    public let time: PluginTime
    public let controlToken: String?
    public let permitsOutputEnable: Bool
    public init(time: PluginTime, controlToken: String? = nil, permitsOutputEnable: Bool = false) {
        self.time = time; self.controlToken = controlToken; self.permitsOutputEnable = permitsOutputEnable
    }
}
public protocol RemoteBinding: Sendable {
    var instanceID: String { get }
    var manifest: PluginManifest { get }
    var tools: [RemoteToolDescriptor] { get }
    var surface: SurfaceDescriptor { get }
    func snapshot() -> PluginSnapshot
    mutating func handle(_ input: PluginInput, at time: PluginTime) throws -> PluginUpdate
    mutating func call(_ name: String, arguments: JSONValue, context: RemoteCallContext) throws -> JSONValue
}
public struct RemoteArguments: Sendable {
    private let values: [String: JSONValue]
    public init(_ value: JSONValue, tool: RemoteToolDescriptor, instanceID: String) throws {
        guard let object = value.objectValue, let expected = tool.inputSchema.objectValue?["properties"]?.objectValue,
              Set(object.keys) == Set(expected.keys), object["instance_id"] == .string(instanceID) else { throw PluginError(code: .invalidParameter) }
        for (key, schema) in expected {
            guard let value = object[key], Self.matches(value, schema: schema) else { throw PluginError(code: .invalidParameter, fields: ["field": .string(key)]) }
        }
        values = object
    }
    private static func matches(_ value: JSONValue, schema: JSONValue) -> Bool {
        guard let spec = schema.objectValue, let type = spec["type"]?.stringValue else { return false }
        switch type {
        case "string": return value.stringValue.map { !$0.isEmpty } ?? false
        case "number": return value.finiteNumber != nil
        case "integer": return exactInteger(value) != nil
        case "boolean": return value.boolValue != nil
        case "array": return value.arrayValue.map { items in items.count <= 1024 && items.allSatisfy { matches($0, schema: spec["items"] ?? .null) } } ?? false
        default: return false
        }
    }
    public func string(_ key: String) throws -> String { guard let x = values[key]?.stringValue else { throw PluginError(code: .invalidParameter) }; return x }
    public func number(_ key: String) throws -> Double { guard let x = values[key]?.finiteNumber else { throw PluginError(code: .invalidParameter) }; return x }
    public func integer(_ key: String) throws -> Int { guard let value = values[key], let x = Self.exactInteger(value) else { throw PluginError(code: .invalidParameter) }; return x }
    static func exactInteger(_ value: JSONValue) -> Int? {
        switch value {
        case let .number(number): number
        case let .double(number): number.isFinite ? Int(exactly: number) : nil
        default: nil
        }
    }
    public func numbers(_ key: String) throws -> [Double] {
        guard let xs = values[key]?.arrayValue else { throw PluginError(code: .invalidParameter) }
        return try xs.map { guard let n = $0.finiteNumber else { throw PluginError(code: .invalidParameter) }; return n }
    }
}

/// A value registry, with atomic installation and no domain-name branches or hidden I/O.
public struct RemoteRegistry: Sendable {
    private var bindings: [String: any RemoteBinding] = [:]
    public private(set) var journal: RemoteEventJournal
    public init(epoch: String, eventCapacity: Int = 256) throws { journal = try .init(epoch: epoch, capacity: eventCapacity) }
    public mutating func install(_ additions: [any RemoteBinding]) throws {
        var next = self
        for binding in additions { try next.install(binding) }
        self = next
    }
    public mutating func install(_ binding: any RemoteBinding) throws {
        guard !binding.instanceID.isEmpty, bindings[binding.instanceID] == nil else { throw PluginError(code: .invalidParameter) }
        guard binding.manifest.contractVersion == "1.0", Self.validIdentifier(binding.manifest.id.rawValue) else { throw PluginError(code: .unsupported) }
        let ids = binding.surface.parameters.map { $0.id.rawValue } + binding.surface.actions.map { $0.id.rawValue } + binding.surface.indicators.map { $0.id.rawValue }
        let prefix = binding.manifest.id.rawValue + "."
        guard Set(ids).count == ids.count, ids.allSatisfy({ $0.hasPrefix(prefix) && $0.count > prefix.count && Self.validIdentifier($0) }),
              binding.surface.parameters.allSatisfy({ !$0.nameKey.isEmpty }),
              binding.surface.actions.allSatisfy({ !$0.nameKey.isEmpty && ($0.indexCount.map { $0 > 0 } ?? true) }),
              binding.surface.indicators.allSatisfy({ !$0.nameKey.isEmpty }) else { throw PluginError(code: .invalidParameter) }
        for old in bindings.values {
            if old.manifest.id == binding.manifest.id {
                guard old.manifest == binding.manifest, old.surface == binding.surface, old.tools == binding.tools else { throw PluginError(code: .invalidParameter) }
            } else {
                let occupied = old.surface.parameters.map { $0.id.rawValue } + old.surface.actions.map { $0.id.rawValue } + old.surface.indicators.map { $0.id.rawValue }
                guard Set(occupied).isDisjoint(with: ids) else { throw PluginError(code: .invalidParameter) }
            }
        }
        let current = tools
        guard Set(binding.tools.map(\.name)).count == binding.tools.count,
              binding.tools.allSatisfy({ candidate in
                  candidate.name.hasPrefix("surface_") && candidate.name.utf8.count <= 64 && candidate.name.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 }) && candidate.name != "surface_capabilities" && candidate.name != "surface_events" &&
                  (current.first(where: { $0.name == candidate.name }).map { $0 == candidate } ?? true)
              }) else { throw PluginError(code: .invalidParameter) }
        bindings[binding.instanceID] = binding
    }
    /// Identifier grammar shared by host registration and plugin declarations.
    public static func validIdentifier(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard let first = parts.first?.utf8.first, (97...122).contains(first) else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 }
        }
    }
    private func validateReplacement(_ binding: any RemoteBinding) throws {
        guard let old = bindings[binding.instanceID], old.manifest == binding.manifest, old.tools == binding.tools, old.surface == binding.surface else { throw PluginError(code: .generationMismatch) }
    }
    /// Atomically commit one trusted typed operation and its observable event.
    /// Event fields must never include tokens, credentials, or command proofs.
    public mutating func replace(_ binding: any RemoteBinding, at time: PluginTime, event: PluginEvent) throws {
        try validateReplacement(binding)
        guard !event.code.isEmpty else { throw PluginError(code: .invalidParameter) }
        _ = try JSONEncoder().encode(event)
        var nextJournal = journal
        try nextJournal.append(instanceID: binding.instanceID, event: event, at: time)
        journal = nextJournal; bindings[binding.instanceID] = binding
    }
    public func binding<P: RemoteBinding>(_ id: String, as type: P.Type) -> P? { bindings[id] as? P }
    public mutating func handle(instanceID: String, input: PluginInput, at time: PluginTime) throws -> PluginUpdate {
        guard var binding = bindings[instanceID] else { throw PluginError(code: .unsupported) }
        let before = binding.snapshot()
        let update = try binding.handle(input, at: time)
        var nextJournal = journal
        if before != binding.snapshot() || !update.events.isEmpty {
            try nextJournal.append(instanceID: instanceID, event: .init(code: "surface.state.updated"), at: time)
        }
        journal = nextJournal; bindings[instanceID] = binding
        return update
    }
    public func snapshot(instanceID: String) -> PluginSnapshot? { bindings[instanceID]?.snapshot() }
    public func surface(instanceID: String) -> SurfaceDescriptor? { bindings[instanceID]?.surface }
    public var tools: [RemoteToolDescriptor] {
        var result: [String: RemoteToolDescriptor] = [:]
        for binding in bindings.values { for tool in binding.tools { result[tool.name] = tool } }
        let s = RemoteSchema.self
        result["surface_capabilities"] = .init(name: "surface_capabilities", fields: [:], output: s.object([
            "instances": s.array(s.object(["instance_id": s.string, "manifest": s.object(["id": s.string, "version": s.string, "contractVersion": s.string, "source": s.string]), "tools": s.array(s.string)]))
        ]), isMutation: false)
        result["surface_events"] = .init(name: "surface_events", fields: ["epoch": s.string, "after": s.string, "limit": s.integer], output: s.object([
            "epoch": s.string, "gap": s.boolean, "latestSequence": s.integer,
            "events": s.array(s.object(["sequence": s.integer, "time": s.number, "instanceID": s.string, "event": s.object(["code": s.string, "fields": .object(["type": .string("object")])])]))
        ]), isMutation: false)
        return result.values.sorted { $0.name < $1.name }
    }
    public func capabilities() throws -> JSONValue {
        .object(["instances": .array(try bindings.keys.sorted().map { id in
            let binding = bindings[id]!
            return .object(["instance_id": .string(id), "manifest": try .encoded(binding.manifest), "tools": .array(binding.tools.map { .string($0.name) })])
        })])
    }
    public mutating func call(_ name: String, arguments: JSONValue, context: RemoteCallContext) throws -> JSONValue {
        do { return try execute(name, arguments: arguments, context: context) }
        catch { throw RemoteFailure.from(error) }
    }
    private mutating func execute(_ name: String, arguments: JSONValue, context: RemoteCallContext) throws -> JSONValue {
        guard context.time.isFinite else { throw PluginError(code: .invalidTime) }
        if name == "surface_capabilities" {
            guard arguments == .object([:]) else { throw PluginError(code: .invalidParameter) }
            return try capabilities()
        }
        if name == "surface_events" {
            guard let values = arguments.objectValue, Set(values.keys) == ["epoch", "after", "limit"],
                  let epoch = values["epoch"]?.stringValue, let raw = values["after"]?.stringValue, let cursor = UInt64(raw),
                  let rawLimit = values["limit"], let limit = RemoteArguments.exactInteger(rawLimit) else { throw PluginError(code: .invalidParameter) }
            return try .encoded(journal.read(epoch: epoch, after: cursor, limit: limit))
        }
        guard let id = arguments.objectValue?["instance_id"]?.stringValue, var binding = bindings[id] else { throw PluginError(code: .unsupported) }
        let response = try binding.call(name, arguments: arguments, context: context)
        var nextJournal = journal
        if binding.tools.first(where: { $0.name == name })?.isMutation == true {
            try nextJournal.append(instanceID: id, event: .init(code: name), at: context.time)
        }
        journal = nextJournal; bindings[id] = binding
        return response
    }
}
