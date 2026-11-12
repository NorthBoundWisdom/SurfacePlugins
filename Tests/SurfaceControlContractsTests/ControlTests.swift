import XCTest
import SurfacePluginContracts
@testable import SurfaceControlContracts

final class ControlTests: XCTestCase {
    func profile(_ id: String = "fixture.alpha") -> ControlProfile {
        .init(id: id, version: "1", controls: [
            .init(id: "absolute.1", inputKind: .absolute, encoding: .scalar, range: .init(minimum: 0, maximum: 100, step: 1), feedbackKinds: [.value, .indicator], mapping: .init(kind: .parameter, id: "consumer.input")),
            .init(id: "relative.1", inputKind: .relative, encoding: .signedDelta, range: .init(minimum: -8, maximum: 8, step: 1)),
            .init(id: "button.1", inputKind: .button, encoding: .boolean, feedbackKinds: [.indicator])
        ], capabilities: ["simulation", "input.absolute", "input.relative", "input.button"])
    }
    func session(_ id: String = "fixture.alpha", capacity: Int = 1024) throws -> SurfaceControlSession {
        try .init(instanceID: "instance-A", epoch: "epoch-1", mappingRevision: "map-1", profile: profile(id), eventCapacity: capacity)
    }
    func input(_ state: SurfaceControlSession, _ value: JSONValue = .number(1), id: String = "absolute.1", encoding: String = "scalar") -> ControlInput {
        .init(expected: state.expected, expectedSequence: state.discovery().latest_sequence, controlID: id, encoding: encoding, value: value)
    }
    func assertCode(_ code: String, _ action: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) { error in
            XCTAssertEqual((error as? ControlContractError)?.code, code, file: file, line: line)
        }
    }
    func testTwoProfilesUseIdenticalInputSemanticsAndExplicitSimulationSource() throws {
        var a = try session(), b = try session("fixture.beta")
        for value in [0, 75, 100] {
            let x = try a.recordInput(input(a, .number(value)), disposition: .accepted, mappedValue: .number(value), origin: .remote, at: Double(value))
            let y = try b.recordInput(input(b, .number(value)), disposition: .accepted, mappedValue: .number(value), origin: .remote, at: Double(value))
            XCTAssertEqual(x.value, y.value); XCTAssertEqual(x.sequence, y.sequence)
            XCTAssertEqual(x.source, .simulation); XCTAssertEqual(x.origin, .remote)
        }
        XCTAssertEqual(try a.snapshot(at: 100).inputs, try b.snapshot(at: 100).inputs)
        XCTAssertEqual(a.discovery().contract_version, "1.0")
        XCTAssertEqual(a.discovery().profile.id, "fixture.alpha")
    }
    func testInputEncodingAndValuesFailWithoutFallbackOrMutation() throws {
        var s = try session()
        let before = try s.snapshot(at: 100)
        for value in [JSONValue.double(.nan), .double(.infinity), .double(0.5), .number(101), .bool(true)] {
            assertCode("invalid_value") { _ = try s.recordInput(input(s, value), disposition: .accepted, origin: .remote, at: 0) }
        }
        assertCode("unsupported_encoding") { try s.validateInput(input(s, encoding: "ordinaryCC")) }
        assertCode("unsupported_control") { try s.validateInput(input(s, id: "missing")) }
        XCTAssertEqual(try s.snapshot(at: 100), before)
        try s.validateInput(input(s, .number(-3), id: "relative.1", encoding: "signedDelta"))
        try s.validateInput(input(s, .bool(true), id: "button.1", encoding: "boolean"))
        assertCode("invalid_value") { try s.validateInput(input(s, .number(1), id: "button.1", encoding: "boolean")) }
    }
    func testFeedbackNeverCreatesInputAndIgnoredDoesNotChangeValues() throws {
        var s = try session()
        let update = ControlFeedback(expected: s.expected, expectedSequence: s.discovery().latest_sequence, controlID: "absolute.1", kind: "value", value: .number(40))
        let event = try s.recordFeedback(update, origin: .remote, at: 1)
        XCTAssertEqual(event.kind, .feedback); XCTAssertTrue(try s.snapshot(at: 100).inputs.isEmpty)
        XCTAssertEqual(try s.snapshot(at: 100).feedback["absolute.1"]?["value"], .number(40))
        try s.recordInput(input(s, .number(80)), disposition: .ignored, reason: "inactive_layer", origin: .remote, at: 1)
        XCTAssertTrue(try s.snapshot(at: 100).inputs.isEmpty)
        let before = try s.snapshot(at: 100)
        assertCode("invalid_result") { try s.recordInput(input(s), disposition: .ignored, origin: .remote, at: 1) }
        XCTAssertEqual(try s.snapshot(at: 100), before)
        let indicator = ControlFeedback(expected: s.expected, expectedSequence: s.discovery().latest_sequence, controlID: "button.1", kind: "indicator", value: .string("blink"))
        try s.recordFeedback(indicator, origin: .remote, at: 2)
        assertCode("unsupported_feedback") { try s.validateFeedback(.init(expected: s.expected, expectedSequence: s.discovery().latest_sequence, controlID: "relative.1", kind: "value", value: .number(1))) }
        assertCode("invalid_value") { try s.validateFeedback(.init(expected: s.expected, expectedSequence: s.discovery().latest_sequence, controlID: "button.1", kind: "indicator", value: .string("active"))) }
    }
    func testInstanceEpochProfileAndMappingFencesBeforeEngineWork() throws {
        let s = try session()
        for (expected, code) in [
            (ControlExpected(instanceID: "B", epoch: "epoch-1", mappingRevision: "map-1", profileID: "fixture.alpha", profileVersion: "1"), "instance_mismatch"),
            (.init(instanceID: "instance-A", epoch: "old", mappingRevision: "map-1", profileID: "fixture.alpha", profileVersion: "1"), "stale_epoch"),
            (.init(instanceID: "instance-A", epoch: "epoch-1", mappingRevision: "old", profileID: "fixture.alpha", profileVersion: "1"), "stale_mapping"),
            (.init(instanceID: "instance-A", epoch: "epoch-1", mappingRevision: "map-1", profileID: "unknown", profileVersion: "1"), "unsupported_profile")
        ] {
            var engineCalls = 0
            assertCode(code) {
                try s.validateInput(.init(expected: expected, expectedSequence: "0", controlID: "absolute.1", encoding: "scalar", value: .number(1)), at: 0)
                engineCalls += 1
            }
            XCTAssertEqual(engineCalls, 0)
        }
    }
    func testJournalOverflowFutureCursorAndResetRequireNewPreparation() throws {
        var s = try session(capacity: 2)
        let old = s.expected
        for n in 1...3 { try s.recordInput(input(s, .number(n)), disposition: .accepted, origin: .interface, at: Double(n)) }
        assertCode("event_gap") { _ = try s.events(instanceID: "instance-A", epoch: "epoch-1", afterSequence: "0", at: 100) }
        assertCode("event_gap") { _ = try s.events(instanceID: "instance-A", epoch: "epoch-1", afterSequence: "4", at: 100) }
        XCTAssertEqual(try s.events(instanceID: "instance-A", epoch: "epoch-1", afterSequence: "1", limit: 1, at: 100).events.map(\.sequence), ["2"])
        try s.reset(expected: old, expectedSequence: "3", epoch: "epoch-2", mappingRevision: "map-2", at: 3)
        XCTAssertEqual(try s.snapshot(at: 100).latest_sequence, "0"); XCTAssertTrue(try s.snapshot(at: 100).inputs.isEmpty)
        assertCode("stale_epoch") { try s.validateExpected(old) }
        assertCode("stale_epoch") { _ = try s.events(instanceID: "instance-A", epoch: "epoch-1", afterSequence: "3", at: 100) }
        let before = try s.snapshot(at: 100)
        assertCode("invalid_argument") { try s.reset(expected: s.expected, expectedSequence: "0", epoch: "epoch-2", mappingRevision: "map-3", at: 3) }
        XCTAssertEqual(try s.snapshot(at: 100), before)
    }
    func testRegressingAndNonfiniteTimeAreAtomic() throws {
        var s = try session()
        try s.recordInput(input(s), disposition: .accepted, origin: .remote, at: 2)
        let before = try s.snapshot(at: 100)
        for time in [Double.nan, .infinity, 1] {
            assertCode("invalid_time") { try s.recordInput(input(s), disposition: .accepted, origin: .remote, at: time) }
        }
        XCTAssertEqual(try s.snapshot(at: 100), before)
    }
    func testStrictToolsRejectSourceSpoofingUnknownFieldsAndFractionalCursorLimit() throws {
        let s = try session()
        let args = try JSONValue.encoded(input(s))
        guard case .input(let decoded) = try SurfaceControlTools.parse("surface_control_input", arguments: args) else { return XCTFail() }
        XCTAssertEqual(decoded, input(s))
        var object = args.objectValue!
        object["source"] = .string("hardware")
        assertCode("invalid_argument") { _ = try SurfaceControlTools.parse("surface_control_input", arguments: .object(object)) }
        var nested = args.objectValue!
        var expected = nested["expected"]!.objectValue!; expected["extra"] = .number(1); nested["expected"] = .object(expected)
        assertCode("invalid_argument") { _ = try SurfaceControlTools.parse("surface_control_input", arguments: .object(nested)) }
        let events: JSONValue = .object(["instance_id": .string("instance-A"), "epoch": .string("epoch-1"), "after_sequence": .string("0"), "limit": .double(1.1)])
        assertCode("invalid_argument") { _ = try SurfaceControlTools.parse("surface_control_events", arguments: events) }
        assertCode("unsupported_tool") { _ = try SurfaceControlTools.parse("surface_unknown", arguments: .object([:])) }
        XCTAssertEqual(Set(SurfaceControlTools.descriptors.map(\.name)).count, 6)
    }
    func testProfileValidationRejectsDuplicateAndUnsupportedCombinations() throws {
        let control = profile().controls[0]
        assertCode("invalid_profile") { try ControlProfile(id: "fixture", version: "1", controls: [control, control]).validate() }
        assertCode("unsupported_encoding") { try ControlProfile(id: "fixture", version: "1", controls: [.init(id: "x", inputKind: .button, encoding: .scalar)]).validate() }
        assertCode("invalid_profile") { try ControlValueRange(minimum: 0, maximum: .infinity).validate() }
    }
    func testCASRejectsDuplicateInputFeedbackAndResetWithoutReplay() throws {
        var s = try session()
        let first = input(s)
        try s.recordInput(first, disposition: .ignored, reason: "unmapped", origin: .remote, at: 1)
        assertCode("stale_sequence") { try s.recordInput(first, disposition: .accepted, origin: .remote, at: 1) }
        let update = ControlFeedback(expected: s.expected, expectedSequence: "1", controlID: "absolute.1", kind: "value", value: .number(20))
        try s.recordFeedback(update, origin: .remote, at: 2)
        let before = try s.snapshot(at: 100)
        assertCode("stale_sequence") { try s.recordFeedback(update, origin: .remote, at: 2) }
        assertCode("stale_sequence") { try s.reset(expected: s.expected, expectedSequence: "1", epoch: "new", mappingRevision: "m2", at: 2) }
        assertCode("invalid_argument") { try s.validateSequence("02") }
        XCTAssertEqual(try s.snapshot(at: 100), before)
        try s.reset(expected: s.expected, expectedSequence: "2", epoch: "new", mappingRevision: "m2", at: 3)
        assertCode("invalid_time") { try s.recordInput(input(s), disposition: .accepted, origin: .remote, at: 2) }
        assertCode("invalid_time") { _ = try s.snapshot(at: 2) }
        XCTAssertEqual(try s.snapshot(at: 4).server_time, 4)
        // Reading at 100 did not commit a clock; a write at 4 is valid after reset at 3.
        _ = try s.snapshot(at: 100)
        try s.recordInput(input(s), disposition: .accepted, origin: .remote, at: 4)
    }
    func testRelativeFeedbackRangeAndHostBootstrapAreSeparateFromInput() throws {
        let p = ControlProfile(id: "fixture.delta", version: "1", controls: [
            .init(id: "dial", inputKind: .relative, encoding: .signedDelta, range: .init(minimum: -8, maximum: 8, step: 1),
                  feedbackRange: .init(minimum: 0, maximum: 100, step: 1), feedbackKinds: [.value])])
        var s = try SurfaceControlSession(instanceID: "A", epoch: "e", mappingRevision: "m", profile: p)
        assertCode("invalid_value") { try s.seedInputs(["dial": .number(80)], at: 0) }
        try s.seedInputs(["dial": .number(0)], at: 0)
        XCTAssertEqual(try s.snapshot(at: 0).inputs["dial"], .number(0))
        XCTAssertEqual(s.discovery().latest_sequence, "0")
        XCTAssertTrue(try s.events(instanceID: "A", epoch: "e", afterSequence: "0", at: 0).events.isEmpty)
        assertCode("invalid_transition") { try s.seedInputs(["dial": .number(1)], at: 0) }
        try s.recordFeedback(.init(expected: s.expected, expectedSequence: "0", controlID: "dial", kind: "value", value: .number(80)), origin: .remote, at: 1)
        XCTAssertEqual(try s.snapshot(at: 1).inputs["dial"], .number(0))
    }
    func testSeedBatchIsAtomicAndResetAllowsNewKnownModelState() throws {
        var s = try session()
        assertCode("invalid_value") { try s.seedInputs(["absolute.1": .number(30), "button.1": .number(1)], at: 1) }
        XCTAssertTrue(try s.snapshot(at: 0).inputs.isEmpty)
        try s.seedInputs(["absolute.1": .number(30), "button.1": .bool(false)], at: 2)
        assertCode("invalid_time") { try s.recordInput(input(s), disposition: .accepted, origin: .remote, at: 1) }
        try s.reset(expected: s.expected, expectedSequence: "0", epoch: "reset", mappingRevision: "reset", at: 3)
        try s.seedInputs(["absolute.1": .number(0)], at: 3)
        XCTAssertEqual(try s.snapshot(at: 3).inputs, ["absolute.1": .number(0)])
    }
    func testPublishedSchemasMatchDescriptors() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/surface-control-tools.json")
        let published = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
        XCTAssertEqual(published.objectValue?["tools"], try .encoded(SurfaceControlTools.descriptors))
    }
    func testMappedOutputRejectsNonScalarAndNonfiniteAtomically() throws {
        var s = try session()
        let before = try s.snapshot(at: 0)
        for value in [JSONValue.object([:]), .array([]), .null, .double(.nan), .double(.infinity), .string("")] {
            assertCode("invalid_result") { try s.recordInput(input(s), disposition: .accepted, mappedValue: value, origin: .remote, at: 0) }
            XCTAssertEqual(try s.snapshot(at: 0), before)
        }
        for value in [JSONValue.number(1), .bool(true), .string("known")] {
            try s.recordInput(input(s), disposition: .accepted, mappedValue: value, origin: .remote, at: 0)
        }
    }
}
