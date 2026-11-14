import Foundation
import XCTest
import SurfacePluginContracts
@testable import SurfaceControlContracts

/// A reference harness for trusted host adapters. No device I/O or remote injection.
final class IndependentHardwareFixtureTests: XCTestCase {
    private let roles = ["button_accepted": "button", "button_ignored": "ignored", "input_a": "axis",
                         "touch_input": "touch", "feedback_progress": "ring", "input_only": "press"]
    private func profile() -> ControlProfile {
        .init(id: "fixture.independent.hardware", version: "1.4", controls: [
            .init(id: "axis", inputKind: .absolute, encoding: .scalar, range: .init(minimum: 0, maximum: 127, step: 1), acceptsInput: false),
            .init(id: "button", inputKind: .button, encoding: .boolean, acceptsInput: false),
            .init(id: "ignored", inputKind: .button, encoding: .boolean, acceptsInput: false),
            .init(id: "touch", inputKind: .button, encoding: .boolean, acceptsInput: false),
            .init(id: "ring", inputKind: .absolute, encoding: .scalar, range: .init(minimum: 0, maximum: 127, step: 1), feedbackRange: .init(minimum: 0, maximum: 28, step: 1), feedbackKinds: [.value], acceptsInput: false),
            .init(id: "press", inputKind: .button, encoding: .boolean, acceptsInput: false)
        ], capabilities: ["hardware", "controls.input_declared", "input.absolute", "input.button", "feedback.value"])
    }
    private func fixture() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixtures/surface-control-hardware-independent-v1.4.json"))) as! [String: Any]
    }
    private func value(_ symbolic: String?, control: ControlDescriptor, feedback: Bool = false) -> JSONValue {
        if symbolic == "on" || symbolic == "off" || symbolic == "blink" { return .string(symbolic!) }
        if control.encoding == .boolean { return .bool(symbolic == "maximum") }
        let range = feedback ? control.feedback_range ?? control.range! : control.range!
        return .double(symbolic == "maximum" ? range.maximum : range.minimum)
    }
    func testIndependentFixtureExecutesEveryExpectationWithoutRelativeControls() throws {
        let profile = profile()
        XCTAssertFalse(profile.capabilities.contains("input.relative"))
        var counts: [String: Int] = [:]
        for scene in try fixture()["scenarios"] as! [[String: Any]] {
            let id = scene["id"] as! String
            let required = scene["required_roles"] as! [String]
            XCTAssertTrue(required.allSatisfy { roles[$0] != nil })
            var session = try SurfaceControlSession(instanceID: "independent", epoch: "initial", profile: profile, eventCapacity: scene["event_capacity"] as! Int)
            try session.transitionHardware(epoch: "connected", linkState: .connected, at: 0)
            let initial = session.expected
            counts[id] = 0
            for (index, step) in (scene["steps"] as! [[String: Any]]).enumerated() {
                counts[id]! += 1
                let time = step["at_s"] as! Double, operation = step["operation"] as! String, expect = step["expect"] as! [String: Any]
                let before = try session.snapshot(at: time)
                let beforePage = try session.events(instanceID: "independent", epoch: session.expected.epoch, afterSequence: "0", at: time)
                let control = (step["role"] as? String).flatMap { roles[$0] }.flatMap { id in profile.controls.first { $0.id == id } }
                var event: ControlEvent?, page: ControlEventPage?, error: String?
                do {
                    switch operation {
                    case "snapshot": break
                    case "hardware_input":
                        let row = control!
                        let input = ControlHardwareInput(expected: session.expected, controlID: row.id, encoding: row.encoding.rawValue, value: value(step["value"] as? String, control: row))
                        try session.validateHardwareInput(input, at: time)
                        var candidate = session
                        event = try candidate.recordHardwareInput(input, disposition: ControlDisposition(rawValue: step["disposition"] as? String ?? "accepted")!, reason: step["reason"] as? String, at: time)
                        session = candidate
                    case "hardware_link": try session.transitionHardware(epoch: "new-\(index)", linkState: ControlLink.State(rawValue: step["link_state"] as! String)!, at: time)
                    case "feedback", "feedback_failure":
                        let row = control!, kind = step["feedback_kind"] as! String
                        let raw: JSONValue = step["invalid_value"] as? String == "nan" ? .double(.nan) : value(step["value"] as? String, control: row, feedback: true)
                        let request = ControlFeedback(expected: session.expected, expectedSequence: session.discovery().latest_sequence, controlID: row.id, kind: kind, value: raw)
                        var candidate = session
                        try candidate.validateFeedback(request, at: time)
                        // Model a failed trusted display transport between preflight and commit.
                        // Host runners must inject failure in their own fake display adapter.
                        if operation == "feedback_failure" { throw ControlContractError("test_transport_rejected") }
                        event = try candidate.recordFeedback(request, origin: .remote, at: time)
                        session = candidate
                    case "input":
                        let row = control!
                        try session.validateInput(.init(expected: session.expected, expectedSequence: session.discovery().latest_sequence, controlID: row.id, encoding: row.encoding.rawValue, value: value(step["value"] as? String, control: row)), at: time)
                    case "renew": try session.validateRenew(.init(expected: session.expected, controlID: control!.id, holdSeconds: step["hold_s"] as! Double), at: time)
                    case "reset": try session.reset(expected: session.expected, expectedSequence: session.discovery().latest_sequence, epoch: "forbidden", at: time)
                    case "events": page = try session.events(instanceID: "independent", epoch: step["expected_scope"] as? String == "initial" ? initial.epoch : session.expected.epoch, afterSequence: step["after_sequence"] as? String ?? "0", at: time)
                    default: XCTFail("unsupported fixture operation \(operation)")
                    }
                } catch let failure as ControlContractError { error = failure.code }
                XCTAssertEqual(error, expect["error"] as? String, "\(id) step \(index)")
                let after = try session.snapshot(at: time)
                for (key, expected) in expect {
                    switch key {
                    case "error": break
                    case "atomic":
                        XCTAssertEqual(before, after)
                        XCTAssertEqual(beforePage, try session.events(instanceID: "independent", epoch: session.expected.epoch, afterSequence: "0", at: time))
                    case "unknown_inputs": for role in expected as! [String] { XCTAssertNil(after.inputs[roles[role]!]) }
                    case "known_inputs": for (role, symbolic) in expected as! [String: String] {
                        let row = profile.controls.first { $0.id == roles[role]! }!
                        XCTAssertEqual(after.inputs[row.id], SurfaceControlSession.normalized(value(symbolic, control: row)))
                    }
                    case "sequence": XCTAssertEqual(session.discovery().latest_sequence, expected as? String)
                    case "link_state": XCTAssertEqual(after.link?.state.rawValue, expected as? String)
                    case "disposition": XCTAssertEqual(event?.disposition.rawValue, expected as? String)
                    case "source": XCTAssertEqual(event?.source.rawValue, expected as? String)
                    case "origin": XCTAssertEqual(event?.origin.rawValue, expected as? String)
                    case "inputs_unchanged": XCTAssertEqual(before.inputs, after.inputs)
                    case "epoch_changed": XCTAssertNotEqual(before.discovery.expected.epoch, after.discovery.expected.epoch)
                    case "event_count": XCTAssertEqual(page?.events.count, expected as? Int)
                    default: XCTFail("unchecked fixture expectation \(key)")
                    }
                }
            }
        }
        XCTAssertEqual(counts, ["accepted_button_edges_and_recovery": 12, "ignored_button_edges_remain_unknown": 4,
                                "position_touch_independent_edges": 8, "value_feedback_failures_are_atomic": 8])
    }
}
