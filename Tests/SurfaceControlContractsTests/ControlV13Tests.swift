import XCTest
import SurfacePluginContracts
@testable import SurfaceControlContracts

final class ControlV13Tests: XCTestCase {
    let limits = ControlWriteLimits(inputPerWindow: 60, feedbackPerWindow: 20, renewPerWindow: 60, adminPerWindow: 5)
    func profile(_ additions: [String] = ["input.independent_sequence", "events.writer_id"]) -> ControlProfile {
        .init(id: "fixture", version: "1.3", controls: [
            .init(id: "button", inputKind: .button, encoding: .boolean, feedbackKinds: [.indicator],
                  hold: .init(restValue: .bool(false), maxHoldSeconds: 2), acceptsInput: true)
        ], capabilities: ["input.button", "input.hold", "feedback.indicator", "feedback.unsequenced", "controls.input_declared"] + additions)
    }
    func session(_ additions: [String] = ["input.independent_sequence", "events.writer_id"]) throws -> SurfaceControlSession {
        try .init(instanceID: "I", epoch: "E", profile: profile(additions), writeLimits: additions.contains("writes.independent_limits") ? limits : nil)
    }
    func input(_ s: SurfaceControlSession, _ n: String, value: Bool = true, hold: Double? = nil) -> ControlInput {
        .init(expected: s.expected, expectedInputSequence: n, controlID: "button", encoding: "boolean", value: .bool(value), holdSeconds: hold)
    }
    func feedback(_ s: SurfaceControlSession) -> ControlFeedback { .init(expected: s.expected, controlID: "button", kind: "indicator", value: .string("on")) }
    func code(_ value: String, _ action: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) { XCTAssertEqual(($0 as? ControlContractError)?.code, value, file: file, line: line) }
    }
    func testIndependentInputIgnoresFeedbackButLegacyGlobalCASDoesNot() throws {
        var s = try session()
        let fresh = input(s, "0")
        let legacy = ControlInput(expected: s.expected, expectedSequence: "0", controlID: "button", encoding: "boolean", value: .bool(true))
        let f = try s.recordFeedback(feedback(s), origin: .remote, at: 0, writerID: "principal.display")
        XCTAssertEqual(f.sequence, "1"); XCTAssertEqual(f.input_sequence, "0")
        code("stale_sequence") { try s.validateInput(legacy, at: 0, writerID: "principal.operator") }
        let e = try s.recordInput(fresh, disposition: .accepted, origin: .remote, at: 0, writerID: "principal.operator")
        XCTAssertEqual(e.sequence, "2"); XCTAssertEqual(e.input_sequence, "1")
        XCTAssertEqual(e.writer_id, "principal.operator")
        code("stale_input_sequence") { try s.validateInput(fresh, at: 0, writerID: "principal.operator") }
    }
    func testParserAndSchemaRequireExactlyOneCASAndRejectWriterSpoofing() throws {
        let s = try session()
        let valid = try JSONValue.encoded(input(s, "0")).objectValue!
        guard case .input(let parsed) = try SurfaceControlTools.parse("surface_control_input", arguments: .object(valid)) else { return XCTFail() }
        XCTAssertEqual(parsed.expected_input_sequence, "0"); XCTAssertNil(parsed.expected_sequence)
        for fields in [valid.merging(["expected_sequence": .string("0")]) { _, n in n }, valid.filter { $0.key != "expected_input_sequence" }, valid.merging(["writer_id": .string("forged")]) { _, n in n }] {
            code("invalid_argument") { _ = try SurfaceControlTools.parse("surface_control_input", arguments: .object(fields)) }
        }
        let schema = try XCTUnwrap(SurfaceControlTools.descriptors.first { $0.name == "surface_control_input" }?.inputSchema.objectValue)
        XCTAssertEqual(schema["oneOf"]?.arrayValue?.count, 2)
        let legacy = try session([])
        code("invalid_argument") { try legacy.validateInput(input(legacy, "0"), at: 0) }
    }
    func testIgnoredInputAndSystemExpiryAdvanceInputWhileRenewalAndFeedbackDoNot() throws {
        var s = try session()
        try s.recordInput(input(s, "0", hold: 1), disposition: .accepted, origin: .remote, at: 0, writerID: "principal.operator")
        try s.renew(.init(expected: s.expected, controlID: "button", holdSeconds: 1), at: 0.2)
        XCTAssertEqual(s.discovery().latest_input_sequence, "1")
        try s.recordInput(input(s, "1"), disposition: .ignored, reason: "inactive_layer", origin: .remote, at: 0.2, writerID: "principal.operator")
        XCTAssertEqual(s.discovery().latest_input_sequence, "2")
        try s.recordFeedback(feedback(s), origin: .remote, at: 0.3, writerID: "principal.display")
        code("hold_expiry_pending") { try s.validateInput(input(s, "2"), at: 1.2, writerID: "principal.operator") }
        let expiry = try s.recordHoldExpiry(controlID: "button", at: 1.2, writerID: "principal.system")
        XCTAssertEqual(expiry.input_sequence, "3"); XCTAssertEqual(expiry.sequence, "4")
        XCTAssertEqual(expiry.writer_id, "principal.system"); XCTAssertEqual(expiry.reason, "hold_expired")
        XCTAssertEqual(expiry.value, .bool(false))
        code("stale_input_sequence") { try s.validateInput(input(s, "2"), at: 1.2, writerID: "principal.operator") }
    }
    func testMissingInvalidWriterFailsBeforeStateOrLeaseMutation() throws {
        var s = try session()
        let before = try s.snapshot(at: 0)
        for writer in [nil, "", "bad id", String(repeating: "x", count: 129)] as [String?] {
            code("invalid_argument") { try s.recordInput(input(s, "0", hold: 1), disposition: .accepted, origin: .remote, at: 0, writerID: writer) }
            code("invalid_argument") { try s.recordFeedback(feedback(s), origin: .remote, at: 0, writerID: writer) }
            XCTAssertEqual(try s.snapshot(at: 0), before)
        }
        try s.recordInput(input(s, "0", hold: 1), disposition: .accepted, origin: .interface, at: 0, writerID: "principal.interface")
        code("invalid_argument") { try s.recordHoldExpiry(controlID: "button", at: 1) }
        XCTAssertEqual(s.dueHoldExpiries(at: 1).count, 1)
        let legacy = try session([])
        code("invalid_argument") { try legacy.validateWriterID("principal.operator") }
    }
    func testBothCountersExhaustAtomicallyBeforeEnginePreflight() throws {
        var s = try session()
        s.inputSequence = UInt64.max
        code("sequence_exhausted") { try s.validateInput(input(s, String(UInt64.max)), at: 0, writerID: "principal.operator") }
        // Feedback can still be recorded while only the input counter is exhausted.
        try s.recordFeedback(feedback(s), origin: .remote, at: 0, writerID: "principal.display")
        s.sequence = UInt64.max
        code("sequence_exhausted") { try s.validateFeedback(feedback(s), at: 0, writerID: "principal.display") }
        code("sequence_exhausted") { try s.validateFeedback(feedback(s), writerID: "principal.display") }
        code("sequence_exhausted") { try s.validateInput(input(s, String(UInt64.max)), writerID: "principal.operator") }
        XCTAssertEqual(s.discovery().latest_sequence, String(UInt64.max))
        XCTAssertEqual(s.discovery().latest_input_sequence, String(UInt64.max))
    }
    func testContinuousPaginationCarriesReadHighwatersAndResetClearsBoth() throws {
        var s = try session()
        try s.recordInput(input(s, "0"), disposition: .accepted, origin: .remote, at: 0, writerID: "principal.operator")
        try s.recordFeedback(feedback(s), origin: .remote, at: 0, writerID: "principal.display")
        let first = try s.events(instanceID: "I", epoch: "E", afterSequence: "0", limit: 1, at: 0)
        XCTAssertEqual(first.events.map(\.sequence), ["1"])
        XCTAssertEqual(first.latest_sequence, "2"); XCTAssertEqual(first.latest_input_sequence, "1")
        let second = try s.events(instanceID: "I", epoch: "E", afterSequence: "1", at: 0)
        XCTAssertEqual(second.events.first?.input_sequence, "1")
        try s.reset(expected: s.expected, expectedSequence: "2", epoch: "new", at: 0)
        XCTAssertEqual(s.discovery().latest_sequence, "0"); XCTAssertEqual(s.discovery().latest_input_sequence, "0")
    }
    func testLimitsRequireCapabilityAndDoNotChangeMapping() throws {
        let p = profile(["input.independent_sequence", "events.writer_id", "writes.independent_limits"])
        XCTAssertEqual(p.mappingRevision, profile([]).mappingRevision)
        let s = try session(["input.independent_sequence", "events.writer_id", "writes.independent_limits"])
        XCTAssertEqual(s.discovery().write_limits, limits)
        code("invalid_profile") { _ = try SurfaceControlSession(instanceID: "I", epoch: "E", profile: p) }
        code("invalid_profile") { _ = try SurfaceControlSession(instanceID: "I", epoch: "E", profile: profile([]), writeLimits: limits) }
        for value in [0, 10001] {
            code("invalid_argument") { try ControlWriteLimits(inputPerWindow: value, feedbackPerWindow: 20, renewPerWindow: 60, adminPerWindow: 5).validate() }
        }
        let old = try session([])
        let encoded = try JSONValue.encoded(old.snapshot(at: 0)).objectValue!
        XCTAssertNil(encoded["latest_input_sequence"])
        XCTAssertNil(try JSONValue.encoded(old.discovery()).objectValue?["write_limits"])
    }
}
