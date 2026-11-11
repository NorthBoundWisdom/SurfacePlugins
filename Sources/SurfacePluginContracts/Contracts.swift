import Foundation

public enum PluginErrorCode: String, Codable, Sendable {
    case invalidParameter, unsupported, permissionDenied, ownershipExpired, generationMismatch
    case notInitialized, outcomeUnknown, unknownAction, indexOutOfRange, stopped, invalidTime, invalidTransition
}
public struct PluginError: Error, Equatable, Codable, Sendable {
    public let code: PluginErrorCode
    public let fields: [String: JSONValue]
    public init(code: PluginErrorCode, fields: [String: JSONValue] = [:]) { self.code = code; self.fields = fields }
}
public enum PluginSource: String, Codable, Sendable { case mock, simulation, hardware }
public struct PluginManifest: Equatable, Codable, Sendable {
    public let id: PluginID
    public let version: String
    public let contractVersion: String
    public let source: PluginSource
    public init(id: PluginID, version: String, contractVersion: String = "1.0", source: PluginSource) {
        self.id = id; self.version = version; self.contractVersion = contractVersion; self.source = source
    }
}
/// Seconds on a caller-owned monotonic clock. Plugins reject nonfinite or regressing times.
public typealias PluginTime = Double
public enum InputOrigin: String, Codable, Sendable { case hardware, interface, remote }
public struct ActionReference: Equatable, Codable, Sendable {
    public let pluginID: PluginID
    public let actionID: ActionID
    public let index: Int?
    public init(pluginID: PluginID, actionID: ActionID, index: Int? = nil) { self.pluginID = pluginID; self.actionID = actionID; self.index = index }
}
public struct ActionDescriptor: Equatable, Codable, Sendable {
    public let id: ActionID
    public let nameKey: String
    /// Nil means unindexed; indexed actions accept the closed range 1...indexCount.
    public let indexCount: Int?
    public init(id: ActionID, nameKey: String, indexCount: Int? = nil) { self.id = id; self.nameKey = nameKey; self.indexCount = indexCount }
}
public struct IndicatorDescriptor: Equatable, Codable, Sendable {
    public let id: IndicatorID
    public let nameKey: String
    public init(id: IndicatorID, nameKey: String) { self.id = id; self.nameKey = nameKey }
}
public enum IndicatorSemantic: String, Codable, Sendable, CaseIterable { case idle, queued, active, attention, done, stopped, fault }
public struct IndicatorState: Equatable, Codable, Sendable {
    public let semantic: IndicatorSemantic
    public let progress: Double?
    public init(semantic: IndicatorSemantic, progress: Double? = nil) { self.semantic = semantic; self.progress = progress }
}
public struct SurfaceDescriptor: Equatable, Codable, Sendable {
    public let parameters: [ParameterDefinition]
    public let actions: [ActionDescriptor]
    public let indicators: [IndicatorDescriptor]
    public init(parameters: [ParameterDefinition] = [], actions: [ActionDescriptor] = [], indicators: [IndicatorDescriptor] = []) {
        self.parameters = parameters; self.actions = actions; self.indicators = indicators
    }
}
public enum PluginInput: Equatable, Sendable {
    case start, stop, advance
    case invoke(ActionReference, origin: InputOrigin)
    case parameterChanged(ParameterID, Double, origin: InputOrigin)
}
public struct ParameterWrite: Equatable, Codable, Sendable {
    public let id: ParameterID
    public let value: Double
    public let origin: InputOrigin
    public init(id: ParameterID, value: Double, origin: InputOrigin) { self.id = id; self.value = value; self.origin = origin }
}
public struct PluginEvent: Equatable, Codable, Sendable {
    public let code: String
    public let fields: [String: JSONValue]
    public init(code: String, fields: [String: JSONValue] = [:]) { self.code = code; self.fields = fields }
}
public struct PluginUpdate: Equatable, Sendable {
    public var parameterWrites: [ParameterWrite]
    public var indicators: [IndicatorID: IndicatorState]
    public var events: [PluginEvent]
    public init(parameterWrites: [ParameterWrite] = [], indicators: [IndicatorID: IndicatorState] = [:], events: [PluginEvent] = []) {
        self.parameterWrites = parameterWrites; self.indicators = indicators; self.events = events
    }
}
/// Generic host-facing state; domain-specific state remains available on each plugin's typed API.
public struct PluginSnapshot: Equatable, Sendable {
    public let isStarted: Bool
    public let indicators: [IndicatorID: IndicatorState]
    public init(isStarted: Bool, indicators: [IndicatorID: IndicatorState] = [:]) { self.isStarted = isStarted; self.indicators = indicators }
}
public protocol ControlPlugin: Sendable {
    var manifest: PluginManifest { get }
    var surface: SurfaceDescriptor { get }
    mutating func handle(_ input: PluginInput, at time: PluginTime) throws -> PluginUpdate
    func snapshot() -> PluginSnapshot
}
