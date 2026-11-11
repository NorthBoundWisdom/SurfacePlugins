import Foundation
import SurfacePluginContracts
import RemoteToolContracts
import ParameterOutputPlugin

public struct OutputRemoteBinding: RemoteBinding {
    public let instanceID: String
    public var plugin: ParameterOutputPlugin
    public var manifest: PluginManifest { plugin.manifest }
    public var surface: SurfaceDescriptor { plugin.surface }
    public func snapshot() -> PluginSnapshot { plugin.snapshot() }
    public mutating func handle(_ input: PluginInput, at time: PluginTime) throws -> PluginUpdate { try plugin.handle(input, at: time) }
    public init(instanceID: String, plugin: ParameterOutputPlugin) { self.instanceID = instanceID; self.plugin = plugin }
    public var tools: [RemoteToolDescriptor] {
        let s = RemoteSchema.self
        let output = s.object(["started": s.boolean, "requested_enabled": s.boolean, "status": s.string])
        return ["snapshot", "enable", "disable"].map {
            .init(name: "surface_output_" + $0, fields: ["instance_id": s.string], output: output, isMutation: $0 != "snapshot")
        }
    }
    public mutating func call(_ name: String, arguments: JSONValue, context: RemoteCallContext) throws -> JSONValue {
        do { return try execute(name, arguments: arguments, context: context) }
        catch { throw RemoteFailure.from(error) }
    }
    private mutating func execute(_ name: String, arguments: JSONValue, context: RemoteCallContext) throws -> JSONValue {
        guard let tool = tools.first(where: { $0.name == name }) else { throw PluginError(code: .unsupported) }
        _ = try RemoteArguments(arguments, tool: tool, instanceID: instanceID)
        var next = plugin
        switch name {
        case "surface_output_snapshot": break
        case "surface_output_enable":
            guard context.permitsOutputEnable else { throw PluginError(code: .permissionDenied) }
            try next.setEnabled(true)
        case "surface_output_disable":
            _ = try next.handle(.invoke(.init(pluginID: "output", actionID: "output.disable"), origin: .remote), at: context.time)
        default: throw PluginError(code: .unsupported)
        }
        let result: JSONValue = .object(["started": .bool(next.isStarted), "requested_enabled": .bool(next.requestedEnabled), "status": .string(next.gate.status.rawValue)])
        plugin = next; return result
    }
}
