import XCTest
import SurfacePluginContracts
@testable import SurfaceControlContracts

/// Contract 1.1 additions: mapping revision, capability vocabulary, numeric normalization, input.hold.
final class ControlV11Tests: XCTestCase {
    func holdProfile(maxHold: Double = 2, capabilities: [String]? = nil) -> ControlProfile {
        .init(id: "fixture.hold", version: "1.1", controls: [
            .init(id: "deadman", inputKind: .button, encoding: .boolean, feedbackKinds: [.indicator],
                  hold: .init(restValue: .bool(false), maxHoldSeconds: maxHold)),
            .init(id: "axis", inputKind: .absolute, encoding: .scalar, range: .init(minimum: -100, maximum: 100, step: 1),
                  feedbackKinds: [.value], mapping: .init(kind: .parameter, id: "consumer.axis"),
                  hold: .init(restValue: .number(0), maxHoldSeconds: maxHold)),
            .init(id: "plain", inputKind: .absolute, encoding: .scalar, range: .init(minimum: 0, maximum: 127, step: 1))
        ], capabilities: capabilities ?? ["simulation", "controls.stable_ids", "input.button", "input.absolute", "input.hold",
                                          "feedback.value", "feedback.indicator", "x.fixture.extra"])
    }
    func session() throws -> SurfaceControlSession { try .init(instanceID: "I", epoch: "e1", profile: holdProfile()) }
    func input(_ s: SurfaceControlSession, _ id: String, _ value: JSONValue, hold: Double? = nil) -> ControlInput {
        let encoding = s.profile.controls.first { $0.id == id }!.encoding.rawValue
        return .init(expected: s.expected, expectedSequence: s.discovery().latest_sequence, controlID: id, encoding: encoding, value: value, holdSeconds: hold)
    }
    func assertCode(_ code: String, _ action: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) { error in
            XCTAssertEqual((error as? ControlContractError)?.code, code, file: file, line: line)
        }
    }

    // MARK: mapping revision
    func testMappingRevisionIsDeterministicOrderIndependentAndSensitiveToMappingFields() throws {
        let p = holdProfile()
        XCTAssertEqual(p.mappingRevision.count, 16)
        XCTAssertTrue(p.mappingRevision.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertEqual(p.mappingRevision, holdProfile().mappingRevision)
        // Control order, feedback kind order, capabilities, profile id/version are not part of the mapping.
        let reordered = ControlProfile(id: "other", version: "9", controls: p.controls.reversed(), capabilities: ["input.button", "input.absolute", "input.hold", "feedback.value", "feedback.indicator"])
        XCTAssertEqual(reordered.mappingRevision, p.mappingRevision)
        // .number and .double of the same value give the same revision.
        let doubled = ControlProfile(id: p.id, version: p.version, controls: [
            p.controls[0],
            .init(id: "axis", inputKind: .absolute, encoding: .scalar, range: .init(minimum: -100.0, maximum: 100.0, step: 1.0),
                  feedbackKinds: [.value], mapping: .init(kind: .parameter, id: "consumer.axis"), hold: .init(restValue: .double(0), maxHoldSeconds: 2)),
            p.controls[2]], capabilities: p.capabilities)
        XCTAssertEqual(doubled.mappingRevision, p.mappingRevision)
        func changed(_ control: ControlDescriptor) -> String {
            ControlProfile(id: p.id, version: p.version, controls: [p.controls[0], control, p.controls[2]], capabilities: p.capabilities).mappingRevision
        }
        let variants: [ControlDescriptor] = [
            .init(id: "axis", inputKind: .absolute, encoding: .scalar, range: .init(minimum: -100, maximum: 99, step: 1), feedbackKinds: [.value], mapping: .init(kind: .parameter, id: "consumer.axis"), hold: p.controls[1].hold),
            .init(id: "axis", inputKind: .absolute, encoding: .scalar, range: .init(minimum: -100, maximum: 100, step: 1), feedbackKinds: [.value], mapping: .init(kind: .parameter, id: "consumer.other"), hold: p.controls[1].hold),
            .init(id: "axis", inputKind: .absolute, encoding: .scalar, range: .init(minimum: -100, maximum: 100, step: 1), feedbackKinds: [.value], mapping: .init(kind: .action, id: "consumer.axis"), hold: p.controls[1].hold),
            .init(id: "axis", inputKind: .absolute, encoding: .scalar, range: .init(minimum: -100, maximum: 100, step: 1), feedbackKinds: [.value], mapping: nil, hold: p.controls[1].hold),
            .init(id: "axis", inputKind: .absolute, encoding: .scalar, range: .init(minimum: -100, maximum: 100, step: 1), feedbackKinds: [.value, .indicator], mapping: .init(kind: .parameter, id: "consumer.axis"), hold: p.controls[1].hold),
            .init(id: "axis", inputKind: .absolute, encoding: .scalar, range: .init(minimum: -100, maximum: 100, step: 1), feedbackRange: .init(minimum: 0, maximum: 10), feedbackKinds: [.value], mapping: .init(kind: .parameter, id: "consumer.axis"), hold: p.controls[1].hold),
            .init(id: "axis", inputKind: .absolute, encoding: .scalar, range: .init(minimum: -100, maximum: 100, step: 1), feedbackKinds: [.value], mapping: .init(kind: .parameter, id: "consumer.axis"), hold: .init(restValue: .number(0), maxHoldSeconds: 3)),
            .init(id: "axis", inputKind: .absolute, encoding: .scalar, range: .init(minimum: -100, maximum: 100, step: 1), feedbackKinds: [.value], mapping: .init(kind: .parameter, id: "consumer.axis"), hold: nil),
            .init(id: "axis2", inputKind: .absolute, encoding: .scalar, range: .init(minimum: -100, maximum: 100, step: 1), feedbackKinds: [.value], mapping: .init(kind: .parameter, id: "consumer.axis"), hold: p.controls[1].hold)
        ]
        let revisions = Set(variants.map(changed))
        XCTAssertEqual(revisions.count, variants.count)
        XCTAssertFalse(revisions.contains(p.mappingRevision))
    }
    func testCanonicalDocumentAndHashArePinned() {
        // Pinned so the Python SDK and hosts can reproduce the exact algorithm.
        let p = ControlProfile(id: "x", version: "1", controls: [
            .init(id: "b", inputKind: .button, encoding: .boolean, feedbackKinds: [.indicator, .value]),
            .init(id: "a", inputKind: .absolute, encoding: .scalar, range: .init(minimum: 0, maximum: 1.5, step: 0.5), mapping: .init(kind: .parameter, id: "p\"q"))])
        XCTAssertEqual(ControlCanonicalJSON.mappingDocument(p),
                       #"[{"encoding":"scalar","feedback_kinds":[],"id":"a","input_kind":"absolute","mapping":{"id":"p\"q","kind":"parameter"},"range":{"maximum":1.5,"minimum":0,"step":0.5}},{"encoding":"boolean","feedback_kinds":["indicator","value"],"id":"b","input_kind":"button"}]"#)
        XCTAssertEqual(ControlCanonicalJSON.fnv1a64Hex(""), "cbf29ce484222325")
        XCTAssertEqual(ControlCanonicalJSON.fnv1a64Hex("a"), "af63dc4c8601ec8c")
        XCTAssertEqual(ControlCanonicalJSON.serialize(.double(1e21)), "1e+21")
        XCTAssertEqual(ControlCanonicalJSON.serialize(.double(-0.0)), "0")
        XCTAssertEqual(ControlCanonicalJSON.serialize(.string("\u{01}\n")), #""\u0001\n""#)
    }
    func testConvenienceInitAndResetUseDerivedRevisionAndValidationOrderIsMappingBeforeEpoch() throws {
        var s = try session()
        XCTAssertEqual(s.expected.mapping_revision, holdProfile().mappingRevision)
        let old = s.expected
        try s.reset(expected: old, expectedSequence: "0", epoch: "e2", at: 1)
        XCTAssertEqual(s.expected.mapping_revision, old.mapping_revision)
        // Same mapping, new epoch: stale_epoch.
        assertCode("stale_epoch") { try s.validateExpected(old) }
        let changedProfile = holdProfile(maxHold: 3)
        try s.reset(expected: s.expected, expectedSequence: "0", epoch: "e3", profile: changedProfile, at: 2)
        XCTAssertNotEqual(s.expected.mapping_revision, old.mapping_revision)
        // Mapping changed too: stale_mapping wins over stale_epoch.
        assertCode("stale_mapping") { try s.validateExpected(old) }
        // Profile mismatch is still checked before mapping.
        assertCode("unsupported_profile") { try s.validateExpected(.init(instanceID: "I", epoch: "zz", mappingRevision: "zz", profileID: "nope", profileVersion: "1.1")) }
        assertCode("instance_mismatch") { try s.validateExpected(.init(instanceID: "J", epoch: "zz", mappingRevision: "zz", profileID: "nope", profileVersion: "1.1")) }
    }

    // MARK: capabilities
    func testCapabilityVocabularyAndConsistency() throws {
        try holdProfile().validate()
        for bad in [
            ["simulation", "input.button", "input.absolute", "input.hold", "feedback.value", "feedback.indicator", "stable_control_ids"],
            ["simulation", "input.button", "input.absolute", "input.hold", "feedback.value", "feedback.indicator", "x.host"],
            ["simulation", "input.button", "input.absolute", "input.hold", "feedback.value", "feedback.indicator", "x..name"],
            ["input.absolute", "input.hold", "feedback.value", "feedback.indicator"],           // missing input.button
            ["input.button", "input.absolute", "input.hold", "feedback.value"],                 // missing feedback.indicator
            ["input.button", "input.absolute", "feedback.value", "feedback.indicator"]          // hold controls without input.hold
        ] {
            assertCode("invalid_profile") { try holdProfile(capabilities: bad).validate() }
        }
        // Declaring input.hold without any hold control is inconsistent.
        let noHold = ControlProfile(id: "p", version: "1", controls: [.init(id: "b", inputKind: .button, encoding: .boolean)],
                                    capabilities: ["input.button", "input.hold"])
        assertCode("invalid_profile") { try noHold.validate() }
        // Pre-1.1 host capability strings now fail validation (intentional; hosts adopt the vocabulary in P2).
        let legacy = ControlProfile(id: "p", version: "1", controls: [.init(id: "b", inputKind: .button, encoding: .boolean)],
                                    capabilities: ["simulation", "button_input"])
        assertCode("invalid_profile") { try legacy.validate() }
        try ControlProfile(id: "p", version: "1", controls: [.init(id: "b", inputKind: .button, encoding: .boolean)],
                           capabilities: ["input.button", "x.bcr.indicator_blink_as_on"]).validate()
    }
    func testHoldDescriptorValidation() {
        for hold in [ControlHold(restValue: .bool(false), maxHoldSeconds: 0), .init(restValue: .bool(false), maxHoldSeconds: 10.5),
                     .init(restValue: .bool(false), maxHoldSeconds: .infinity), .init(restValue: .number(0), maxHoldSeconds: 1)] {
            let p = ControlProfile(id: "p", version: "1", controls: [.init(id: "b", inputKind: .button, encoding: .boolean, hold: hold)],
                                   capabilities: ["input.button", "input.hold"])
            assertCode("invalid_profile") { try p.validate() }
        }
        let outOfRange = ControlProfile(id: "p", version: "1", controls: [.init(id: "a", inputKind: .absolute, encoding: .scalar,
            range: .init(minimum: 0, maximum: 10, step: 1), hold: .init(restValue: .number(11), maxHoldSeconds: 1))], capabilities: ["input.absolute", "input.hold"])
        assertCode("invalid_profile") { try outOfRange.validate() }
        let relative = ControlProfile(id: "p", version: "1", controls: [.init(id: "r", inputKind: .relative, encoding: .signedDelta,
            range: .init(minimum: -1, maximum: 1, step: 1), hold: .init(restValue: .number(0), maxHoldSeconds: 1))], capabilities: ["input.relative", "input.hold"])
        assertCode("invalid_profile") { try relative.validate() }
    }

    // MARK: numeric normalization
    func testNumericNormalizationAndIsUnchanged() throws {
        var s = try session()
        try s.seedInputs(["plain": .double(80), "axis": .number(0)], at: 0)
        XCTAssertEqual(try s.snapshot(at: 0).inputs["plain"], .number(80))
        XCTAssertTrue(s.isUnchanged(input(s, "plain", .number(80))))
        XCTAssertTrue(s.isUnchanged(input(s, "plain", .double(80))))
        XCTAssertFalse(s.isUnchanged(input(s, "plain", .number(81))))
        XCTAssertFalse(s.isUnchanged(input(s, "deadman", .bool(false)))) // unknown (unseeded) is not unchanged
        let event = try s.recordInput(input(s, "plain", .double(81)), disposition: .accepted, mappedValue: .double(2), origin: .remote, at: 1)
        XCTAssertEqual(event.value, .number(81)); XCTAssertEqual(event.mapped_value, .number(2))
        // Off-grid values are still rejected, never rounded into an integer.
        assertCode("invalid_value") { try s.recordInput(self.input(s, "plain", .double(81.5)), disposition: .ignored, reason: "off_grid", origin: .remote, at: 1) }
        XCTAssertEqual(SurfaceControlSession.normalized(.double(81.5)), .double(81.5))
        XCTAssertEqual(SurfaceControlSession.normalized(.double(1e300)), .double(1e300))
    }
    func testIsUnchangedConsidersLeases() throws {
        var s = try session()
        try s.seedInputs(["axis": .number(0)], at: 0)
        XCTAssertTrue(s.isUnchanged(input(s, "axis", .number(0), hold: 1)))   // rest value with hold_s acquires nothing
        try s.recordInput(input(s, "axis", .number(50), hold: 1), disposition: .accepted, origin: .remote, at: 0)
        XCTAssertFalse(s.isUnchanged(input(s, "axis", .number(50))))          // would clear the lease
        XCTAssertFalse(s.isUnchanged(input(s, "axis", .number(50), hold: 1))) // would refresh the lease
    }

    // MARK: hold
    func testHoldAcquireRenewExpireAndRecord() throws {
        var s = try session()
        try s.seedInputs(["deadman": .bool(false)], at: 0)
        let acquired = try s.recordInput(input(s, "deadman", .bool(true), hold: 1), disposition: .accepted, origin: .remote, at: 1)
        XCTAssertEqual(acquired.hold_deadline, 2)
        XCTAssertEqual(try s.snapshot(at: 1.5).holds, ["deadman": 2])
        XCTAssertEqual(s.nextHoldDeadline, 2)
        let renewed = try s.renew(.init(expected: s.expected, controlID: "deadman", holdSeconds: 1), at: 1.5)
        XCTAssertEqual(renewed, .init(control_id: "deadman", hold_deadline: 2.5, server_time: 1.5))
        XCTAssertEqual(s.discovery().latest_sequence, "1")    // renew consumes no sequence
        XCTAssertEqual(try s.events(instanceID: "I", epoch: "e1", afterSequence: "0", at: 1.5).events.count, 1)
        XCTAssertTrue(s.dueHoldExpiries(at: 2.4).isEmpty)
        let due = s.dueHoldExpiries(at: 2.5)
        XCTAssertEqual(due, [.init(controlID: "deadman", restValue: .bool(false), deadline: 2.5)])
        // Every read and write at t >= deadline fails closed until processed.
        assertCode("hold_expiry_pending") { _ = try s.snapshot(at: 2.5) }
        assertCode("hold_expiry_pending") { _ = try s.events(instanceID: "I", epoch: "e1", afterSequence: "0", at: 3) }
        assertCode("hold_expiry_pending") { try s.recordInput(self.input(s, "plain", .number(1)), disposition: .accepted, origin: .remote, at: 3) }
        assertCode("hold_expiry_pending") { try s.recordFeedback(.init(expected: s.expected, expectedSequence: "1", controlID: "deadman", kind: "indicator", value: .string("on")), origin: .remote, at: 3) }
        assertCode("hold_expiry_pending") { _ = try s.renew(.init(expected: s.expected, controlID: "deadman", holdSeconds: 1), at: 3) }
        assertCode("hold_expiry_pending") { try s.reset(expected: s.expected, expectedSequence: "1", epoch: "e2", at: 3) }
        // Reads before the deadline still succeed.
        XCTAssertEqual(try s.snapshot(at: 2.4).latest_sequence, "1")
        let expiry = try s.recordHoldExpiry(controlID: "deadman", mappedValue: .bool(false), at: 3)
        XCTAssertEqual(expiry.kind, .input); XCTAssertEqual(expiry.disposition, .accepted); XCTAssertEqual(expiry.origin, .remote)
        XCTAssertEqual(expiry.reason, "hold_expired"); XCTAssertEqual(expiry.value, .bool(false)); XCTAssertNil(expiry.hold_deadline)
        let snapshot = try s.snapshot(at: 3)
        XCTAssertEqual(snapshot.inputs["deadman"], .bool(false)); XCTAssertNil(snapshot.holds)
        // Renewal after expiry is rejected.
        assertCode("hold_expired") { _ = try s.renew(.init(expected: s.expected, controlID: "deadman", holdSeconds: 1), at: 3) }
        assertCode("invalid_transition") { try s.recordHoldExpiry(controlID: "deadman", at: 3) }
    }
    func testRestInputClearsHoldAndPlainInputReplacesIt() throws {
        var s = try session()
        try s.recordInput(input(s, "axis", .number(40), hold: 2), disposition: .accepted, origin: .remote, at: 0)
        let rest = try s.recordInput(input(s, "axis", .number(0), hold: 2), disposition: .accepted, origin: .remote, at: 1)
        XCTAssertNil(rest.hold_deadline); XCTAssertNil(try s.snapshot(at: 5).holds)
        try s.recordInput(input(s, "axis", .number(40), hold: 2), disposition: .accepted, origin: .remote, at: 6)
        try s.recordInput(input(s, "axis", .number(30)), disposition: .accepted, origin: .remote, at: 7) // accepted without hold_s
        XCTAssertNil(try s.snapshot(at: 100).holds)
        // Ignored input leaves an existing lease intact.
        try s.recordInput(input(s, "axis", .number(40), hold: 2), disposition: .accepted, origin: .remote, at: 101)
        try s.recordInput(input(s, "axis", .number(50)), disposition: .ignored, reason: "inactive_layer", origin: .remote, at: 102)
        XCTAssertEqual(try s.snapshot(at: 102).holds, ["axis": 103])
    }
    func testHoldValidationErrorsAndResetClears() throws {
        var s = try session()
        let before = try s.snapshot(at: 0)
        assertCode("unsupported_hold") { try s.recordInput(self.input(s, "plain", .number(1), hold: 1), disposition: .accepted, origin: .remote, at: 0) }
        for bad in [0, -1, 2.5, Double.nan, .infinity] {
            assertCode("invalid_argument") { try s.recordInput(self.input(s, "deadman", .bool(true), hold: bad), disposition: .accepted, origin: .remote, at: 0) }
        }
        XCTAssertEqual(try s.snapshot(at: 0), before)
        assertCode("hold_expired") { _ = try s.renew(.init(expected: s.expected, controlID: "deadman", holdSeconds: 1), at: 0) }
        assertCode("unsupported_hold") { _ = try s.renew(.init(expected: s.expected, controlID: "plain", holdSeconds: 1), at: 0) }
        assertCode("unsupported_control") { _ = try s.renew(.init(expected: s.expected, controlID: "missing", holdSeconds: 1), at: 0) }
        try s.recordInput(input(s, "deadman", .bool(true), hold: 2), disposition: .accepted, origin: .remote, at: 1)
        assertCode("stale_epoch") { _ = try s.renew(.init(expected: .init(instanceID: "I", epoch: "old", mappingRevision: s.expected.mapping_revision, profileID: "fixture.hold", profileVersion: "1.1"), controlID: "deadman", holdSeconds: 1), at: 1) }
        assertCode("invalid_time") { _ = try s.renew(.init(expected: s.expected, controlID: "deadman", holdSeconds: 1), at: 0.5) }
        try s.reset(expected: s.expected, expectedSequence: "1", epoch: "e2", at: 2)
        XCTAssertNil(try s.snapshot(at: 10).holds)
        XCTAssertTrue(s.dueHoldExpiries(at: 10).isEmpty)
        assertCode("hold_expired") { _ = try s.renew(.init(expected: s.expected, controlID: "deadman", holdSeconds: 1), at: 2) }
    }
    func testMultipleDueExpiriesAreOrderedByDeadline() throws {
        var s = try session()
        try s.recordInput(input(s, "axis", .number(10), hold: 2), disposition: .accepted, origin: .remote, at: 0)
        try s.recordInput(input(s, "deadman", .bool(true), hold: 1), disposition: .accepted, origin: .remote, at: 0.5)
        XCTAssertEqual(s.dueHoldExpiries(at: 3).map(\.controlID), ["deadman", "axis"])
        try s.recordHoldExpiry(controlID: "deadman", at: 3)
        assertCode("hold_expiry_pending") { _ = try s.snapshot(at: 3) }
        try s.recordHoldExpiry(controlID: "axis", mappedValue: .number(0), at: 3)
        XCTAssertEqual(try s.snapshot(at: 3).inputs, ["deadman": .bool(false), "axis": .number(0)])
    }

    // MARK: tools
    func testToolParsingAcceptsLegacyAndHoldRequestsAndRenew() throws {
        let s = try session()
        let legacy = try JSONValue.encoded(input(s, "deadman", .bool(true)))
        XCTAssertNil(legacy.objectValue?["hold_s"])
        guard case .input(let plain) = try SurfaceControlTools.parse("surface_control_input", arguments: legacy) else { return XCTFail() }
        XCTAssertNil(plain.hold_s)
        guard case .input(let held) = try SurfaceControlTools.parse("surface_control_input", arguments: try .encoded(input(s, "deadman", .bool(true), hold: 1.5))) else { return XCTFail() }
        XCTAssertEqual(held.hold_s, 1.5)
        let renew: JSONValue = .object(["expected": try .encoded(s.expected), "control_id": .string("deadman"), "hold_s": .number(1)])
        guard case .renew(let request) = try SurfaceControlTools.parse("surface_control_renew", arguments: renew) else { return XCTFail() }
        XCTAssertEqual(request, .init(expected: s.expected, controlID: "deadman", holdSeconds: 1))
        var extra = renew.objectValue!; extra["expected_sequence"] = .string("0")
        assertCode("invalid_argument") { _ = try SurfaceControlTools.parse("surface_control_renew", arguments: .object(extra)) }
        var missing = renew.objectValue!; missing["hold_s"] = nil
        assertCode("invalid_argument") { _ = try SurfaceControlTools.parse("surface_control_renew", arguments: .object(missing)) }
        var bad = legacy.objectValue!; bad["hold_s"] = .string("1")
        assertCode("invalid_argument") { _ = try SurfaceControlTools.parse("surface_control_input", arguments: .object(bad)) }
        var noValue = legacy.objectValue!; noValue["value"] = nil
        assertCode("invalid_argument") { _ = try SurfaceControlTools.parse("surface_control_input", arguments: .object(noValue)) }
        XCTAssertEqual(SurfaceControlTools.descriptors.first { $0.name == "surface_control_renew" }?.isMutation, true)
    }
    func testLegacyEncodingOmitsOptionalFields() throws {
        var s = try session()
        let event = try s.recordInput(input(s, "plain", .number(1)), disposition: .accepted, origin: .remote, at: 0)
        XCTAssertNil(try JSONValue.encoded(event).objectValue?["hold_deadline"])
        XCTAssertNil(try JSONValue.encoded(s.snapshot(at: 0)).objectValue?["holds"])
        XCTAssertNil(try JSONValue.encoded(s.profile.controls[2]).objectValue?["hold"])
    }
}
