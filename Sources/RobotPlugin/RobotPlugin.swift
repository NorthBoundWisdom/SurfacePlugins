import Foundation
import SurfacePluginContracts
import SimulationContracts

/// The typed simulator is also available to explicit domain bindings at the composition root.
public struct RobotPlugin: ControlPlugin {
    public var simulator: RobotSimulator
    public let manifest = PluginManifest(id: "robot", version: "0.1.0", source: .simulation)
    private var started = false
    private var stopping = false
    private var lastTime: Double?
    private var eventPolicy: SimulationEventPolicy
    public let maxCatchUpGap: Double
    public init(deviceID: String = "robot.reference", model: RobotModel = .reference, instanceID: String, motionEventInterval: Double = 0.25, maxCatchUpGap: Double = 2) throws {
        guard maxCatchUpGap.isFinite, maxCatchUpGap > 0 else { throw PluginError(code: .invalidParameter) }
        self.maxCatchUpGap = maxCatchUpGap
        simulator = try RobotSimulator(deviceID: deviceID, model: model, instanceID: instanceID)
        eventPolicy = try .init(initial: Self.eventState(simulator.snapshot()), motionInterval: motionEventInterval)
    }
    private static func eventState(_ snapshot: RobotSnapshot) -> SimulationEventState {
        .init(metadata: snapshot.metadata, motionActive: snapshot.motion_active, actual: snapshot.actual.map { $0.joints_rad + $0.joint_velocity_rad_s + $0.base_from_tool_row_major_m })
    }
    /// Typed host adapters call after simulator updates; same filter/throttle as handle.
    public mutating func simulationEvent(at time: PluginTime) throws -> PluginEvent? {
        try eventPolicy.update(Self.eventState(simulator.snapshot()), at: time, code: "robot.simulation.updated")
    }
    /// Remote adapters use the same lifecycle gate as the semantic surface.
    public var acceptsWrites: Bool { started && !stopping }
    /// Explicit simulation stepping may finish a pending stop, but never restarts an instance.
    public mutating func advanceSimulation(_ dt: Double) throws {
        try simulator.advance(dt)
        if stopping && !(simulator.snapshot().motion_active) { started = false; stopping = false }
    }
    public var surface: SurfaceDescriptor {
        .init(actions: [.init(id: "robot.stop", nameKey: "robot.stop")],
              indicators: [.init(id: "robot.state", nameKey: "robot.state")])
    }
    public func snapshot() -> PluginSnapshot {
        let s = simulator.snapshot()
        let semantic: IndicatorSemantic = s.metadata.fault != nil ? .fault : stopping ? .active : s.motion_active ? .active : s.stopped ? .stopped : .idle
        return .init(isStarted: started, indicators: ["robot.state": .init(semantic: semantic)])
    }
    public mutating func handle(_ input: PluginInput, at time: PluginTime) throws -> PluginUpdate {
        do { return try apply(input, at: time) }
        catch let failure as SimulationError { throw failure.pluginError }
    }
    private mutating func apply(_ input: PluginInput, at time: PluginTime) throws -> PluginUpdate {
        guard time.isFinite, lastTime.map({ time >= $0 }) ?? true else { throw PluginError(code: .invalidTime) }
        var next = self
        switch input {
        case .start:
            guard !stopping else { throw PluginError(code: .stopped) }
            next.started = true
        case .stop:
            next.simulator.revokeControl(); next.stopping = next.simulator.snapshot().motion_active
            next.started = next.stopping
        case .advance:
            if let previous = lastTime, started {
                let gap = time - previous
                if gap > maxCatchUpGap {
                    // Never integrate an unbounded host stall or invent post-stall movement.
                    let wasStopping = next.stopping
                    try next.simulator.fault("host_clock_gap", generation: next.simulator.control.generation)
                    if wasStopping { next.started = false }
                    next.stopping = false
                } else {
                    let end = next.simulator.control.time + gap
                    guard end.isFinite else { throw PluginError(code: .invalidTime) }
                    while next.simulator.control.time < end {
                        let dt = min(0.1, end - next.simulator.control.time)
                        try next.advanceSimulation(dt)
                    }
                }
                if next.stopping && !next.simulator.snapshot().motion_active { next.started = false; next.stopping = false }
            }
        case let .invoke(ref, _):
            guard started && !stopping else { throw PluginError(code: .stopped) }
            guard ref.pluginID == manifest.id && ref.actionID == "robot.stop" else { throw PluginError(code: .unknownAction) }
            guard ref.index == nil else { throw PluginError(code: .indexOutOfRange) }
            next.simulator.revokeControl()
        case .parameterChanged:
            guard started && !stopping else { throw PluginError(code: .stopped) }
            throw PluginError(code: .invalidParameter)
        }
        let event = try next.simulationEvent(at: time)
        next.lastTime = time; self = next
        let events = event.map { [$0] } ?? []
        return .init(indicators: snapshot().indicators, events: events)
    }
}
