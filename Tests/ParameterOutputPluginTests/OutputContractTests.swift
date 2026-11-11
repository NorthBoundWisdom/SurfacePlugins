import XCTest
import SurfacePluginContracts
import SurfacePluginConformance
import ParameterOutputPlugin
import ExampleParameterSets

final class OutputContractTests: XCTestCase {
    func make() throws -> ParameterOutputPlugin {
        try .init(limits: [.init(id: "x", minimum: -1, maximum: 1, maximumChange: 0.1, maximumVelocity: 1)])
    }
    func testConformanceAndExampleProtection() throws {
        try PluginConformance.check(make: make, sequence: [.init(.start, at: 0), .init(.stop, at: 1)],
            unknownAction: .invoke(.init(pluginID: "output", actionID: "output.unknown"), origin: .remote),
            outOfRange: .invoke(.init(pluginID: "output", actionID: "output.disable", index: 1), origin: .remote),
            writeAfterStop: .parameterChanged("output.x", 1, origin: .remote))
        let parameters = try ExampleParameterSets.referenceArm()
        XCTAssertEqual(parameters.count, 9)
        let enabled = try XCTUnwrap(parameters.first { $0.id == "arm.enabled" })
        XCTAssertFalse(enabled.agentWritable); XCTAssertTrue(enabled.externallyProtected)
        XCTAssertEqual(parameters.first { $0.id == "arm.j2" }?.defaultValue, 30)
    }
    func testNonfiniteClockAndHeartbeatFailClosed() throws {
        for bad in [Double.nan, .infinity, -.infinity] {
            var p = try make()
            p.setConnected(true, at: 0); p.receiveHeartbeat(at: 0)
            p.receiveActual([.init(id: "x", value: 0, receivedAt: 0)])
            _ = p.evaluate(targets: [:], at: 0)
            p.receiveHeartbeat(at: bad)
            let decision = p.evaluate(targets: ["x": 1], at: bad)
            XCTAssertEqual(decision.status, .clockError)
            XCTAssertFalse(decision.command?.enabled ?? false)
        }
    }
    func testStopNeverSendsEnabledCommand() throws {
        var p = try make(); _ = try p.handle(.start, at: 0)
        p.setConnected(true, at: 0); p.receiveHeartbeat(at: 0)
        p.receiveActual([.init(id: "x", value: 0, receivedAt: 0)])
        _ = p.evaluate(targets: [:], at: 0)
        try p.setEnabled(true); _ = p.evaluate(targets: ["x": 1], at: 0)
        _ = try p.handle(.stop, at: 0)
        XCTAssertFalse(p.decision?.command?.enabled ?? false)
        XCTAssertThrowsError(try p.setEnabled(true))
    }
}

final class HeartbeatGapTests: XCTestCase {
    func testFreshPacketsAfterLateOrEqualGapCannotAutoRearm() throws {
        for gap in [0.3, 0.6] {
            var g = try MotionSafetyGate(limits: [.init(id: "x", minimum: -1, maximum: 1, maximumChange: 1, maximumVelocity: 1)])
            g.setConnected(true, at: 0); g.receiveHeartbeat(at: 0)
            g.receiveActual([.init(id: "x", value: 0, receivedAt: 0)])
            _ = g.evaluate(targets: [:], enabled: false, at: 0)
            XCTAssertEqual(g.evaluate(targets: ["x": 1], enabled: true, at: 0).status, .ready)
            g.receiveHeartbeat(at: gap)
            g.receiveActual([.init(id: "x", value: 0.1, receivedAt: gap)])
            let blocked = g.evaluate(targets: ["x": 1], enabled: true, at: gap)
            XCTAssertEqual(blocked.status, .waitingRearm)
            XCTAssertFalse(blocked.command?.enabled ?? false)
            _ = g.evaluate(targets: [:], enabled: false, at: gap)
            XCTAssertEqual(g.evaluate(targets: ["x": 1], enabled: true, at: gap).status, .ready)
            XCTAssertEqual(g.outputs["x"], 0.1)
        }
    }
}
