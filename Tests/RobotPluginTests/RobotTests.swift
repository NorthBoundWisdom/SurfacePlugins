import Foundation
import XCTest
import SurfacePluginContracts
import SimulationContracts
import RobotPlugin
import SurfacePluginConformance

final class RobotTests: XCTestCase {
    func proof(_ grant: DeviceControlGrant, _ sequence: Int) -> DeviceCommandProof {
        DeviceCommandProof(generation: grant.generation, token: grant.control_token, sequence: sequence)
    }

    func robot() throws -> (RobotSimulator, DeviceControlGrant) {
        var robot = try RobotSimulator(instanceID: "fixture")
        try robot.initialize(Array(repeating: 0, count: 6), generation: robot.control.generation)
        let grant = try robot.acquire(generation: robot.control.generation, owner: "fixture", ttl: 5, controlToken: "fixture-secret")
        try robot.enable(proof(grant, 1))
        return (robot, grant)
    }

    func testUnknownInitialStateDoesNotBecomeZeroAndSourceIsSimulation() throws {
        var robot = try RobotSimulator(instanceID: "fixture")
        XCTAssertNil(robot.snapshot().actual)
        XCTAssertFalse(robot.snapshot().stopped)
        XCTAssertEqual(robot.snapshot().metadata.source, .simulation)
        XCTAssertThrowsError(try robot.acquire(generation: robot.control.generation, owner: "x", ttl: 1, controlToken: "fixture-secret"))
        XCTAssertNil(robot.snapshot().actual)
    }

    func testRobotTargetIsSeparateFromActualAndForwardPoseUsesActualJoints() throws {
        var (robot, grant) = try robot()
        let before = try XCTUnwrap(robot.snapshot().actual)
        let target = [1.0, 0, 0, 0, 0, 0]
        try robot.move(proof(grant, 2), target: target, duration: 1.5, validFor: 2)
        XCTAssertEqual(robot.snapshot().actual?.joints_rad, before.joints_rad)
        try robot.advance(0.1)
        let actual = try XCTUnwrap(robot.snapshot().actual)
        XCTAssertGreaterThan(actual.joints_rad[0], 0)
        XCTAssertLessThan(actual.joints_rad[0], 1)
        XCTAssertNotEqual(actual.base_from_tool_row_major_m, before.base_from_tool_row_major_m)
        XCTAssertEqual(actual.base_from_tool_row_major_m, robot.model.forward(actual.joints_rad))
        for _ in 0 ..< 15 { try robot.advance(0.1) }
        XCTAssertEqual(robot.snapshot().actual?.joints_rad, target)
        XCTAssertTrue(robot.snapshot().stopped)
    }

    func testRobotStopDeceleratesAndDoesNotResume() throws {
        var (robot, grant) = try robot()
        try robot.move(proof(grant, 2), target: [1, 0, 0, 0, 0, 0], duration: 1.5, validFor: 2)
        for _ in 0 ..< 7 { try robot.advance(0.1) }
        let initial = try XCTUnwrap(robot.snapshot().actual)
        try robot.stop(proof(grant, 3))
        XCTAssertEqual(robot.snapshot().actual?.joints_rad, initial.joints_rad)
        XCTAssertFalse(robot.snapshot().stopped)
        var previous = initial.joint_velocity_rad_s[0]
        for _ in 0 ..< 70 {
            try robot.advance(0.01)
            let next = try XCTUnwrap(robot.snapshot().actual).joint_velocity_rad_s[0]
            XCTAssertLessThanOrEqual(abs(next - previous), robot.model.maximum_acceleration_rad_s2 * 0.01 + 1e-10)
            previous = next
        }
        XCTAssertTrue(robot.snapshot().stopped)
        XCTAssertLessThan(try XCTUnwrap(robot.snapshot().actual).joints_rad[0], 1)
        let stopped = robot.snapshot().actual?.joints_rad
        try robot.advance(0.1)
        XCTAssertEqual(robot.snapshot().actual?.joints_rad, stopped)
    }

    func testInvalidRobotCommandsDoNotConsumeSequenceOrClamp() throws {
        var (robot, grant) = try robot()
        for target in [[4.0, 0, 0, 0, 0, 0], [Double.nan, 0, 0, 0, 0, 0], [0.0]] {
            XCTAssertThrowsError(try robot.move(proof(grant, 2), target: target, duration: 1.5, validFor: 2))
        }
        XCTAssertThrowsError(try robot.move(proof(grant, 2), target: [1, 0, 0, 0, 0, 0], duration: 0.01, validFor: 2))
        XCTAssertEqual(robot.control.lastCommandSequence, 1)
        XCTAssertFalse(robot.snapshot().motion_active)
    }

    func testControlGenerationTokenAndSequenceAreCheckedIndependently() throws {
        var (robot, grant) = try robot()
        XCTAssertThrowsError(try robot.enable(proof(grant, 1)))
        XCTAssertThrowsError(try robot.enable(.init(generation: grant.generation, token: "foreign", sequence: 2)))
        XCTAssertThrowsError(try robot.enable(.init(generation: "old", token: grant.control_token, sequence: 2)))
        try robot.reset(generation: robot.control.generation)
        XCTAssertNil(robot.snapshot().actual)
        XCTAssertThrowsError(try robot.enable(proof(grant, 2)))
    }

}

final class RobotContractTests: XCTestCase {
    func testReplayAndStopContract() throws {
        try PluginConformance.check(make: { try RobotPlugin(instanceID: "fixture") }, sequence: [.init(.start, at: 0), .init(.advance, at: 0.1), .init(.stop, at: 0.2)],
            unknownAction: .invoke(.init(pluginID: "robot", actionID: "robot.unknown"), origin: .remote),
            outOfRange: .invoke(.init(pluginID: "robot", actionID: "robot.stop", index: 1), origin: .remote),
            writeAfterStop: .parameterChanged("robot.unknown", 1, origin: .remote))
    }
    func testDeterministicControlAndNamespaceIsolation() throws {
        var a = DeviceControl(namespace: "a"), b = DeviceControl(namespace: "b")
        try a.initialize(expectedGeneration: a.generation); try b.initialize(expectedGeneration: b.generation)
        let grant = try a.acquire(expectedGeneration: a.generation, owner: "fixture", ttl: 1, controlToken: "fixture-secret")
        try b.acquire(expectedGeneration: b.generation, owner: "fixture", ttl: 1, controlToken: "fixture-secret")
        XCTAssertThrowsError(try b.enable(.init(generation: grant.generation, token: grant.control_token, sequence: 1)))
        let old = a.generation
        try a.reset(expectedGeneration: old)
        XCTAssertNotEqual(a.generation, old)
    }
    func testStopRemainsStartedUntilBrakingFinishes() throws {
        var plugin = try RobotPlugin(instanceID: "fixture")
        _ = try plugin.handle(.start, at: 0)
        try plugin.simulator.initialize([0,0,0,0,0,0], generation: plugin.simulator.control.generation)
        let grant = try plugin.simulator.acquire(generation: plugin.simulator.control.generation, owner: "fixture", ttl: 5, controlToken: "fixture-secret")
        try plugin.simulator.enable(.init(generation: grant.generation, token: grant.control_token, sequence: 1))
        try plugin.simulator.move(.init(generation: grant.generation, token: grant.control_token, sequence: 2), target: [1,0,0,0,0,0], duration: 1.5, validFor: 2)
        _ = try plugin.handle(.advance, at: 0.7); _ = try plugin.handle(.stop, at: 0.7)
        XCTAssertTrue(plugin.snapshot().isStarted)
        XCTAssertThrowsError(try plugin.handle(.parameterChanged("robot.x", 1, origin: .remote), at: 0.7))
        _ = try plugin.handle(.advance, at: 2)
        XCTAssertFalse(plugin.snapshot().isStarted)
        XCTAssertTrue(plugin.simulator.snapshot().stopped)
    }
}

final class GrantSecurityTests: XCTestCase {
    func testReacquireNeedsFreshHostSecretAndOldProofFails() throws {
        var c = DeviceControl(namespace: "visible-instance")
        try c.initialize(expectedGeneration: c.generation)
        let a = try c.acquire(expectedGeneration: c.generation, owner: "one", ttl: 1, controlToken: "opaque-host-first")
        try c.release(.init(generation: a.generation, token: a.control_token, sequence: 1))
        XCTAssertThrowsError(try c.acquire(expectedGeneration: c.generation, owner: "two", ttl: 1, controlToken: a.control_token))
        let b = try c.acquire(expectedGeneration: c.generation, owner: "two", ttl: 1, controlToken: "opaque-host-next")
        XCTAssertNotEqual(a.control_token, b.control_token)
        XCTAssertThrowsError(try c.enable(.init(generation: b.generation, token: a.control_token, sequence: 2)))
        let metadata = try JSONValue.encoded(c.metadata(device: "device", model: "model", state: "idle", frame: "frame"))
        XCTAssertFalse(try metadata.jsonText.contains(b.control_token))
        XCTAssertThrowsError(try c.enable(.init(generation: b.generation, token: "visible-instance.grant.2", sequence: 2)))
    }
}
