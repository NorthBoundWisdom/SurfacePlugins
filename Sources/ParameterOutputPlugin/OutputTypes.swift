import Foundation
import SurfacePluginContracts

public struct MotionSafetyError: Error, Equatable, Sendable {
    public let reason: String
    public var code: String { "invalid_argument" }
    public init(_ reason: String) { self.reason = reason }
}

public enum MotionGateStatus: String, Codable, Equatable, Sendable {
    case disconnected, disabled, waitingHeartbeat, heartbeatExpired, waitingActual, actualOutOfLimits
    case invalidTarget, invalidActual, clockError, waitingRearm, ready
}

public struct MotionSafetySnapshot: Equatable, Sendable {
    public let status: MotionGateStatus
    public let reason: String
    public let outputs: [ParameterID: Double]
    public let actual: [ParameterID: Double]
    public let limited: Bool
    public let baseline: [ParameterID: Double]
    public init(status: MotionGateStatus, reason: String, outputs: [ParameterID: Double],
                actual: [ParameterID: Double], limited: Bool, baseline: [ParameterID: Double] = [:])
    {
        self.baseline = baseline
        self.status = status; self.reason = reason; self.outputs = outputs
        self.actual = actual; self.limited = limited
    }
}
