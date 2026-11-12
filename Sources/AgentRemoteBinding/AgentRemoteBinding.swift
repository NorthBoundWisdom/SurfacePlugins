import Foundation
import SurfacePluginContracts
import RemoteToolContracts
import AgentPlugin

public struct AgentRemoteBinding: RemoteBinding {
    public static let defaultInstanceID = "agent.mock"
    public let instanceID: String
    public var plugin: AgentPlugin
    public var surface: SurfaceDescriptor { plugin.surface }
    public func snapshot() -> PluginSnapshot { plugin.snapshot() }
    public mutating func handle(_ input: PluginInput, at time: PluginTime) throws -> PluginUpdate { try plugin.handle(input, at: time) }
    public var manifest: PluginManifest { plugin.manifest }
    public init(instanceID: String, plugin: AgentPlugin) { self.instanceID = instanceID; self.plugin = plugin }
    public var tools: [RemoteToolDescriptor] {
        let s = RemoteSchema.self
        let output = s.object(["slots": s.array(s.object(["id": s.integer, "state": s.string, "progress": s.number, "status_key": s.string, "last_updated": s.number]))])
        return [RemoteToolDescriptor(name: "surface_agent_snapshot", fields: ["instance_id": s.string], output: output, isMutation: false)] + ["primary", "interrupt"].map {
            .init(name: "surface_agent_" + $0, fields: ["instance_id": s.string, "slot": s.integer], output: output, isMutation: true)
        }
    }
    public mutating func call(_ name: String, arguments: JSONValue, context: RemoteCallContext) throws -> JSONValue {
        do { return try execute(name, arguments: arguments, context: context) }
        catch { throw RemoteFailure.from(error) }
    }
    private mutating func execute(_ name: String, arguments: JSONValue, context: RemoteCallContext) throws -> JSONValue {
        guard let tool = tools.first(where: { $0.name == name }) else { throw PluginError(code: .unsupported) }
        let a = try RemoteArguments(arguments, tool: tool, instanceID: instanceID)
        var next = plugin
        switch name {
        case "surface_agent_snapshot": break
        case "surface_agent_primary": _ = try next.handle(.invoke(.init(pluginID: AgentPlugin.pluginID, actionID: AgentPlugin.primaryActionID, index: a.integer("slot")), origin: .remote), at: context.time)
        case "surface_agent_interrupt": _ = try next.interrupt(a.integer("slot"), at: context.time)
        default: throw PluginError(code: .unsupported)
        }
        let result: JSONValue = .object(["slots": .array(next.slots.map { .object(["id": .number($0.id), "state": .string($0.state.rawValue), "progress": .double($0.progress), "status_key": .string($0.statusKey), "last_updated": .double($0.lastUpdated)]) })])
        plugin = next
        return result
    }
}
