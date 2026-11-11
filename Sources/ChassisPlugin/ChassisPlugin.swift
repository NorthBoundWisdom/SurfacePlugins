import Foundation
import SurfacePluginContracts
import SimulationContracts

/// The typed simulator is also available to explicit domain bindings at the composition root.
public struct ChassisPlugin: ControlPlugin {
    public var simulator: ChassisSimulator
    public let manifest = PluginManifest(id: "chassis", version: "0.1.0", source: .simulation)
    private var started = false
    private var stopping = false
    private var lastTime: Double?
    public init(deviceID: String = "chassis.reference", model: AckermannModel = .reference, instanceID: String) throws {
        simulator = try ChassisSimulator(deviceID: deviceID, model: model, instanceID: instanceID)
    }
    /// Remote adapters use the same lifecycle gate as the semantic surface.
    public var acceptsWrites: Bool { started && !stopping }
    /// Explicit simulation stepping may finish a pending stop, but never restarts an instance.
    public mutating func advanceSimulation(_ dt: Double) throws {
        try simulator.advance(dt)
        if stopping && !(!simulator.snapshot().stopped && simulator.snapshot().actual != nil) { started = false; stopping = false }
    }
    public var surface: SurfaceDescriptor {
        .init(actions: [.init(id: "chassis.stop", nameKey: "chassis.stop")],
              indicators: [.init(id: "chassis.state", nameKey: "chassis.state")])
    }
    public func snapshot() -> PluginSnapshot {
        let s = simulator.snapshot()
        let semantic: IndicatorSemantic = s.metadata.fault != nil ? .fault : stopping ? .active : !s.stopped && s.actual != nil ? .active : s.stopped ? .stopped : .idle
        return .init(isStarted: started, indicators: ["chassis.state": .init(semantic: semantic)])
    }
    public mutating func handle(_ input: PluginInput, at time: PluginTime) throws -> PluginUpdate {
        guard time.isFinite, lastTime.map({ time >= $0 }) ?? true else { throw PluginError(code: .invalidTime) }
        let previousRevision = simulator.control.revision
        var next = self
        switch input {
        case .start:
            guard !stopping else { throw PluginError(code: .stopped) }
            next.started = true
        case .stop:
            next.simulator.revokeControl(); next.stopping = !next.simulator.snapshot().stopped && next.simulator.snapshot().actual != nil
            next.started = next.stopping
        case .advance:
            if let previous = lastTime, started {
                let end = next.simulator.control.time + (time - previous)
                guard end.isFinite else { throw PluginError(code: .invalidTime) }
                while next.simulator.control.time < end {
                    let dt = min(0.1, end - next.simulator.control.time)
                    try next.advanceSimulation(dt)
                }
                if next.stopping && next.simulator.snapshot().stopped { next.started = false; next.stopping = false }
            }
        case let .invoke(ref, _):
            guard started && !stopping else { throw PluginError(code: .stopped) }
            guard ref.pluginID == manifest.id && ref.actionID == "chassis.stop" else { throw PluginError(code: .unknownAction) }
            guard ref.index == nil else { throw PluginError(code: .indexOutOfRange) }
            next.simulator.revokeControl()
        case .parameterChanged:
            guard started && !stopping else { throw PluginError(code: .stopped) }
            throw PluginError(code: .invalidParameter)
        }
        next.lastTime = time; self = next
        let events: [PluginEvent] = simulator.control.revision == previousRevision ? [] : [
            .init(code: "chassis.simulation.updated", fields: [
                "revision": .string(String(simulator.control.revision)), "simulated_time_s": .double(simulator.control.time)
            ])
        ]
        return .init(indicators: snapshot().indicators, events: events)
    }
}
