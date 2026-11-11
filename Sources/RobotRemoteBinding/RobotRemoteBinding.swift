import Foundation
import SurfacePluginContracts
import RemoteToolContracts
import SimulationContracts
import RobotPlugin

public struct RobotRemoteBinding: RemoteBinding {
    public let instanceID: String
    public var plugin: RobotPlugin
    public var manifest: PluginManifest { plugin.manifest }
    public var surface: SurfaceDescriptor { plugin.surface }
    public func snapshot() -> PluginSnapshot { plugin.snapshot() }
    public mutating func handle(_ input: PluginInput, at time: PluginTime) throws -> PluginUpdate { try plugin.handle(input, at: time) }
    public init(instanceID: String, plugin: RobotPlugin) { self.instanceID = instanceID; self.plugin = plugin }
    private var actualSchema: JSONValue { let s = RemoteSchema.self; return s.object(["joints_rad": s.array(s.number), "joint_velocity_rad_s": s.array(s.number), "base_from_tool_row_major_m": s.array(s.number)]) }
    private var stateSchema: JSONValue {
        let s = RemoteSchema.self
        var fields: [String: JSONValue] = ["metadata": s.metadata, "actual": s.nullable(actualSchema), "stopped": s.boolean, "trace_dropped": s.integer]
        fields.merge(["target_joints_rad": s.nullable(s.array(s.number)), "motion_active": s.boolean]) { _, new in new }
        return s.object(fields)
    }
    public var tools: [RemoteToolDescriptor] {
        let s = RemoteSchema.self
        let base = ["instance_id": s.string]
        let generation = base.merging(["generation": s.string]) { _,new in new }
        let controlled = base.merging(s.proof) { _,new in new }
        var result: [RemoteToolDescriptor] = []
        func add(_ operation: String, _ fields: [String: JSONValue], _ output: JSONValue, _ mutation: Bool = true) {
            result.append(.init(name: "surface_robot_" + operation, fields: fields, output: output, isMutation: mutation))
        }
        add("snapshot", base, stateSchema, false)
        add("trace", base, s.array(s.object(["source": s.string, "generation": s.string, "sequence": s.integer, "simulated_time_s": s.number, "actual": actualSchema])), false)
        add("initialize", generation.merging(["joints_rad": s.array(s.number)]) { _,new in new }, stateSchema)
        add("acquire", generation.merging(["owner": s.string, "ttl_s": s.number]) { _,new in new }, s.grant)
        for operation in ["enable", "release", "stop"] { add(operation, controlled, stateSchema) }
        add("renew", controlled.merging(["ttl_s": s.number]) { _,new in new }, stateSchema)
        add("move", controlled.merging(["target_joints_rad": s.array(s.number), "duration_s": s.number, "valid_for_s": s.number]) { _,new in new }, stateSchema)
        add("advance", base.merging(["dt_s": s.number]) { _,new in new }, stateSchema)
        add("reset", generation, stateSchema)
        return result
    }
    private func proof(_ a: RemoteArguments) throws -> DeviceCommandProof {
        try .init(generation: a.string("generation"), token: a.string("control_token"), sequence: a.integer("sequence"))
    }
    public mutating func call(_ name: String, arguments: JSONValue, context: RemoteCallContext) throws -> JSONValue {
        do { return try execute(name, arguments: arguments, context: context) }
        catch let failure as SimulationError { throw RemoteFailure(code: failure.code, fields: ["reasonKey": .string(failure.reasonKey)]) }
        catch { throw RemoteFailure.from(error) }
    }
    private mutating func execute(_ name: String, arguments: JSONValue, context: RemoteCallContext) throws -> JSONValue {
        guard let tool = tools.first(where: { $0.name == name }) else { throw PluginError(code: .unsupported) }
        let a = try RemoteArguments(arguments, tool: tool, instanceID: instanceID)
        if tool.isMutation && name != "surface_robot_advance" {
            guard plugin.acceptsWrites else { throw PluginError(code: .stopped) }
        }
        var next = plugin
        let response: JSONValue
        switch name {
        case "surface_robot_snapshot": return try .encoded(plugin.simulator.snapshot())
        case "surface_robot_trace": return try .encoded(plugin.simulator.trace)
        case "surface_robot_initialize": try next.simulator.initialize(a.numbers("joints_rad"), generation: a.string("generation"))
        case "surface_robot_acquire":
            guard let token = context.controlToken else { throw PluginError(code: .permissionDenied) }
            let grant = try next.simulator.acquire(generation: a.string("generation"), owner: a.string("owner"), ttl: a.number("ttl_s"), controlToken: token)
            response = try .encoded(grant); plugin = next; return response
        case "surface_robot_enable": try next.simulator.enable(proof(a))
        case "surface_robot_renew": try next.simulator.renew(proof(a), ttl: a.number("ttl_s"))
        case "surface_robot_release": try next.simulator.release(proof(a))
        case "surface_robot_move": try next.simulator.move(proof(a), target: a.numbers("target_joints_rad"), duration: a.number("duration_s"), validFor: a.number("valid_for_s"))
        case "surface_robot_stop": try next.simulator.stop(proof(a))
        case "surface_robot_advance": try next.advanceSimulation(a.number("dt_s"))
        case "surface_robot_reset": try next.simulator.reset(generation: a.string("generation"))
        default: throw PluginError(code: .unsupported)
        }
        response = try .encoded(next.simulator.snapshot()); plugin = next; return response
    }
}
