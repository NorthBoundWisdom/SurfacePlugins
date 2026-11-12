import Foundation
import SurfacePluginContracts

/// Observable simulation facts, intentionally excluding clock/revision/command/trace bookkeeping.
public struct SimulationEventState: Equatable, Sendable {
    private let generation: String
    private let phase: String
    private let initialized: Bool
    private let enabled: Bool
    private let fault: String?
    private let owner: String?
    private let expires: Double?
    private let motionActive: Bool
    private let actual: [Double]?
    public init(metadata: DeviceMetadata, motionActive: Bool, actual: [Double]?) {
        generation = metadata.generation; phase = metadata.state; initialized = metadata.initialized
        enabled = metadata.enabled; fault = metadata.fault; owner = metadata.control_owner
        expires = metadata.control_expires_at_s; self.motionActive = motionActive; self.actual = actual
    }
    fileprivate func criticalChange(from old: Self) -> Bool {
        generation != old.generation || phase != old.phase || initialized != old.initialized || enabled != old.enabled ||
        fault != old.fault || owner != old.owner || expires != old.expires || motionActive != old.motionActive
    }
    fileprivate var fields: [String: JSONValue] { ["phase": .string(phase), "motion_active": .bool(motionActive)] }
}

/// Critical transitions are immediate; continuous actual changes are coalesced per instance.
public struct SimulationEventPolicy: Sendable {
    public let motionInterval: Double
    private var observed: SimulationEventState
    private var lastUpdateTime: Double?
    private var lastMotionEventTime: Double?
    public init(initial: SimulationEventState, motionInterval: Double = 0.25) throws {
        guard motionInterval.isFinite, motionInterval >= 0.25 else { throw PluginError(code: .invalidParameter) }
        observed = initial; self.motionInterval = motionInterval
    }
    public mutating func update(_ state: SimulationEventState, at time: PluginTime, code: String) throws -> PluginEvent? {
        guard time.isFinite, lastUpdateTime.map({ time >= $0 }) ?? true else { throw PluginError(code: .invalidTime) }
        let critical = state.criticalChange(from: observed)
        let actualChanged = state != observed
        let due = lastMotionEventTime.map { time >= $0 + motionInterval } ?? true
        observed = state; lastUpdateTime = time
        guard critical || (actualChanged && due) else { return nil }
        lastMotionEventTime = time
        return .init(code: code, fields: state.fields)
    }
}
