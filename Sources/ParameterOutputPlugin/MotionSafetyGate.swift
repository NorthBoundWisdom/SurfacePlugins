import SurfacePluginContracts
import Foundation

public struct MotionLimit: Codable, Equatable, Sendable, Identifiable {
    public let id: ParameterID
    public var minimum: Double
    public var maximum: Double
    public var maximumChange: Double
    public var maximumVelocity: Double

    public init(id: ParameterID, minimum: Double, maximum: Double, maximumChange: Double, maximumVelocity: Double) {
        self.id = id; self.minimum = minimum; self.maximum = maximum
        self.maximumChange = maximumChange; self.maximumVelocity = maximumVelocity
    }

    public func validate() throws {
        guard minimum.isFinite, maximum.isFinite, minimum < maximum, (maximum - minimum).isFinite,
              maximumChange.isFinite, maximumChange > 0, maximumVelocity.isFinite, maximumVelocity > 0
        else {
            throw MotionSafetyError("output.reason.001")
        }
    }
}

public struct ParameterSample: Equatable, Sendable {
    public let id: ParameterID
    public let value: Double
    public let receivedAt: PluginTime
    public init(id: ParameterID, value: Double, receivedAt: PluginTime) {
        self.id = id; self.value = value; self.receivedAt = receivedAt
    }
}

public struct ParameterOutputFrame: Equatable, Sendable {
    public let enabled: Bool
    public let values: [ParameterID: Double]
    public init(enabled: Bool, values: [ParameterID: Double]) { self.enabled = enabled; self.values = values }
}

public enum MotionOutputPrecision: Sendable { case double, float32 }

public struct MotionSafetyDecision: Equatable, Sendable {
    public let status: MotionGateStatus
    public let reason: String
    public let command: ParameterOutputFrame?
    public let limited: Bool
}

/// Clock-injected safety state; no network or UI. Only returned commands may reach a sink.
public struct MotionSafetyGate: Sendable {
    public let limits: [MotionLimit]
    public let heartbeatTimeout: TimeInterval
    public private(set) var status: MotionGateStatus = .disconnected
    public private(set) var outputs: [ParameterID: Double] = [:]
    public private(set) var baseline: [ParameterID: Double] = [:]
    private let precision: MotionOutputPrecision
    private var observedDisabled = false
    private var armed = false
    private var connected = false
    private var connectedAt: PluginTime?
    private var heartbeat: PluginTime?
    private var actual: [ParameterID: ParameterSample] = [:]
    private var lastStep: PluginTime?
    private var fault: String?
    private var faultStatus: MotionGateStatus = .invalidActual

    public init(limits: [MotionLimit], heartbeatTimeout: TimeInterval = 0.3,
                precision: MotionOutputPrecision = .double) throws
    {
        guard !limits.isEmpty, Set(limits.map(\.id)).count == limits.count,
              heartbeatTimeout.isFinite, heartbeatTimeout > 0, heartbeatTimeout <= 0.45
        else {
            throw MotionSafetyError("output.reason.002")
        }
        for limit in limits { try limit.validate() }
        self.limits = limits
        self.heartbeatTimeout = heartbeatTimeout
        self.precision = precision
    }

    public mutating func setConnected(_ value: Bool, at now: PluginTime) {
        guard now.isFinite else { fault = "output.clock.nonfinite"; faultStatus = .clockError; return }
        if value != connected {
            observedDisabled = false
            armed = false
            heartbeat = nil
            actual.removeAll()
            lastStep = now
            connectedAt = value ? now : nil
            fault = nil
            faultStatus = .invalidActual
        }
        connected = value
    }

    public mutating func receiveHeartbeat(at now: PluginTime) {
        guard connected else { return }
        guard now.isFinite else { fault = "output.clock.nonfinite"; faultStatus = .clockError; return }
        if let heartbeat, now < heartbeat { fault = "output.clock.regressed"; faultStatus = .clockError; return }
        if let heartbeat, now - heartbeat >= heartbeatTimeout { armed = false; observedDisabled = false }
        heartbeat = now
    }

    public mutating func receiveActual(_ samples: [ParameterSample]) {
        let allowed = Set(limits.map(\.id))
        for sample in samples where allowed.contains(sample.id) {
            guard sample.value.isFinite, sample.receivedAt.isFinite else { fault = "output.reason.003"; continue }
            if let old = actual[sample.id], sample.receivedAt < old.receivedAt { continue }
            actual[sample.id] = sample
        }
    }

    public mutating func evaluate(targets: [ParameterID: Double], enabled: Bool, at now: PluginTime) -> MotionSafetyDecision {
        let previous = status
        guard now.isFinite else {
            status = .clockError; fault = "output.clock.nonfinite"; faultStatus = .clockError
            armed = false; observedDisabled = false
            return MotionSafetyDecision(status: .clockError, reason: "output.clock.nonfinite", command: connected ? .init(enabled: false, values: [:]) : nil, limited: false)
        }
        let elapsed = lastStep.map { (now - $0) } ?? 0
        lastStep = now
        func stopped(_ state: MotionGateStatus, _ reason: String) -> MotionSafetyDecision {
            MotionSafetyDecision(status: state, reason: reason,
                                 command: previous == .ready || (connected && heartbeat != nil) ? ParameterOutputFrame(
                                     enabled: false,
                                     values: [:]
                                 ) : nil, limited: false)
        }
        if elapsed < 0 { fault = "output.reason.004"; faultStatus = .clockError }
        let closed: MotionSafetyDecision?
        if !connected { closed = stopped(.disconnected, "output.reason.005") }
        else if let fault { closed = stopped(faultStatus, fault) }
        else if let heartbeat {
            let age = (now - heartbeat)
            if age < 0 { closed = stopped(.clockError, "output.reason.006") }
            else if age >= heartbeatTimeout { closed = stopped(.heartbeatExpired, "output.reason.007") }
            else { closed = nil }
        } else if connectedAt.map({ (now - $0) >= heartbeatTimeout }) == true {
            closed = stopped(.heartbeatExpired, "output.reason.008")
        } else { closed = stopped(.waitingHeartbeat, "output.reason.009") }
        if let closed { armed = false; observedDisabled = false; status = closed.status; return closed }
        if !enabled {
            armed = false
            observedDisabled = true
            let result = stopped(.disabled, "output.reason.010")
            status = result.status
            return result
        }

        for limit in limits {
            guard let sample = actual[limit.id], (now - sample.receivedAt) >= 0,
                  (now - sample.receivedAt) < heartbeatTimeout
            else {
                let result = stopped(.waitingActual, "output.reason.011")
                armed = false; observedDisabled = false
                status = result.status; return result
            }
            guard sample.value >= limit.minimum, sample.value <= limit.maximum else {
                let result = stopped(.actualOutOfLimits, "output.reason.012")
                armed = false; observedDisabled = false
                status = result.status; return result
            }
            guard let target = targets[limit.id], target.isFinite else {
                let result = stopped(.invalidTarget, "output.reason.013")
                armed = false; observedDisabled = false
                status = result.status; return result
            }
        }
        if !armed {
            guard observedDisabled else {
                let result = stopped(.waitingRearm, "output.reason.014")
                status = result.status
                return result
            }
            armed = true
            observedDisabled = false
        }
        if previous != .ready {
            outputs = Dictionary(uniqueKeysWithValues: limits.map { ($0.id, actual[$0.id]!.value) })
            baseline = outputs
        }
        var limited = false
        for limit in limits {
            let previousOutput = outputs[limit.id]!
            let target = targets[limit.id]!
            let distance = previous == .ready ? min(limit.maximumChange, limit.maximumVelocity * elapsed) : 0
            let lower = max(limit.minimum, previousOutput - distance)
            let upper = min(limit.maximum, previousOutput + distance)
            let candidate = min(max(target, lower), upper)
            let next = quantized(candidate, lower: lower, upper: upper, previous: previousOutput)
            outputs[limit.id] = next
            limited = limited || next != target
        }
        status = .ready
        let command = ParameterOutputFrame(enabled: true, values: outputs)
        return MotionSafetyDecision(status: .ready, reason: limited ? "output.reason.015" : "output.reason.016",
                                    command: command, limited: limited)
    }

    private func quantized(_ value: Double, lower: Double, upper: Double, previous: Double) -> Double {
        guard precision == .float32 else { return value }
        var result = Float(value)
        if Double(result) > upper { result = result.nextDown }
        if Double(result) < lower { result = result.nextUp }
        let output = Double(result)
        // If a cycle's permitted interval is narrower than a float ULP, hold position.
        return output.isFinite && output >= lower && output <= upper ? output : previous
    }
}
