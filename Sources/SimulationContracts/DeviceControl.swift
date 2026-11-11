import SurfacePluginContracts
import Foundation

/// A value owned separately by each device. No global control, model or clock state.
public struct DeviceControl: Sendable {
    public private(set) var generation: String
    private let namespace: String
    private var generationCounter: UInt64 = 0
    private var grantCounter: UInt64 = 0
    public private(set) var revision: UInt64 = 0
    public private(set) var time: Double = 0
    public private(set) var initialized = false
    public private(set) var enabled = false
    public private(set) var fault: String?
    public private(set) var lastCommandSequence = 0
    public private(set) var owner: String?
    public private(set) var expires: Double?
    private var token: String?

    public init(namespace: String) { self.namespace = namespace; generation = namespace + ".generation.0" }
    private mutating func nextGeneration() -> String { generationCounter &+= 1; return namespace + ".generation.\(generationCounter)" }
    public mutating func changed() { revision &+= 1 }

    public func checkGeneration(_ expected: String) throws {
        try SimulationValidation.require(expected == generation, "stale_generation", "simulation.the_device_generation_changed")
    }

    public mutating func initialize(expectedGeneration: String) throws {
        try checkGeneration(expectedGeneration)
        try SimulationValidation.require(fault == nil, "faulted", "simulation.clear_the_simulated_fault_before_initialization")
        generation = nextGeneration(); initialized = true; enabled = false
        owner = nil; expires = nil; token = nil; lastCommandSequence = 0; changed()
    }

    public mutating func acquire(expectedGeneration: String, owner: String, ttl: Double) throws -> DeviceControlGrant {
        try checkGeneration(expectedGeneration)
        try SimulationValidation.require(initialized, "not_initialized", "simulation.initialize_the_device_first")
        try SimulationValidation.require(fault == nil, "faulted", "simulation.the_device_has_a_fault")
        try SimulationValidation.require(
            !owner.isEmpty && owner.utf8.count <= 128 && !owner.unicodeScalars.contains(where: { $0.value < 32 }),
            "invalid_argument",
            "simulation.invalid_control_owner"
        )
        try SimulationValidation.require(
            ttl.isFinite && ttl >= 0.1 && ttl <= 5,
            "invalid_argument",
            "simulation.control_ttl_must_be_within_0_1_5_seconds"
        )
        try SimulationValidation.require(token == nil, "busy", "simulation.control_is_already_owned")
        grantCounter &+= 1
        let value = namespace + ".grant.\(grantCounter)"
        self.owner = owner; expires = time + ttl; token = value; lastCommandSequence = 0; changed()
        return DeviceControlGrant(generation: generation, token: value, expires: time + ttl)
    }

    public func validate(_ proof: DeviceCommandProof) throws {
        try checkGeneration(proof.generation)
        try SimulationValidation.require(initialized, "not_initialized", "simulation.initialize_the_device_first")
        try SimulationValidation.require(fault == nil, "faulted", "simulation.the_device_has_a_fault")
        try SimulationValidation.require(
            token != nil && expires.map { $0 > time } == true,
            "control_expired",
            "simulation.control_is_absent_or_expired"
        )
        try SimulationValidation.require(
            proof.token == token,
            "invalid_control",
            "simulation.control_token_does_not_own_this_device"
        )
        try SimulationValidation.require(
            proof.sequence > lastCommandSequence,
            "stale_sequence",
            "simulation.command_sequence_must_strictly_increase"
        )
    }

    public mutating func accept(_ proof: DeviceCommandProof) throws {
        try validate(proof); lastCommandSequence = proof.sequence; changed()
    }

    public mutating func enable(_ proof: DeviceCommandProof) throws { try accept(proof); enabled = true; changed() }
    public mutating func disable() { enabled = false; changed() }
    public mutating func revoke() {
        enabled = false; owner = nil; expires = nil; token = nil
        generation = nextGeneration(); lastCommandSequence = 0; changed()
    }

    public mutating func release(_ proof: DeviceCommandProof) throws {
        try accept(proof); owner = nil; expires = nil; token = nil; enabled = false; changed()
    }

    public mutating func renew(_ proof: DeviceCommandProof, ttl: Double) throws {
        try SimulationValidation.require(
            ttl.isFinite && ttl >= 0.1 && ttl <= 5,
            "invalid_argument",
            "simulation.invalid_control_ttl"
        )
        try accept(proof); expires = time + ttl; changed()
    }

    /// The caller splits integration at the expiry boundary before revoking control.
    @discardableResult public mutating func advance(_ dt: Double) throws -> Bool {
        try SimulationValidation.require(
            dt.isFinite && dt > 0 && dt <= 0.1,
            "invalid_argument",
            "Advance must be within (0, 0.1] seconds"
        )
        let next = time + dt
        try SimulationValidation.require(
            next.isFinite && next > time,
            "invalid_argument",
            "simulation.time_step_is_not_representable_at_this_simulation_time"
        )
        time = next
        let expired = expireIfDue()
        changed(); return expired
    }

    @discardableResult public mutating func expireIfDue() -> Bool {
        guard let expires, time >= expires else { return false }
        owner = nil; self.expires = nil; token = nil; enabled = false; changed(); return true
    }

    public mutating func injectFault(_ code: String, expectedGeneration: String) throws {
        try checkGeneration(expectedGeneration)
        try SimulationValidation.require(
            !code.isEmpty && code.utf8.count <= 64 && code.unicodeScalars
                .allSatisfy {
                    $0.isASCII && ($0.properties.isAlphabetic || CharacterSet.decimalDigits.contains($0) || $0 == "_")
                },
            "invalid_argument",
            "simulation.invalid_simulated_fault_code"
        )
        fault = code; enabled = false; owner = nil; expires = nil; token = nil
        generation = nextGeneration(); lastCommandSequence = 0; changed()
    }

    public mutating func reset(expectedGeneration: String) throws {
        try checkGeneration(expectedGeneration)
        generation = nextGeneration(); initialized = false; enabled = false; fault = nil
        owner = nil; expires = nil; token = nil; lastCommandSequence = 0; changed()
    }

    public func metadata(device: String, model: String, state: String, frame: String) -> DeviceMetadata {
        DeviceMetadata(device: device, model: model, generation: generation, sequence: revision, time: time,
                       state: state, initialized: initialized, enabled: enabled, fault: fault,
                       owner: owner, expires: expires, commandSequence: lastCommandSequence, frame: frame)
    }
}
