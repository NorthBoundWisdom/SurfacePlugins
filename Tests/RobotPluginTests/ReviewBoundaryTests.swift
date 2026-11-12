import XCTest
import SurfacePluginContracts
@testable import SimulationContracts
import RobotPlugin

final class ReviewBoundaryTests: XCTestCase {
    func testLargeHostGapFreezesPoseRevokesAndReanchorsWithoutClearingFault() throws {
        var plugin = try RobotPlugin(instanceID: "test")
        _ = try plugin.handle(.start, at: 0)
        try plugin.simulator.initialize([0,0,0,0,0,0], generation: plugin.simulator.control.generation)
        let g = try plugin.simulator.acquire(generation: plugin.simulator.control.generation, owner: "test", ttl: 5, controlToken: "secret")
        try plugin.simulator.enable(.init(generation: g.generation, token: g.control_token, sequence: 1))
        try plugin.simulator.move(.init(generation: g.generation, token: g.control_token, sequence: 2), target: [1,0,0,0,0,0], duration: 1.5, validFor: 2)
        _ = try plugin.handle(.advance, at: 0.5)
        let before = plugin.simulator.snapshot()
        let update = try plugin.handle(.advance, at: 100_000)
        XCTAssertEqual(plugin.simulator.snapshot().actual?.joints_rad, before.actual?.joints_rad)
        XCTAssertEqual(plugin.simulator.control.time, 0.5, accuracy: 1e-12)
        XCTAssertEqual(plugin.simulator.control.fault, "host_clock_gap")
        XCTAssertTrue(plugin.snapshot().isStarted); XCTAssertTrue(plugin.acceptsWrites)
        XCTAssertNil(plugin.simulator.control.owner); XCTAssertFalse(plugin.simulator.control.enabled)
        XCTAssertFalse(update.events.isEmpty)
        _ = try plugin.handle(.advance, at: 100_000.1)
        XCTAssertEqual(plugin.simulator.control.time, 0.6, accuracy: 1e-10)
        XCTAssertEqual(plugin.simulator.control.fault, "host_clock_gap")
        XCTAssertEqual(plugin.simulator.snapshot().actual?.joints_rad, before.actual?.joints_rad)
    }
    func testCatchUpConfigurationAndPluginErrorBoundary() throws {
        XCTAssertThrowsError(try RobotPlugin(instanceID: "test", maxCatchUpGap: 0))
        XCTAssertThrowsError(try RobotPlugin(instanceID: "test", maxCatchUpGap: .infinity))
        var plugin = try RobotPlugin(instanceID: "test", maxCatchUpGap: 0.5)
        _ = try plugin.handle(.start, at: 0)
        _ = try plugin.handle(.advance, at: 0.5)
        XCTAssertNil(plugin.simulator.control.fault)
        _ = try plugin.handle(.advance, at: 1.0001)
        XCTAssertEqual(plugin.simulator.control.fault, "host_clock_gap")
        XCTAssertThrowsError(try plugin.handle(.advance, at: 0)) { XCTAssertNotNil($0 as? PluginError) }
        let domain = SimulationError("invalid_argument", "simulation.invalid_robot_time_step")
        XCTAssertEqual(domain.pluginError.code, .invalidParameter)
        XCTAssertEqual(domain.pluginError.fields, ["domainCode": .string("invalid_argument"), "reasonKey": .string("simulation.invalid_robot_time_step")])
        XCTAssertThrowsError(try plugin.simulator.advance(0)) { XCTAssertNotNil($0 as? SimulationError) }
    }
    func testRecentTokenGuardStaysBoundedAndClearsAcrossGeneration() throws {
        var control = DeviceControl(namespace: "test")
        try control.initialize(expectedGeneration: control.generation)
        var first: DeviceControlGrant?
        for i in 0..<10_000 {
            let grant = try control.acquire(expectedGeneration: control.generation, owner: "test", ttl: 1, controlToken: "opaque-\(i)")
            if first == nil { first = grant }
            XCTAssertLessThanOrEqual(control.retainedTokenCount, DeviceControl.recentTokenCapacity)
            try control.release(.init(generation: grant.generation, token: grant.control_token, sequence: 1))
        }
        XCTAssertEqual(control.retainedTokenCount, 256)
        XCTAssertThrowsError(try control.acquire(expectedGeneration: control.generation, owner: "test", ttl: 1, controlToken: "opaque-9999"))
        let fresh = try control.acquire(expectedGeneration: control.generation, owner: "test", ttl: 1, controlToken: "fresh-secret")
        let old = try XCTUnwrap(first)
        XCTAssertThrowsError(try control.enable(.init(generation: old.generation, token: old.control_token, sequence: 2)))
        try control.reset(expectedGeneration: control.generation)
        XCTAssertEqual(control.retainedTokenCount, 0)
        try control.initialize(expectedGeneration: control.generation)
        let next = try control.acquire(expectedGeneration: control.generation, owner: "test", ttl: 1, controlToken: "new-generation-secret")
        XCTAssertThrowsError(try control.enable(.init(generation: fresh.generation, token: fresh.control_token, sequence: 2)))
        XCTAssertNoThrow(try control.enable(.init(generation: next.generation, token: next.control_token, sequence: 1)))
    }
}
