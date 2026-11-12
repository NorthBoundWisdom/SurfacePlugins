import Foundation
import XCTest
import SurfacePluginContracts
import SimulationContracts
import RobotPlugin
import ChassisPlugin
import SurfacePluginConformance
final class ChassisTests: XCTestCase {
    func proof(_ grant: DeviceControlGrant, _ sequence: Int) -> DeviceCommandProof {
        DeviceCommandProof(generation: grant.generation, token: grant.control_token, sequence: sequence)
    }

    func robot() throws -> (RobotSimulator, DeviceControlGrant) {
        var robot = try RobotSimulator(instanceID: "robot")
        try robot.initialize(Array(repeating: 0, count: 6), generation: robot.control.generation)
        let grant = try robot.acquire(generation: robot.control.generation, owner: "fixture", ttl: 5, controlToken: "fixture-secret")
        try robot.enable(proof(grant, 1))
        return (robot, grant)
    }

    func chassis() throws -> (ChassisSimulator, DeviceControlGrant) {
        var chassis = try ChassisSimulator(instanceID: "chassis")
        try chassis.initialize([0, 0, 0], generation: chassis.control.generation)
        let grant = try chassis.acquire(generation: chassis.control.generation, owner: "fixture", ttl: 5, controlToken: "fixture-secret")
        try chassis.enable(proof(grant, 1))
        return (chassis, grant)
    }

    func testChassisAccelerationBrakingAndCommandExpiryAreIntegrated() throws {
        var (chassis, grant) = try chassis()
        try chassis.drive(proof(grant, 2), speed: 0.5, steering: 0, validFor: 0.5)
        XCTAssertEqual(chassis.snapshot().actual?.speed_m_s, 0)
        for _ in 0 ..< 5 { try chassis.advance(0.1) }
        XCTAssertEqual(try XCTUnwrap(chassis.snapshot().actual).pose_m_rad[0], 0.125, accuracy: 1e-10)
        XCTAssertFalse(chassis.snapshot().stopped)
        for _ in 0 ..< 6 { try chassis.advance(0.1) }
        let actual = try XCTUnwrap(chassis.snapshot().actual)
        XCTAssertEqual(actual.speed_m_s, 0, accuracy: 1e-12)
        XCTAssertEqual(actual.pose_m_rad[0], 0.25, accuracy: 1e-10)
        XCTAssertTrue(chassis.snapshot().stopped)
    }

    func testAckermannSteeringIsNotYawRateAndCannotRotateInPlace() throws {
        var (chassis, grant) = try chassis()
        try chassis.drive(proof(grant, 2), speed: 0, steering: 0.3, validFor: 1)
        for _ in 0 ..< 4 { try chassis.advance(0.1) }
        XCTAssertEqual(chassis.snapshot().actual?.pose_m_rad, [0, 0, 0])
        try chassis.drive(proof(grant, 3), speed: 0.5, steering: 0.3, validFor: 1)
        for _ in 0 ..< 4 { try chassis.advance(0.1) }
        let actual = try XCTUnwrap(chassis.snapshot().actual)
        XCTAssertGreaterThan(actual.pose_m_rad[1], 0)
        XCTAssertEqual(
            actual.yaw_rate_rad_s,
            actual.speed_m_s * tan(actual.steering_angle_rad) / chassis.model.wheelbase_m,
            accuracy: 1e-12
        )
        XCTAssertNotEqual(actual.rear_wheel_velocity_rad_s[0], actual.rear_wheel_velocity_rad_s[1])
    }

    func testDomainResetClockAndFaultDoNotAffectAnotherDomain() throws {
        let (robot, _) = try robot()
        var (chassis, grant) = try chassis()
        let original = try JSONValue.encoded(robot.snapshot())
        try chassis.drive(proof(grant, 2), speed: 0.5, steering: 0.2, validFor: 0.3)
        try chassis.advance(0.1)
        try chassis.fault("telemetry_unavailable", generation: chassis.control.generation)
        XCTAssertNil(chassis.snapshot().actual)
        XCTAssertThrowsError(try chassis.enable(proof(grant, 3)))
        try chassis.reset(generation: chassis.control.generation)
        XCTAssertNil(chassis.snapshot().actual)
        XCTAssertEqual(try JSONValue.encoded(robot.snapshot()), original)
    }

    func testExpiredLeaseStopsAndRejectsOldControl() throws {
        var chassis = try ChassisSimulator(instanceID: "chassis")
        try chassis.initialize([0, 0, 0], generation: chassis.control.generation)
        let grant = try chassis.acquire(generation: chassis.control.generation, owner: "fixture", ttl: 0.2, controlToken: "fixture-secret")
        try chassis.enable(proof(grant, 1))
        try chassis.drive(proof(grant, 2), speed: 0.5, steering: 0, validFor: 0.2)
        for _ in 0 ..< 6 { try chassis.advance(0.1) }
        XCTAssertTrue(chassis.snapshot().stopped)
        XCTAssertFalse(chassis.control.enabled)
        XCTAssertNil(chassis.snapshot().metadata.control_owner)
        XCTAssertThrowsError(try chassis.drive(proof(grant, 3), speed: 0.5, steering: 0, validFor: 0.1))
    }

    func testInvalidChassisValuesAndTimeAreRejectedWithoutMutation() throws {
        var (chassis, grant) = try chassis()
        XCTAssertThrowsError(try chassis.drive(proof(grant, 2), speed: 2, steering: 0, validFor: 1))
        XCTAssertThrowsError(try chassis.drive(proof(grant, 2), speed: 0, steering: .nan, validFor: 1))
        for dt in [0.0, -0.1, 0.2, .infinity] { XCTAssertThrowsError(try chassis.advance(dt)) }
        XCTAssertEqual(chassis.control.time, 0)
        XCTAssertEqual(chassis.control.lastCommandSequence, 1)
    }

    func testIndependentModelsHaveDeterministicMotionAndBoundedTrace() throws {
        var (left, a) = try chassis(); var (right, b) = try chassis()
        try left.drive(proof(a, 2), speed: 0.5, steering: 0.2, validFor: 1)
        try right.drive(proof(b, 2), speed: 0.5, steering: 0.2, validFor: 1)
        for _ in 0 ..< 600 { try left.advance(0.01); try right.advance(0.01) }
        XCTAssertEqual(left.snapshot().actual?.pose_m_rad, right.snapshot().actual?.pose_m_rad)
        XCTAssertEqual(left.trace.count, 512)
        XCTAssertGreaterThan(left.snapshot().trace_dropped, 0)
    }

    func testChassisStopBarrierPreventsReauthorizationAndRetargetUntilZeroSpeed() throws {
        var (chassis, grant) = try chassis()
        try chassis.drive(proof(grant, 2), speed: 0.8, steering: 0.3, validFor: 2)
        for _ in 0 ..< 5 { try chassis.advance(0.1) }
        try chassis.stop(proof(grant, 3))
        let stoppedSequence = chassis.control.lastCommandSequence
        XCTAssertFalse(chassis.snapshot().stopped)
        XCTAssertThrowsError(try chassis.enable(proof(grant, 4))) { XCTAssertEqual(
            ($0 as? SimulationError)?.code,
            "busy"
        ) }
        XCTAssertThrowsError(try chassis.drive(proof(grant, 4), speed: 0.4, steering: -0.2, validFor: 1)) {
            XCTAssertEqual(
                ($0 as? SimulationError)?.code,
                "busy"
            )
        }
        XCTAssertEqual(chassis.control.lastCommandSequence, stoppedSequence)
        for _ in 0 ..< 6 { try chassis.advance(0.1) }
        XCTAssertTrue(chassis.snapshot().stopped)
        try chassis.enable(proof(grant, 4))
        try chassis.drive(proof(grant, 5), speed: 0.4, steering: -0.2, validFor: 1)
        XCTAssertEqual(chassis.snapshot().target_speed_m_s, 0.4)
    }

    func testShortenedLeaseStopsAtExactBoundaryAndDoesNotContinueSteering() throws {
        var (chassis, grant) = try chassis()
        try chassis.drive(proof(grant, 2), speed: 0.8, steering: 0.5, validFor: 2)
        for _ in 0 ..< 3 { try chassis.advance(0.1) }
        try chassis.advance(0.01)
        try chassis.renew(proof(grant, 3), ttl: 0.1)
        try chassis.advance(0.1)
        let angleAtExpiry = try XCTUnwrap(chassis.snapshot().actual).steering_angle_rad
        XCTAssertFalse(chassis.control.enabled)
        let next = try chassis.acquire(generation: chassis.control.generation, owner: "next-owner", ttl: 2, controlToken: "new-secret")
        XCTAssertThrowsError(try chassis.enable(proof(next, 1))) { XCTAssertEqual(
            ($0 as? SimulationError)?.code,
            "busy"
        ) }
        for _ in 0 ..< 6 { try chassis.advance(0.1) }
        XCTAssertTrue(chassis.snapshot().stopped)
        XCTAssertEqual(try XCTUnwrap(chassis.snapshot().actual).steering_angle_rad, angleAtExpiry)
        try chassis.enable(proof(next, 1))
    }
}

final class ChassisContractTests: XCTestCase {
    func testContract() throws {
        try PluginConformance.check(make: { try ChassisPlugin(instanceID: "fixture") }, sequence: [.init(.start, at: 0), .init(.advance, at: 0.1), .init(.stop, at: 0.2)],
            unknownAction: .invoke(.init(pluginID: "chassis", actionID: "chassis.unknown"), origin: .remote),
            outOfRange: .invoke(.init(pluginID: "chassis", actionID: "chassis.stop", index: 1), origin: .remote),
            writeAfterStop: .parameterChanged("chassis.unknown", 1, origin: .remote))
    }
    func testSameTypeInstancesCannotUseForeignProof() throws {
        var a = try ChassisSimulator(instanceID: "a"), b = try ChassisSimulator(instanceID: "b")
        try a.initialize([0,0,0], generation: a.control.generation); try b.initialize([0,0,0], generation: b.control.generation)
        let grant = try a.acquire(generation: a.control.generation, owner: "fixture", ttl: 1, controlToken: "fixture-secret")
        XCTAssertThrowsError(try b.enable(.init(generation: grant.generation, token: grant.control_token, sequence: 1)))
        let before = try JSONValue.encoded(b.snapshot())
        try a.reset(generation: a.control.generation)
        XCTAssertEqual(try JSONValue.encoded(b.snapshot()), before)
    }
    func testMovingStopWaitsForBraking() throws {
        var p = try ChassisPlugin(instanceID: "fixture")
        _ = try p.handle(.start, at: 0)
        try p.simulator.initialize([0,0,0], generation: p.simulator.control.generation)
        let g = try p.simulator.acquire(generation: p.simulator.control.generation, owner: "fixture", ttl: 5, controlToken: "fixture-secret")
        try p.simulator.enable(.init(generation: g.generation, token: g.control_token, sequence: 1))
        try p.simulator.drive(.init(generation: g.generation, token: g.control_token, sequence: 2), speed: 0.8, steering: 0.3, validFor: 2)
        _ = try p.handle(.advance, at: 0.5); _ = try p.handle(.stop, at: 0.5)
        XCTAssertTrue(p.snapshot().isStarted)
        XCTAssertThrowsError(try p.handle(.parameterChanged("chassis.x", 1, origin: .remote), at: 0.5))
        _ = try p.handle(.advance, at: 1.5)
        XCTAssertFalse(p.snapshot().isStarted); XCTAssertTrue(p.simulator.snapshot().stopped)
    }
}

final class ChassisClockGapTests: XCTestCase {
    func testLargeGapFreezesAndRequiresExplicitFaultRecovery() throws {
        var plugin = try ChassisPlugin(instanceID: "test")
        _ = try plugin.handle(.start, at: 0)
        try plugin.simulator.initialize([0,0,0], generation: plugin.simulator.control.generation)
        let g = try plugin.simulator.acquire(generation: plugin.simulator.control.generation, owner: "test", ttl: 5, controlToken: "secret")
        try plugin.simulator.enable(.init(generation: g.generation, token: g.control_token, sequence: 1))
        try plugin.simulator.drive(.init(generation: g.generation, token: g.control_token, sequence: 2), speed: 0.8, steering: 0.3, validFor: 2)
        _ = try plugin.handle(.advance, at: 0.5)
        let before = plugin.simulator.snapshot().actual?.pose_m_rad
        _ = try plugin.handle(.advance, at: 100_000)
        XCTAssertEqual(plugin.simulator.snapshot().actual?.pose_m_rad, before)
        XCTAssertEqual(plugin.simulator.control.time, 0.5, accuracy: 1e-12)
        XCTAssertEqual(plugin.simulator.control.fault, "host_clock_gap")
        XCTAssertTrue(plugin.snapshot().isStarted); XCTAssertTrue(plugin.acceptsWrites)
        XCTAssertNil(plugin.simulator.control.owner); XCTAssertFalse(plugin.simulator.control.enabled)
        _ = try plugin.handle(.advance, at: 100_000.1)
        XCTAssertEqual(plugin.simulator.control.time, 0.6, accuracy: 1e-10)
        XCTAssertEqual(plugin.simulator.control.fault, "host_clock_gap")
        XCTAssertEqual(plugin.simulator.snapshot().actual?.pose_m_rad, before)
    }
}
