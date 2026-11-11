import SurfacePluginContracts
import SimulationContracts
import Foundation

public struct AckermannModel: Codable, Sendable {
    public let id: String
    public let wheelbase_m: Double
    public let track_m: Double
    public let wheel_radius_m: Double
    public let maximum_speed_m_s: Double
    public let maximum_acceleration_m_s2: Double
    public let maximum_steering_rad: Double
    public let maximum_steering_rate_rad_s: Double
    public init(id: String, wheelbase_m: Double, track_m: Double, wheel_radius_m: Double,
                maximum_speed_m_s: Double, maximum_acceleration_m_s2: Double,
                maximum_steering_rad: Double, maximum_steering_rate_rad_s: Double) {
        self.id = id; self.wheelbase_m = wheelbase_m; self.track_m = track_m; self.wheel_radius_m = wheel_radius_m
        self.maximum_speed_m_s = maximum_speed_m_s; self.maximum_acceleration_m_s2 = maximum_acceleration_m_s2
        self.maximum_steering_rad = maximum_steering_rad; self.maximum_steering_rate_rad_s = maximum_steering_rate_rad_s
    }
    public static var reference: AckermannModel {
        AckermannModel(id: "reference-ackermann-v1", wheelbase_m: 1, track_m: 0.6, wheel_radius_m: 0.1,
                       maximum_speed_m_s: 1, maximum_acceleration_m_s2: 1,
                       maximum_steering_rad: 0.5, maximum_steering_rate_rad_s: 1)
    }

    public func validate() throws {
        let values = [
            wheelbase_m,
            track_m,
            wheel_radius_m,
            maximum_speed_m_s,
            maximum_acceleration_m_s2,
            maximum_steering_rad,
            maximum_steering_rate_rad_s
        ]
        try SimulationValidation.require(values.allSatisfy { $0.isFinite && $0 > 0 } && maximum_steering_rad < .pi / 2,
                                       "invalid_argument", "simulation.invalid_ackermann_model")
    }
}

public struct ChassisActual: Codable, Sendable {
    public let pose_m_rad: [Double]
    public let speed_m_s: Double
    public let steering_angle_rad: Double
    public let yaw_rate_rad_s: Double
    public let rear_wheel_velocity_rad_s: [Double]
}

public struct ChassisSnapshot: Codable, Sendable {
    public let metadata: DeviceMetadata
    public let actual: ChassisActual?
    public let target_speed_m_s: Double
    public let target_steering_angle_rad: Double
    public let command_expires_at_s: Double?
    public let stopped: Bool
    public let trace_dropped: UInt64
    private enum CodingKeys: String,
        CodingKey
    { case metadata, actual, target_speed_m_s, target_steering_angle_rad, command_expires_at_s, stopped,
           trace_dropped
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(metadata, forKey: .metadata); try c.encode(actual, forKey: .actual)
        try c.encode(target_speed_m_s, forKey: .target_speed_m_s); try c.encode(
            target_steering_angle_rad,
            forKey: .target_steering_angle_rad
        )
        try c.encode(command_expires_at_s, forKey: .command_expires_at_s); try c.encode(stopped, forKey: .stopped)
        try c.encode(trace_dropped, forKey: .trace_dropped)
    }
}

public struct ChassisTraceSample: Codable, Sendable {
    public let source: ProviderSource
    public let generation: String
    public let sequence: UInt64
    public let simulated_time_s: Double
    public let actual: ChassisActual
}

public struct ChassisSimulator: Sendable {
    public let deviceID: String
    public let model: AckermannModel
    public private(set) var control: DeviceControl
    public private(set) var trace: [ChassisTraceSample] = []
    private var pose: [Double]?
    private var speed = 0.0
    private var steering = 0.0
    private var targetSpeed = 0.0
    private var targetSteering = 0.0
    private var commandExpiry: Double?
    private var phase = "uninitialized"
    private var dropped: UInt64 = 0

    public init(deviceID: String = "chassis.reference", model: AckermannModel = .reference, instanceID: String) throws {
        try model.validate(); self.deviceID = deviceID; self.model = model; control = DeviceControl(namespace: instanceID)
    }

    public mutating func initialize(_ pose: [Double], generation: String) throws {
        try SimulationValidation.require(
            speed == 0 && abs(steering - targetSteering) <= 1e-12,
            "busy",
            "simulation.stop_before_initializing_the_chassis"
        )
        try SimulationValidation.require(
            pose.count == 3 && SimulationValidation.finite(pose),
            "invalid_argument",
            "simulation.finite_x_y_yaw_pose_required"
        )
        try control.initialize(expectedGeneration: generation)
        self.pose = pose; speed = 0; steering = 0; targetSpeed = 0; targetSteering = 0
        commandExpiry = nil; phase = "disabled"; trace.removeAll(); dropped = 0; record()
    }

    public mutating func acquire(generation: String, owner: String, ttl: Double, controlToken: String) throws -> DeviceControlGrant {
        try control.acquire(expectedGeneration: generation, owner: owner, ttl: ttl, controlToken: controlToken)
    }

    public mutating func enable(_ proof: DeviceCommandProof) throws {
        try control.validate(proof)
        try SimulationValidation.require(snapshot().stopped, "busy", "simulation.the_chassis_is_still_stopping_or_steering")
        try control.enable(proof); phase = "idle"
    }

    public mutating func renew(_ proof: DeviceCommandProof, ttl: Double) throws { try control.renew(proof, ttl: ttl) }
    public mutating func release(_ proof: DeviceCommandProof) throws {
        try SimulationValidation.require(snapshot().stopped, "busy", "simulation.stop_before_releasing_chassis_control")
        try control.release(proof); targetSpeed = 0; targetSteering = steering; commandExpiry = nil; phase = "disabled"
    }

    public mutating func drive(_ proof: DeviceCommandProof, speed: Double, steering: Double, validFor: Double) throws {
        try control.validate(proof)
        try SimulationValidation.require(control.enabled, "disabled", "simulation.enable_the_chassis_before_motion")
        try SimulationValidation.require(phase != "stopping", "busy", "simulation.a_requested_stop_must_finish_before_a_new_drive")
        try SimulationValidation.require(
            speed.isFinite && steering.isFinite && abs(speed) <= model.maximum_speed_m_s && abs(steering) <= model
                .maximum_steering_rad,
            "invalid_argument",
            "simulation.speed_or_steering_exceeds_model_limits"
        )
        try SimulationValidation.require(
            validFor.isFinite && validFor > 0 && validFor <= 5 && (control.expires ?? 0) - control.time >= validFor,
            "command_expired",
            "simulation.drive_must_fit_the_control_validity_window"
        )
        try control.accept(proof); targetSpeed = speed; targetSteering = steering
        commandExpiry = control.time + validFor; phase = "running"
    }

    public mutating func stop(_ proof: DeviceCommandProof, disable: Bool = false) throws {
        try control.accept(proof); if disable { control.disable() }; beginStop()
    }

    public mutating func revokeControl() { control.revoke(); beginStop() }
    private mutating func beginStop() {
        targetSpeed = 0; targetSteering = steering; commandExpiry = nil
        phase = abs(speed) > 1e-12 ? "stopping" : (control.enabled ? "stopped" : "disabled")
    }

    public mutating func advance(_ dt: Double) throws {
        try SimulationValidation.require(
            dt.isFinite && dt > 0 && dt <= 0.1,
            "invalid_argument",
            "simulation.invalid_chassis_time_step"
        )
        try SimulationValidation.require(
            (control.time + dt).isFinite && control.time + dt > control.time,
            "invalid_argument",
            "simulation.time_step_is_not_representable"
        )
        let endTime = control.time + dt
        var remaining = dt
        while remaining > 0 {
            if control.expireIfDue() { beginStop() }
            if let expiry = commandExpiry, control.time >= expiry { beginStop() }
            if control.time >= endTime { break }
            let untilLease = control.expires.map { max(0, $0 - control.time) } ?? remaining
            let untilCommand = commandExpiry.map { max(0, $0 - control.time) } ?? remaining
            let step = min(remaining, untilLease, untilCommand)
            try SimulationValidation.require(
                step > 0 && control.time + step > control.time,
                "invalid_argument",
                "simulation.simulation_boundary_cannot_advance"
            )
            integrate(step); let expired = try control.advance(step)
            if expired { beginStop() }
            remaining -= step
            if let expiry = commandExpiry, control.time >= expiry { beginStop() }
        }
        record()
    }

    private mutating func integrate(_ dt: Double) {
        guard var pose, control.fault == nil else { return }
        func approach(_ current: Double, _ target: Double, _ delta: Double) -> Double {
            if current < target { return min(current + delta, target) }
            return max(current - delta, target)
        }
        let nextSpeed = approach(speed, control.enabled ? targetSpeed : 0, model.maximum_acceleration_m_s2 * dt)
        let nextSteering = approach(steering, targetSteering, model.maximum_steering_rate_rad_s * dt)
        let v = (speed + nextSpeed) / 2, angle = (steering + nextSteering) / 2
        let omega = v * tan(angle) / model.wheelbase_m
        let delta = omega * dt
        let dx = abs(omega) < 1e-12 ? v * dt : v * sin(delta) / omega
        let dy = abs(omega) < 1e-12 ? 0 : v * (1 - cos(delta)) / omega
        pose[0] += cos(pose[2]) * dx - sin(pose[2]) * dy
        pose[1] += sin(pose[2]) * dx + cos(pose[2]) * dy
        pose[2] += delta; self.pose = pose; speed = nextSpeed; steering = nextSteering
        if targetSpeed == 0 && speed == 0 && abs(steering - targetSteering) <= 1e-12 {
            phase = control.enabled ? "stopped" : "disabled"
        }
    }

    public mutating func fault(_ code: String, generation: String) throws {
        try control.injectFault(code, expectedGeneration: generation)
        speed = 0; targetSpeed = 0; targetSteering = steering; commandExpiry = nil; phase = "fault"; record()
    }

    public mutating func reset(generation: String) throws {
        try SimulationValidation.require(
            speed == 0 && abs(steering - targetSteering) <= 1e-12,
            "busy",
            "simulation.stop_before_resetting"
        )
        try control.reset(expectedGeneration: generation)
        pose = nil; speed = 0; steering = 0; targetSpeed = 0; targetSteering = 0
        commandExpiry = nil; phase = "uninitialized"; trace.removeAll(); dropped = 0
    }

    private func actual() -> ChassisActual? {
        guard let pose, control.fault != "telemetry_unavailable" else { return nil }
        let curvature = tan(steering) / model.wheelbase_m
        return ChassisActual(pose_m_rad: pose, speed_m_s: speed, steering_angle_rad: steering,
                             yaw_rate_rad_s: speed * curvature,
                             rear_wheel_velocity_rad_s: [
                                 speed * (1 - curvature * model.track_m / 2) / model.wheel_radius_m,
                                 speed * (1 + curvature * model.track_m / 2) / model.wheel_radius_m
                             ])
    }

    private mutating func record() {
        guard let actual = actual() else { return }
        trace.append(ChassisTraceSample(
            source: .simulation,
            generation: control.generation,
            sequence: control.revision,
            simulated_time_s: control.time,
            actual: actual
        ))
        if trace.count > 512 { trace.removeFirst(trace.count - 512); dropped &+= 1 }
    }

    public func snapshot() -> ChassisSnapshot {
        ChassisSnapshot(
            metadata: control
                .metadata(device: deviceID, model: model.id, state: phase, frame: "chassis_x_forward_y_left_z_up_v1"),
            actual: actual(),
            target_speed_m_s: targetSpeed,
            target_steering_angle_rad: targetSteering,
            command_expires_at_s: commandExpiry,
            stopped: actual() != nil && speed == 0 && abs(steering - targetSteering) <= 1e-12,
            trace_dropped: dropped
        )
    }
}
