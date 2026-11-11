import XCTest
import SurfacePluginContracts
import ParameterOutputPlugin

final class Float32SeedSafetyTests: XCTestCase {
    private func gate(maximum: Double = 1, precision: MotionOutputPrecision = .float32,
                      actual: Double) throws -> MotionSafetyGate {
        var gate = try MotionSafetyGate(limits: [.init(id: "x", minimum: 0, maximum: maximum,
                                                       maximumChange: 1, maximumVelocity: 1)], precision: precision)
        gate.setConnected(true, at: 0); gate.receiveHeartbeat(at: 0)
        gate.receiveActual([.init(id: "x", value: actual, receivedAt: 0)])
        _ = gate.evaluate(targets: [:], enabled: false, at: 0)
        return gate
    }
    func testNonrepresentableBoundaryAndInteriorSeedsFailClosed() throws {
        for (maximum, actual) in [(0.1, 0.1), (1.0, 0.05), (Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude)] {
            var gate = try gate(maximum: maximum, actual: actual)
            let result = gate.evaluate(targets: ["x": actual], enabled: true, at: 0)
            XCTAssertEqual(result.status, .invalidActual)
            XCTAssertEqual(result.reason, "output.actual_not_float32_representable")
            XCTAssertEqual(result.parameterID, "x")
            XCTAssertEqual(result.command, .init(enabled: false, values: [:]))
            XCTAssertTrue(gate.outputs.isEmpty)
            XCTAssertTrue(gate.baseline.isEmpty)
        }
    }
    func testRepresentableWireActualSeedsWithoutMovement() throws {
        for actual in [0.0, 0.0625, Double(Float(0.05))] {
            var gate = try gate(actual: actual)
            let result = gate.evaluate(targets: ["x": 1], enabled: true, at: 0)
            XCTAssertEqual(result.status, .ready)
            XCTAssertEqual(result.command?.values["x"], actual)
            XCTAssertEqual(gate.baseline["x"], actual)
            XCTAssertEqual(Double(Float(try XCTUnwrap(result.command?.values["x"]))), actual)
        }
    }
    func testDoublePrecisionKeepsNonrepresentableActual() throws {
        var gate = try gate(maximum: 0.1, precision: .double, actual: 0.1)
        let result = gate.evaluate(targets: ["x": 0.1], enabled: true, at: 0)
        XCTAssertEqual(result.status, .ready)
        XCTAssertEqual(result.command, .init(enabled: true, values: ["x": 0.1]))
        XCTAssertEqual(gate.baseline["x"], 0.1)
    }
    func testFreshRepresentableActualDoesNotAutomaticallyRearm() throws {
        var gate = try gate(maximum: 0.1, actual: 0.1)
        XCTAssertEqual(gate.evaluate(targets: ["x": 0.1], enabled: true, at: 0).status, .invalidActual)
        gate.receiveActual([.init(id: "x", value: 0.0625, receivedAt: 0)])
        let held = gate.evaluate(targets: ["x": 0.1], enabled: true, at: 0)
        XCTAssertEqual(held.status, .waitingRearm)
        XCTAssertFalse(held.command?.enabled ?? false)
        _ = gate.evaluate(targets: [:], enabled: false, at: 0)
        let rearmed = gate.evaluate(targets: ["x": 0.1], enabled: true, at: 0)
        XCTAssertEqual(rearmed.status, .ready)
        XCTAssertEqual(rearmed.command?.values["x"], 0.0625)
    }
    func testReadyOutputIsNotReseededByUnrelatedDoubleActual() throws {
        var gate = try gate(maximum: 0.1, actual: 0)
        _ = gate.evaluate(targets: ["x": 0.1], enabled: true, at: 0)
        gate.receiveActual([.init(id: "x", value: 0.1, receivedAt: 0.1)])
        let continued = gate.evaluate(targets: ["x": 0.1], enabled: true, at: 0.1)
        XCTAssertEqual(continued.status, .ready)
        XCTAssertEqual(gate.baseline["x"], 0)
        let output = try XCTUnwrap(continued.command?.values["x"])
        XCTAssertEqual(Double(Float(output)), output)
        XCTAssertLessThanOrEqual(output, 0.1)
        _ = gate.evaluate(targets: [:], enabled: false, at: 0.1)
        XCTAssertEqual(gate.evaluate(targets: ["x": 0.1], enabled: true, at: 0.1).status, .invalidActual)
    }
}
