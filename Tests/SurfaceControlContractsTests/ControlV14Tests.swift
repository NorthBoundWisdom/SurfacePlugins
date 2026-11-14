import Foundation
import XCTest
import SurfacePluginContracts
@testable import SurfaceControlContracts

final class ControlV14Tests: XCTestCase {
    func profile() -> ControlProfile {
        .init(id: "test.hardware", version: "1", controls: [
            .init(id: "axis", inputKind: .absolute, encoding: .scalar, range: .init(minimum: 0, maximum: 127, step: 1), feedbackKinds: [.value], acceptsInput: false),
            .init(id: "delta", inputKind: .relative, encoding: .signedDelta, range: .init(minimum: -8, maximum: 8, step: 1), acceptsInput: false),
            .init(id: "touch", inputKind: .button, encoding: .boolean, acceptsInput: false)
        ], capabilities: ["hardware", "controls.input_declared", "input.absolute", "input.relative", "input.button", "feedback.value"])
    }
    func code(_ expected: String, _ action: () throws -> Void) {
        XCTAssertThrowsError(try action()) { XCTAssertEqual(($0 as? ControlContractError)?.code, expected) }
    }
    func testHardwareUnknownLifecycleAndAtomicRejections() throws {
        var s = try SurfaceControlSession(instanceID: "test", epoch: "zero", profile: profile(), eventCapacity: 2)
        XCTAssertEqual(s.discovery().contract_version, "1.4")
        XCTAssertEqual(s.discovery().source, .hardware)
        XCTAssertTrue(try s.snapshot(at: 0).inputs.isEmpty)
        XCTAssertEqual(try s.snapshot(at: 0).link?.state, .disconnected)
        try s.transitionHardware(epoch: "one", linkState: .connected, at: 0)
        let before = try s.snapshot(at: 0)
        code("permission_denied") { try s.seedInputs(["axis": .number(0)], at: 0) }
        code("permission_denied") { try s.validateInput(.init(expected: s.expected, expectedSequence: "0", controlID: "axis", encoding: "scalar", value: .number(5))) }
        code("unsupported_hold") { try s.validateRenew(.init(expected: s.expected, controlID: "touch", holdSeconds: 1), at: 0) }
        code("unsupported_tool") { try s.reset(expected: s.expected, expectedSequence: "0", epoch: "forbidden", at: 0) }
        code("invalid_value") { try s.recordHardwareInput(.init(expected: s.expected, controlID: "axis", encoding: "scalar", value: .number(128)), disposition: .accepted, at: 0) }
        XCTAssertEqual(try s.snapshot(at: 0), before)
        for (id, encoding, value) in [("axis", "scalar", JSONValue.number(5)), ("delta", "signedDelta", .number(-1)), ("touch", "boolean", .bool(true))] {
            let input = ControlHardwareInput(expected: s.expected, controlID: id, encoding: encoding, value: value)
            try s.validateHardwareInput(input, at: 1)
            let e = try s.recordHardwareInput(input, disposition: .accepted, at: 1)
            XCTAssertEqual(e.source, .hardware); XCTAssertEqual(e.origin, .hardware)
        }
        code("event_gap") { _ = try s.events(instanceID: "test", epoch: "one", afterSequence: "0", at: 1) }
        let ignored = try s.recordHardwareInput(.init(expected: s.expected, controlID: "axis", encoding: "scalar", value: .number(10)), disposition: .ignored, reason: "no_binding", at: 2)
        XCTAssertEqual(ignored.disposition, .ignored)
        XCTAssertEqual(try s.snapshot(at: 2).inputs["axis"], .number(5))
        code("invalid_time") { try s.validateHardwareInput(.init(expected: s.expected, controlID: "axis", encoding: "scalar", value: .number(1)), at: 1) }
        let old = s.expected
        try s.transitionHardware(epoch: "two", linkState: .disconnected, at: 2)
        code("stale_epoch") { _ = try s.events(instanceID: "test", epoch: old.epoch, afterSequence: "0", at: 2) }
        try s.transitionHardware(epoch: "three", linkState: .connected, at: 3)
        XCTAssertTrue(try s.snapshot(at: 3).inputs.isEmpty)
        code("unsupported_feedback") { try s.validateFeedback(.init(expected: s.expected, expectedSequence: "0", controlID: "touch", kind: "value", value: .bool(true))) }
        let f = try s.recordFeedback(.init(expected: s.expected, expectedSequence: "0", controlID: "axis", kind: "value", value: .number(8)), origin: .remote, at: 3)
        XCTAssertEqual(f.source, .hardware)
        XCTAssertTrue(try s.snapshot(at: 3).inputs.isEmpty)
    }
    func testHardwareProfileRejectsMixedSourceAndRemoteInput() throws {
        let p = profile()
        for capabilities in [p.capabilities + ["simulation"], p.capabilities.filter { $0 != "controls.input_declared" }, p.capabilities + ["input.hold"]] {
            code("invalid_profile") { try ControlProfile(id: p.id, version: p.version, controls: p.controls, capabilities: capabilities).validate() }
        }
        code("invalid_profile") { try ControlProfile(id: p.id, version: p.version, controls: [.init(id: "touch", inputKind: .button, encoding: .boolean, acceptsInput: true)], capabilities: ["hardware", "controls.input_declared", "input.button"]).validate() }
    }
    func testSimulationDiscoveryBytesMatchFrozen13Example() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let samples = try JSONDecoder().decode([JSONValue].self, from: Data(contentsOf: root.appendingPathComponent("docs/surface-control-examples.json")))
        guard case .object(let sample) = samples[0], let golden = sample["result"] else { return XCTFail("missing frozen discovery") }
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let discovery = try decoder.decode(ControlDiscovery.self, from: encoder.encode(golden))
        let session = try SurfaceControlSession(instanceID: discovery.expected.instance_id, epoch: discovery.expected.epoch, profile: discovery.profile, writeLimits: discovery.write_limits)
        XCTAssertEqual(try encoder.encode(JSONValue.encoded(session.discovery())), try encoder.encode(golden))
        XCTAssertEqual(session.discovery().contract_version, "1.3")
    }
}
