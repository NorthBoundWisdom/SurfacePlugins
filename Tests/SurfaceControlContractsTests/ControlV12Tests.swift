import XCTest
import SurfacePluginContracts
@testable import SurfaceControlContracts

final class ControlV12Tests: XCTestCase {
    func profile(declared: Bool = true, accepts: Bool? = true, unsequenced: Bool = true) -> ControlProfile {
        .init(id: "fixture", version: "1.2", controls: [
            .init(id: "button", inputKind: .button, encoding: .boolean, feedbackKinds: [.indicator],
                  hold: .init(restValue: .bool(false), maxHoldSeconds: 2), acceptsInput: accepts)
        ], capabilities: ["input.button", "input.hold", "feedback.indicator"] +
              (declared ? ["controls.input_declared"] : []) + (unsequenced ? ["feedback.unsequenced"] : []))
    }
    func assertCode(_ code: String, _ action: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) { XCTAssertEqual(($0 as? ControlContractError)?.code, code, file: file, line: line) }
    }
    func testInputDeclarationIsAllOrNothingAndFalseRejectsAtomically() throws {
        try profile().validate()
        try profile(declared: false, accepts: nil).validate()
        assertCode("invalid_profile") { try profile(accepts: nil).validate() }
        assertCode("invalid_profile") { try profile(declared: false).validate() }
        var s = try SurfaceControlSession(instanceID: "I", epoch: "E", profile: profile(accepts: false))
        try s.seedInputs(["button": .bool(false)], at: 0)
        let before = try s.snapshot(at: 0)
        assertCode("permission_denied") { try s.recordInput(.init(expected: s.expected, expectedSequence: "0", controlID: "button", encoding: "boolean", value: .bool(true)), disposition: .accepted, origin: .remote, at: 0) }
        XCTAssertEqual(try s.snapshot(at: 0), before)
        try s.recordFeedback(.init(expected: s.expected, controlID: "button", kind: "indicator", value: .string("on")), origin: .remote, at: 0)
    }
    func testUnsequencedFeedbackConsumesSequenceAndKeepsFencesAndClock() throws {
        var s = try SurfaceControlSession(instanceID: "I", epoch: "E", profile: profile())
        let pending = ControlInput(expected: s.expected, expectedSequence: "0", controlID: "button", encoding: "boolean", value: .bool(true))
        let update = ControlFeedback(expected: s.expected, controlID: "button", kind: "indicator", value: .string("on"))
        let args = try JSONValue.encoded(update)
        XCTAssertNil(args.objectValue?["expected_sequence"])
        guard case .feedback(let parsed) = try SurfaceControlTools.parse("surface_control_feedback", arguments: args) else { return XCTFail() }
        XCTAssertEqual(parsed, update)
        XCTAssertEqual(try s.recordFeedback(update, origin: .remote, at: 1).sequence, "1")
        assertCode("stale_sequence") { try s.recordInput(pending, disposition: .accepted, origin: .remote, at: 1) }
        assertCode("stale_sequence") { try s.recordFeedback(.init(expected: s.expected, expectedSequence: "0", controlID: "button", kind: "indicator", value: .string("off")), origin: .remote, at: 1) }
        assertCode("invalid_time") { try s.recordFeedback(update, origin: .remote, at: 0) }
        try s.recordInput(.init(expected: s.expected, expectedSequence: "1", controlID: "button", encoding: "boolean", value: .bool(true), holdSeconds: 1), disposition: .accepted, origin: .remote, at: 1)
        assertCode("hold_expiry_pending") { try s.recordFeedback(update, origin: .remote, at: 2) }
        let old = s.expected
        try s.recordHoldExpiry(controlID: "button", at: 2)
        try s.reset(expected: old, expectedSequence: "3", epoch: "new", at: 2)
        assertCode("stale_epoch") { try s.recordFeedback(update, origin: .remote, at: 2) }
        let legacy = try SurfaceControlSession(instanceID: "I", epoch: "E", profile: profile(declared: false, accepts: nil, unsequenced: false))
        assertCode("invalid_argument") { try legacy.validateFeedback(.init(expected: legacy.expected, controlID: "button", kind: "indicator", value: .string("on")), at: 0) }
    }
    func testEventPagesCarryCurrentHoldsEvenWhenEmptyAndRenewalIsSilent() throws {
        var s = try SurfaceControlSession(instanceID: "I", epoch: "E", profile: profile())
        func page(_ time: Double) throws -> ControlEventPage { try s.events(instanceID: "I", epoch: "E", afterSequence: "1", at: time) }
        try s.recordInput(.init(expected: s.expected, expectedSequence: "0", controlID: "button", encoding: "boolean", value: .bool(true), holdSeconds: 1), disposition: .accepted, origin: .remote, at: 0)
        XCTAssertEqual(try page(0).holds, ["button": 1])
        try s.renew(.init(expected: s.expected, controlID: "button", holdSeconds: 2), at: 0.5)
        XCTAssertEqual(try page(1).holds, ["button": 2.5])
        XCTAssertTrue(try page(1).events.isEmpty)
        XCTAssertEqual(try page(1).latest_sequence, "1")
        try s.recordHoldExpiry(controlID: "button", at: 2.5)
        XCTAssertNil(try page(2.5).holds)
        XCTAssertNil(try JSONValue.encoded(page(2.5)).objectValue?["holds"])
    }
    func testRevisionWithoutDeclarationKeepsV11ExampleAndDeclarationChangesIt() {
        let old = ControlProfile(id: "example.scalar", version: "1", controls: [
            .init(id: "dial.1", inputKind: .absolute, encoding: .scalar, range: .init(minimum: 0, maximum: 100, step: 1), feedbackKinds: [.value, .indicator], mapping: .init(kind: .parameter, id: "example.input")),
            .init(id: "button.1", inputKind: .button, encoding: .boolean, feedbackKinds: [.indicator], hold: .init(restValue: .bool(false), maxHoldSeconds: 2))])
        XCTAssertEqual(old.mappingRevision, "99b95ecb012073e4")
        XCTAssertNotEqual(profile().mappingRevision, profile(accepts: false).mappingRevision)
        XCTAssertEqual(profile().mappingRevision, "d7291a4e96e8aba4")
    }
}
