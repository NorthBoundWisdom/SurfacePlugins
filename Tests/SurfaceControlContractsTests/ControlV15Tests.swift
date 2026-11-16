import XCTest
import SurfacePluginContracts
@testable import SurfaceControlContracts

final class ControlV15Tests: XCTestCase {
    func profile(hardware: Bool = false, retained: Bool = true, rehearsal: Bool = false) -> ControlProfile {
        var caps = [hardware ? "hardware" : "simulation", "controls.input_declared", "input.button", "feedback.indicator", "feedback.unsequenced", "input.independent_sequence", "events.writer_id"]
        if retained { caps.append("events.input_retention") }
        if rehearsal { caps.append("session.owned_virtual_rehearsal") }
        if !hardware { caps.append("input.hold") }
        return .init(id: rehearsal ? "test.owned-virtual-rehearsal" : "test.retained", version: "1.5", controls: [
            .init(id: "button", inputKind: .button, encoding: .boolean, feedbackKinds: [.indicator],
                  hold: hardware ? nil : .init(restValue: .bool(false), maxHoldSeconds: 2), acceptsInput: !hardware)
        ], capabilities: caps)
    }
    func session(capacity: Int = 4, hardware: Bool = false) throws -> SurfaceControlSession {
        var s = try SurfaceControlSession(instanceID: "I", epoch: "E", profile: profile(hardware: hardware), eventCapacity: 2, inputEventCapacity: capacity)
        if hardware { try s.transitionHardware(epoch: "connected", linkState: .connected, at: 0) }
        return s
    }
    func input(_ s: SurfaceControlSession, hold: Double? = nil) -> ControlInput {
        .init(expected: s.expected, expectedInputSequence: s.discovery().latest_input_sequence!, controlID: "button", encoding: "boolean", value: .bool(true), holdSeconds: hold)
    }
    func feedback(_ s: SurfaceControlSession) -> ControlFeedback {
        .init(expected: s.expected, controlID: "button", kind: "indicator", value: .string("on"))
    }
    func page(_ s: SurfaceControlSession, after: String = "0", limit: Int = 128, at: Double = 0) throws -> ControlInputEventPage {
        try s.inputEvents(expected: s.expected, afterInputSequence: after, limit: limit, at: at)
    }
    func code(_ expected: String, _ action: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) { XCTAssertEqual(($0 as? ControlContractError)?.code, expected, file: file, line: line) }
    }
    func testFeedbackFloodCannotEvictAcceptedIgnoredOrExpiryInputs() throws {
        var s = try session()
        let first = try s.recordInput(input(s, hold: 1), disposition: .accepted, origin: .remote, at: 0, writerID: "operator")
        for _ in 0..<20 { try s.recordFeedback(feedback(s), origin: .remote, at: 0, writerID: "display") }
        let ignored = try s.recordInput(input(s), disposition: .ignored, reason: "inactive_layer", origin: .interface, at: 0, writerID: "interface")
        try s.renew(.init(expected: s.expected, controlID: "button", holdSeconds: 1), at: 0)
        XCTAssertEqual(try page(s).events, [first, ignored])
        let expiry = try s.recordHoldExpiry(controlID: "button", at: 1, writerID: "system")
        for _ in 0..<20 { try s.recordFeedback(feedback(s), origin: .remote, at: 1, writerID: "display") }
        XCTAssertEqual(try page(s, at: 1).events, [first, ignored, expiry])
        XCTAssertEqual(try page(s, at: 1).events.map(\.input_sequence), ["1", "2", "3"])
        XCTAssertEqual(try page(s, at: 1).events.map(\.sequence), ["1", "22", "23"])
        XCTAssertEqual(expiry.reason, "hold_expired"); XCTAssertEqual(expiry.writer_id, "system")
        code("event_gap") { _ = try s.events(instanceID: "I", epoch: "E", afterSequence: "0", at: 1) }
        code("stale_sequence") { try s.validateSequence("1") }
        XCTAssertEqual(try s.snapshot(at: 1).inputs["button"], .bool(false))
    }
    func testInputOverflowFutureCursorAndPaginationRemainExplicit() throws {
        var s = try session(capacity: 2)
        for _ in 0..<3 { try s.recordInput(input(s), disposition: .ignored, reason: "no_change", origin: .remote, at: 0, writerID: "operator") }
        for cursor in ["0", "4", String(UInt64.max)] { code("input_event_gap") { _ = try page(s, after: cursor) } }
        for cursor in ["", "01", "-1", "+1", "18446744073709551616"] { code("invalid_argument") { _ = try page(s, after: cursor) } }
        XCTAssertEqual(try page(s, after: "1", limit: 1).events.map(\.input_sequence), ["2"])
        XCTAssertEqual(try page(s, after: "2", limit: 1).events.map(\.input_sequence), ["3"])
        XCTAssertTrue(try page(s, after: "3").events.isEmpty)
        code("invalid_argument") { _ = try page(s, after: "3", limit: 0) }
        code("invalid_argument") { _ = try page(s, after: "3", limit: 1025) }
    }
    func testResetClearsBothLogsCountersHoldsAndRetainsCapacity() throws {
        var s = try session()
        try s.recordInput(input(s, hold: 1), disposition: .accepted, origin: .remote, at: 0, writerID: "operator")
        let old = s.expected
        try s.reset(expected: old, expectedSequence: "1", epoch: "new", at: 0)
        XCTAssertEqual(s.inputEventCapacity, 4); XCTAssertEqual(s.discovery().contract_version, "1.5")
        XCTAssertEqual(try page(s).latest_input_sequence, "0"); XCTAssertEqual(try page(s).latest_sequence, "0")
        XCTAssertTrue(try page(s).events.isEmpty); XCTAssertTrue(try s.snapshot(at: 0).inputs.isEmpty)
        code("stale_epoch") { _ = try s.inputEvents(expected: old, afterInputSequence: "0", at: 0) }
        XCTAssertTrue(s.dueHoldExpiries(at: 2).isEmpty)
    }
    func testHardware15UsesOnlyTrustedInputsAndClearsUnknownsOnTransition() throws {
        var s = try session(hardware: true)
        XCTAssertEqual(s.discovery().contract_version, "1.5")
        XCTAssertTrue(try s.snapshot(at: 0).inputs.isEmpty)
        code("permission_denied") { try s.recordInput(input(s), disposition: .accepted, origin: .remote, at: 0, writerID: "remote") }
        code("unsupported_hold") { _ = try s.renew(.init(expected: s.expected, controlID: "button", holdSeconds: 1), at: 0) }
        code("unsupported_tool") { try s.reset(expected: s.expected, expectedSequence: "0", epoch: "remote", at: 0) }
        let event = try s.recordHardwareInput(.init(expected: s.expected, controlID: "button", encoding: "boolean", value: .bool(true)), disposition: .accepted, at: 0, writerID: "device")
        XCTAssertEqual(event.origin, .hardware); XCTAssertEqual(try page(s).events, [event])
        XCTAssertEqual(try page(s).link?.state, .connected)
        try s.transitionHardware(epoch: "disconnect", linkState: .disconnected, at: 0)
        XCTAssertTrue(try page(s).events.isEmpty); XCTAssertTrue(try s.snapshot(at: 0).inputs.isEmpty)
        XCTAssertEqual(try page(s).link?.state, .disconnected)
    }
    func testCapacityAndCapabilityMustBeExplicitAndMappingStaysContentDerived() throws {
        let p = profile()
        XCTAssertEqual(p.mappingRevision, profile(retained: false).mappingRevision)
        for capacity in [0, 65537] { code("invalid_argument") { _ = try SurfaceControlSession(instanceID: "I", epoch: "E", profile: p, inputEventCapacity: capacity) } }
        for capacity in [1, 65536] { XCTAssertEqual(try SurfaceControlSession(instanceID: "I", epoch: "E", profile: p, inputEventCapacity: capacity).inputEventCapacity, capacity) }
        code("invalid_profile") { _ = try SurfaceControlSession(instanceID: "I", epoch: "E", profile: p) }
        code("invalid_profile") { _ = try SurfaceControlSession(instanceID: "I", epoch: "E", profile: profile(retained: false), inputEventCapacity: 2) }
        let old = try SurfaceControlSession(instanceID: "I", epoch: "E", profile: profile(retained: false))
        XCTAssertEqual(old.discovery().contract_version, "1.3")
        code("unsupported_input_retention") { _ = try page(old) }
        XCTAssertEqual(SurfaceControlTools.descriptors.count, 7)
        XCTAssertEqual(SurfaceControlInputEventsTools.descriptors(source: .simulation).count, 1)
        XCTAssertFalse(SurfaceControlInputEventsTools.descriptors(source: .hardware)[0].isMutation)
    }
    func testRehearsalIsHardwareOnlyIndependentOfRetentionAndAddsNoTools() throws {
        let p = profile(hardware: true, retained: false, rehearsal: true)
        let s = try SurfaceControlSession(instanceID: "I", epoch: "E", profile: p)
        XCTAssertEqual(s.discovery().contract_version, "1.5"); XCTAssertNil(s.inputEventCapacity)
        XCTAssertEqual(s.source, .hardware)
        code("invalid_profile") { try profile(retained: false, rehearsal: true).validate() }
        code("unsupported_input_retention") { _ = try page(s) }
        code("permission_denied") { try s.validateInput(input(s), writerID: "remote") }
    }
    func testIdentityThenTimeThenExpiryThenCursorErrorsDoNotMutateLogs() throws {
        var s = try session()
        try s.recordInput(input(s, hold: 1), disposition: .accepted, origin: .remote, at: 0, writerID: "operator")
        let bad = ControlExpected(instanceID: "wrong", epoch: "wrong", mappingRevision: "wrong", profileID: "wrong", profileVersion: "wrong")
        code("instance_mismatch") { _ = try s.inputEvents(expected: bad, afterInputSequence: "bad", at: .nan) }
        code("invalid_time") { _ = try page(s, after: "bad", at: -.infinity) }
        code("hold_expiry_pending") { _ = try page(s, after: "bad", at: 1) }
        XCTAssertEqual(try page(s).events.count, 1)
    }
    func testExpiryOrCounterFailureCannotHalfCommitEitherLogOrLease() throws {
        var s = try session()
        try s.recordInput(input(s, hold: 1), disposition: .accepted, origin: .remote, at: 0, writerID: "operator")
        let records = try page(s).events
        code("invalid_argument") { try s.recordHoldExpiry(controlID: "button", at: 1, writerID: nil) }
        XCTAssertEqual(s.dueHoldExpiries(at: 1).count, 1); XCTAssertEqual(try page(s).events, records)
        s.inputSequence = .max
        code("sequence_exhausted") { try s.recordHoldExpiry(controlID: "button", at: 1, writerID: "system") }
        XCTAssertEqual(s.dueHoldExpiries(at: 1).count, 1); XCTAssertEqual(try page(s).events, records)
        code("sequence_exhausted") { try s.recordInput(input(s), disposition: .accepted, origin: .remote, at: 0, writerID: "operator") }
        s.sequence = .max
        code("sequence_exhausted") { try s.recordFeedback(feedback(s), origin: .remote, at: 0, writerID: "display") }
        XCTAssertEqual(try page(s).events, records)
    }
    func testStrictNewParserRejectsSpoofedSourceWriterAndUnknownIdentityFields() throws {
        let s = try session()
        let good = try JSONValue.encoded(ControlInputEventsRequest(expected: s.expected, afterInputSequence: "0", limit: 1))
        XCTAssertEqual(try SurfaceControlInputEventsTools.parse(SurfaceControlInputEventsTools.name, arguments: good).limit, 1)
        code("unsupported_tool") { _ = try SurfaceControlTools.parse(SurfaceControlInputEventsTools.name, arguments: good) }
        for (key, value) in [("source", JSONValue.string("hardware")), ("writer_id", .string("forged")), ("limit", .double(1.5)), ("after_input_sequence", .string("01"))] {
            var bad = good.objectValue!; bad[key] = value
            code("invalid_argument") { _ = try SurfaceControlInputEventsTools.parse(SurfaceControlInputEventsTools.name, arguments: .object(bad)) }
        }
        var bad = good.objectValue!; var expected = bad["expected"]!.objectValue!; expected["extra"] = .bool(true); bad["expected"] = .object(expected)
        code("invalid_argument") { _ = try SurfaceControlInputEventsTools.parse(SurfaceControlInputEventsTools.name, arguments: .object(bad)) }
    }
    func testLastUInt64InputCanBeReadWithoutGapArithmeticOverflow() throws {
        var s = try session(capacity: 1)
        s.sequence = UInt64.max - 1; s.inputSequence = UInt64.max - 1
        let event = try s.recordInput(input(s), disposition: .accepted, origin: .remote, at: 0, writerID: "operator")
        XCTAssertEqual(event.input_sequence, String(UInt64.max))
        XCTAssertEqual(try page(s, after: String(UInt64.max - 1)).events, [event])
        XCTAssertTrue(try page(s, after: String(UInt64.max)).events.isEmpty)
        code("input_event_gap") { _ = try page(s, after: "0") }
        code("sequence_exhausted") { try s.recordInput(input(s), disposition: .accepted, origin: .remote, at: 0, writerID: "operator") }
    }

}
