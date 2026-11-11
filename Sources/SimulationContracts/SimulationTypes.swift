import Foundation
import SurfacePluginContracts

public typealias ProviderSource = PluginSource

public struct SimulationError: Error, Equatable, Sendable {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
    public var reasonKey: String { message }
}

public struct DeviceCommandProof: Sendable {
    public let generation: String
    public let token: String
    public let sequence: Int
    public init(generation: String, token: String, sequence: Int) {
        self.generation = generation; self.token = token; self.sequence = sequence
    }
}

public struct DeviceControlGrant: Codable, Sendable {
    public let generation: String
    public let control_token: String
    public let expires_at_s: Double
    public init(generation: String, token: String, expires: Double) {
        self.generation = generation; control_token = token; expires_at_s = expires
    }
}

public struct DeviceMetadata: Codable, Sendable {
    public let schema_version: Int
    public let device_id: String
    public let model_id: String
    public let frame_id: String
    public let source: ProviderSource
    public let generation: String
    public let sequence: UInt64
    public let simulated_time_s: Double
    public let state: String
    public let initialized: Bool
    public let enabled: Bool
    public let fault: String?
    public let control_owner: String?
    public let control_expires_at_s: Double?
    public let last_command_sequence: Int

    public init(device: String, model: String, generation: String, sequence: UInt64, time: Double,
                state: String, initialized: Bool, enabled: Bool, fault: String?, owner: String?,
                expires: Double?, commandSequence: Int, frame: String)
    {
        schema_version = 1; device_id = device; model_id = model; source = .simulation
        frame_id = frame
        self.generation = generation; self.sequence = sequence; simulated_time_s = time
        self.state = state; self.initialized = initialized; self.enabled = enabled; self.fault = fault
        control_owner = owner; control_expires_at_s = expires; last_command_sequence = commandSequence
    }
}

public enum SimulationValidation {
    public static func require(_ condition: Bool, _ code: String = "invalid_argument", _ message: String) throws {
        if !condition { throw SimulationError(code, message) }
    }

    public static func finite(_ values: [Double]) -> Bool { values.allSatisfy(\.isFinite) }
}
