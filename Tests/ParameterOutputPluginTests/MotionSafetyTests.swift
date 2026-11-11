import Foundation
import XCTest
import SurfacePluginContracts
import ParameterOutputPlugin

final class MotionSafetyTests: XCTestCase {
    private let t0 = 8_000.0
    private func gate(speed: Double = 10, change: Double = 2,
                      precision: MotionOutputPrecision = .double) throws -> MotionSafetyGate
    {
        try MotionSafetyGate(limits: [.init(id: "x", minimum: -100, maximum: 100,
                                            maximumChange: change, maximumVelocity: speed)], precision: precision)
    }

    private func prepare(_ gate: inout MotionSafetyGate, at time: Double, actual: Double = 0) {
        gate.setConnected(true, at: time)
        gate.receiveHeartbeat(at: time)
        gate.receiveActual([.init(id: "x", value: actual, receivedAt: time)])
        _ = gate.evaluate(targets: [:], enabled: false, at: time)
    }

    func testDisabledAndDisconnectedNeverProduceMotionFrames() throws {
        var g = try gate()
        XCTAssertNil(g.evaluate(targets: ["x": 50], enabled: true, at: t0).command)
        prepare(&g, at: t0)
        let decision = g.evaluate(targets: ["x": 50], enabled: false, at: t0)
        XCTAssertEqual(decision.status, .disabled)
        XCTAssertEqual(decision.command, .init(enabled: false, values: [:]))
        XCTAssertTrue(g.outputs.isEmpty)
    }

    func testPerCycleAndVelocityCapsAndInitialEnableDoNotJump() throws {
        var g = try gate(speed: 10, change: 0.5)
        prepare(&g, at: t0)
        let initial = g.evaluate(targets: ["x": 90], enabled: true, at: (t0 + 0.1))
        XCTAssertEqual(initial.command, .init(enabled: true, values: ["x": 0]))
        XCTAssertEqual(g.outputs["x"], 0)
        let next = g.evaluate(targets: ["x": 90], enabled: true, at: (t0 + 0.2))
        XCTAssertEqual(next.command?.values["x"], 0.5)
        XCTAssertTrue(next.limited)
        var velocity = try gate(speed: 2, change: 10)
        prepare(&velocity, at: t0)
        _ = velocity.evaluate(targets: ["x": -90], enabled: true, at: t0)
        _ = velocity.evaluate(targets: ["x": -90], enabled: true, at: (t0 + 0.1))
        XCTAssertEqual(velocity.outputs["x"]!, -0.2, accuracy: 1e-8)
    }

    func testSoftLimitsRemainEffectiveAndClockIsInjected() throws {
        var g = try gate(speed: 10_000, change: 10_000)
        prepare(&g, at: t0, actual: 99)
        _ = g.evaluate(targets: ["x": 999], enabled: true, at: t0)
        _ = g.evaluate(targets: ["x": 999], enabled: true, at: (t0 + 0.1))
        XCTAssertEqual(g.outputs["x"], 100)
        let same = g.evaluate(targets: ["x": 999], enabled: true, at: (t0 + 0.1))
        XCTAssertEqual(same.command?.values, ["x": 100])
        XCTAssertTrue(same.limited)
    }

    func testDisableTimeoutAndDisconnectNeverRepeatMovement() throws {
        for reason in 0 ..< 3 {
            var g = try gate()
            prepare(&g, at: t0)
            _ = g.evaluate(targets: ["x": 50], enabled: true, at: t0)
            let time: Double
            let enabled: Bool
            if reason == 0 { time = (t0 + 0.1); enabled = false }
            else if reason == 1 { time = (t0 + 0.3); enabled = true }
            else { time = (t0 + 0.1); enabled = true; g.setConnected(false, at: time) }
            let result = g.evaluate(targets: ["x": 50], enabled: enabled, at: time)
            XCTAssertEqual(result.command, .init(enabled: false, values: [:]))
            XCTAssertNotEqual(result.status, .ready)
            let repeated = g.evaluate(targets: ["x": 80], enabled: enabled, at: time).command
            XCTAssertTrue(repeated == nil || repeated == .init(enabled: false, values: [:]))
        }
    }

    func testMissingHeartbeatAndActualStateFailClosedAtBoundary() throws {
        var g = try gate()
        g.setConnected(true, at: t0)
        XCTAssertEqual(g.evaluate(targets: ["x": 1], enabled: true, at: t0).status, .waitingHeartbeat)
        XCTAssertEqual(
            g.evaluate(targets: ["x": 1], enabled: false, at: (t0 + 0.3)).status,
            .heartbeatExpired
        )
        g.receiveHeartbeat(at: (t0 + 0.3))
        XCTAssertEqual(
            g.evaluate(targets: ["x": 1], enabled: true, at: (t0 + 0.3)).status,
            .waitingActual
        )
        g.receiveActual([.init(id: "x", value: 0, receivedAt: t0)])
        XCTAssertEqual(
            g.evaluate(targets: ["x": 1], enabled: true, at: (t0 + 0.3)).status,
            .waitingActual
        )
    }

    func testInvalidTargetActualAndClockNeverReachSink() throws {
        var g = try gate()
        prepare(&g, at: t0)
        XCTAssertEqual(g.evaluate(targets: ["x": .nan], enabled: true, at: t0).status, .invalidTarget)
        XCTAssertEqual(g.evaluate(targets: [:], enabled: true, at: t0).status, .invalidTarget)
        g.receiveActual([.init(id: "x", value: 101, receivedAt: t0)])
        XCTAssertEqual(g.evaluate(targets: ["x": 1], enabled: true, at: t0).status, .actualOutOfLimits)
        g.receiveActual([.init(id: "x", value: .nan, receivedAt: t0)])
        XCTAssertEqual(g.evaluate(targets: ["x": 1], enabled: true, at: t0).status, .invalidActual)
        g.setConnected(false, at: t0)
        prepare(&g, at: t0)
        _ = g.evaluate(targets: ["x": 1], enabled: true, at: t0)
        XCTAssertEqual(g.evaluate(targets: ["x": 1], enabled: true, at: (t0 + -1)).status, .clockError)
        XCTAssertEqual(g.evaluate(targets: ["x": 1], enabled: true, at: t0).status, .clockError)
    }

    func testReconnectAndReenableSeedFromFreshActualRatherThanOldCommands() throws {
        var g = try gate()
        prepare(&g, at: t0)
        _ = g.evaluate(targets: ["x": 90], enabled: true, at: t0)
        _ = g.evaluate(targets: ["x": 90], enabled: true, at: (t0 + 0.1))
        _ = g.evaluate(targets: ["x": 90], enabled: false, at: (t0 + 0.2))
        let time = (t0 + 0.25)
        g.receiveHeartbeat(at: time)
        g.receiveActual([.init(id: "x", value: 20, receivedAt: time)])
        let enable = g.evaluate(targets: ["x": 90], enabled: true, at: time)
        XCTAssertEqual(g.outputs["x"], 20)
        XCTAssertEqual(g.baseline["x"], 20)
        XCTAssertEqual(enable.command?.values, ["x": 20])
        g.setConnected(false, at: time)
        _ = g.evaluate(targets: ["x": 90], enabled: true, at: time)
        prepare(&g, at: time, actual: -20)
        _ = g.evaluate(targets: ["x": 90], enabled: true, at: time)
        XCTAssertEqual(g.outputs["x"], -20)
        XCTAssertEqual(g.baseline["x"], -20)
    }

    func testFloatWireQuantizationStaysInsideSoftAndVelocityLimits() throws {
        var g = try MotionSafetyGate(
            limits: [.init(id: "x", minimum: 0, maximum: 0.1, maximumChange: 1, maximumVelocity: 1)],
            precision: .float32
        )
        prepare(&g, at: t0)
        _ = g.evaluate(targets: ["x": 1], enabled: true, at: t0)
        _ = g.evaluate(targets: ["x": 1], enabled: true, at: (t0 + 0.2))
        let output = try XCTUnwrap(g.outputs["x"])
        XCTAssertLessThanOrEqual(output, 0.1)
        XCTAssertEqual(Double(Float(output)), output)
        var slow = try gate(speed: 0.1, change: 1, precision: .float32)
        prepare(&slow, at: t0)
        _ = slow.evaluate(targets: ["x": 50], enabled: true, at: t0)
        _ = slow.evaluate(targets: ["x": 50], enabled: true, at: (t0 + 0.02))
        XCTAssertLessThanOrEqual(slow.outputs["x"]!, 0.1 * 0.02 + 1e-12)
    }

    func testLimitValidationRejectsUnsafeSettings() {
        for limit in [
            MotionLimit(id: "x", minimum: 0, maximum: 0, maximumChange: 1, maximumVelocity: 1),
            .init(id: "x", minimum: 0, maximum: 1, maximumChange: 0, maximumVelocity: 1),
            .init(id: "x", minimum: 0, maximum: 1, maximumChange: 1, maximumVelocity: .infinity)
        ] { XCTAssertThrowsError(try MotionSafetyGate(limits: [limit])) }
        XCTAssertThrowsError(try MotionSafetyGate(limits: []))
        XCTAssertThrowsError(try MotionSafetyGate(
            limits: [.init(id: "x", minimum: 0, maximum: 1, maximumChange: 1, maximumVelocity: 1)],
            heartbeatTimeout: 1
        ))
    }

    func testAlreadyEnabledStartupAndReconnectRequireObservedOffThenOn() throws {
        var g = try gate()
        g.setConnected(true, at: t0)
        g.receiveHeartbeat(at: t0)
        g.receiveActual([.init(id: "x", value: 0, receivedAt: t0)])
        for _ in 0 ..< 3 {
            let held = g.evaluate(targets: ["x": 90], enabled: true, at: t0)
            XCTAssertEqual(held.status, .waitingRearm)
            XCTAssertEqual(held.command, .init(enabled: false, values: [:]))
            XCTAssertTrue(g.outputs.isEmpty)
        }
        _ = g.evaluate(targets: ["x": 90], enabled: false, at: t0)
        XCTAssertEqual(g.evaluate(targets: ["x": 90], enabled: true, at: t0).status, .ready)
        let expired = (t0 + 0.3)
        XCTAssertEqual(g.evaluate(targets: ["x": 90], enabled: true, at: expired).status, .heartbeatExpired)
        g.receiveHeartbeat(at: expired)
        g.receiveActual([.init(id: "x", value: 1, receivedAt: expired)])
        XCTAssertEqual(g.evaluate(targets: ["x": 90], enabled: true, at: expired).status, .waitingRearm)
        _ = g.evaluate(targets: ["x": 90], enabled: false, at: expired)
        XCTAssertEqual(g.evaluate(targets: ["x": 90], enabled: true, at: expired).status, .ready)
        g.setConnected(false, at: expired)
        g.setConnected(true, at: expired)
        g.receiveHeartbeat(at: expired)
        g.receiveActual([.init(id: "x", value: 2, receivedAt: expired)])
        XCTAssertEqual(g.evaluate(targets: ["x": 90], enabled: true, at: expired).status, .waitingRearm)
    }

    func testEveryReadyFrameContainsAllLimitedOutputsIncludingUnchangedJoints() throws {
        var g = try MotionSafetyGate(limits: [
            .init(id: "x", minimum: -100, maximum: 100, maximumChange: 1, maximumVelocity: 10),
            .init(id: "y", minimum: -100, maximum: 100, maximumChange: 1, maximumVelocity: 10)
        ])
        g.setConnected(true, at: t0)
        g.receiveHeartbeat(at: t0)
        g.receiveActual([.init(id: "x", value: 0, receivedAt: t0), .init(id: "y", value: 5, receivedAt: t0)])
        _ = g.evaluate(targets: [:], enabled: false, at: t0)
        for i in 0 ..< 3 {
            let decision = g.evaluate(
                targets: ["x": 1, "y": 5],
                enabled: true,
                at: (t0 + Double(i) * 0.1)
            )
            XCTAssertEqual(Set(decision.command!.values.keys), Set(["x", "y"]))
            XCTAssertEqual(decision.command!.values["y"], 5)
        }
        let retry = g.evaluate(targets: ["x": 1, "y": 5], enabled: true, at: (t0 + 0.2))
        XCTAssertEqual(retry.command?.values, ["x": 1, "y": 5])
        for _ in 0 ..< 3 {
            XCTAssertEqual(
                g.evaluate(targets: [:], enabled: false, at: (t0 + 0.2)).command,
                .init(enabled: false, values: [:])
            )
        }
    }
}
