import Foundation
import SurfacePluginContracts

/// Pure output policy. Host adapters authenticate actual samples and heartbeats before delivery.
/// Only the returned decision.command may reach a transport; a request is never an observation.
public struct ParameterOutputPlugin: ControlPlugin {
    public let manifest = PluginManifest(id: "output", version: "0.1.0", source: .simulation)
    public private(set) var gate: MotionSafetyGate
    public private(set) var isStarted = false
    public private(set) var requestedEnabled = false
    public private(set) var decision: MotionSafetyDecision?
    private var lastTime: Double?
    public init(limits: [MotionLimit], heartbeatTimeout: Double = 0.3, precision: MotionOutputPrecision = .double) throws {
        gate = try .init(limits: limits, heartbeatTimeout: heartbeatTimeout, precision: precision)
    }
    public var surface: SurfaceDescriptor {
        .init(actions: [.init(id: "output.disable", nameKey: "output.disable")],
              indicators: [.init(id: "output.state", nameKey: "output.state")])
    }
    public mutating func setConnected(_ connected: Bool, at time: Double) { gate.setConnected(connected, at: time) }
    public mutating func receiveHeartbeat(at time: Double) { gate.receiveHeartbeat(at: time) }
    public mutating func receiveActual(_ samples: [ParameterSample]) { gate.receiveActual(samples) }
    /// Trusted-host operation. The host authorizes enabling independently of remote request data.
    public mutating func setEnabled(_ enabled: Bool) throws {
        guard isStarted else { throw PluginError(code: .stopped) }
        requestedEnabled = enabled
    }
    @discardableResult
    public mutating func evaluate(targets: [ParameterID: Double], at time: Double) -> MotionSafetyDecision {
        let result = gate.evaluate(targets: targets, enabled: isStarted && requestedEnabled, at: time)
        decision = result
        return result
    }
    public func snapshot() -> PluginSnapshot {
        .init(isStarted: isStarted, indicators: ["output.state": .init(semantic: gate.status == .ready ? .active : gate.status == .disabled || gate.status == .disconnected ? .idle : .attention)])
    }
    public mutating func handle(_ input: PluginInput, at time: PluginTime) throws -> PluginUpdate {
        guard time.isFinite, lastTime.map({ time >= $0 }) ?? true else { throw PluginError(code: .invalidTime) }
        switch input {
        case .start: isStarted = true
        case .stop: requestedEnabled = false; _ = evaluate(targets: [:], at: time); isStarted = false
        case .advance: break
        case let .invoke(ref, _):
            guard isStarted else { throw PluginError(code: .stopped) }
            guard ref.pluginID == manifest.id && ref.actionID == "output.disable" else { throw PluginError(code: .unknownAction) }
            guard ref.index == nil else { throw PluginError(code: .indexOutOfRange) }
            requestedEnabled = false; _ = evaluate(targets: [:], at: time)
        case .parameterChanged:
            guard isStarted else { throw PluginError(code: .stopped) }
            throw PluginError(code: .invalidParameter)
        }
        lastTime = time
        return .init(indicators: snapshot().indicators)
    }
}
