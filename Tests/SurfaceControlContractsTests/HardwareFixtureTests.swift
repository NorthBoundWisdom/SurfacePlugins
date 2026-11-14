import Foundation
import XCTest
import SurfacePluginContracts
@testable import SurfaceControlContracts

final class HardwareFixtureTests: XCTestCase {
    func testSharedHardwareFixtureWithTrustedObservations() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixtures/surface-control-hardware-v1.4.json"))) as! [String: Any]
        let profile = ControlProfile(id: "fixture.hardware", version: "1.4", controls: [
            .init(id: "axis", inputKind: .absolute, encoding: .scalar, range: .init(minimum: 0, maximum: 127, step: 1), acceptsInput: false),
            .init(id: "delta", inputKind: .relative, encoding: .signedDelta, range: .init(minimum: -8, maximum: 8, step: 1), acceptsInput: false),
            .init(id: "button", inputKind: .button, encoding: .boolean, acceptsInput: false),
            .init(id: "touch", inputKind: .button, encoding: .boolean, acceptsInput: false),
            .init(id: "lamp", inputKind: .button, encoding: .boolean, feedbackKinds: [.indicator], acceptsInput: false),
            .init(id: "ring", inputKind: .absolute, encoding: .scalar, range: .init(minimum: 0, maximum: 127, step: 1), feedbackKinds: [.value], acceptsInput: false)
        ], capabilities: ["hardware", "controls.input_declared", "input.absolute", "input.relative", "input.button", "feedback.value", "feedback.indicator"])
        let roles = ["input_a": "axis", "relative_input": "delta", "button_input": "button", "touch_input": "touch", "feedback_state": "lamp", "feedback_progress": "ring"]
        var count = 0
        for scene in document["scenarios"] as! [[String: Any]] {
            var session = try SurfaceControlSession(instanceID: "fixture", epoch: "initial", profile: profile, eventCapacity: scene["event_capacity"] as! Int)
            try session.transitionHardware(epoch: "connected", linkState: .connected, at: 0)
            let initial = session.expected
            for (index, step) in (scene["steps"] as! [[String: Any]]).enumerated() {
                count += 1
                let time = step["at_s"] as! Double, operation = step["operation"] as! String, expect = step["expect"] as! [String: Any]
                let before = try session.snapshot(at: time)
                let control = (step["role"] as? String).flatMap { roles[$0] }.flatMap { id in profile.controls.first { $0.id == id } }
                let symbolic = step["value"] as? String
                let value: JSONValue = control.map { row in
                    if row.encoding == .boolean { return .bool(symbolic == "maximum") }
                    let range = row.feedback_range ?? row.range!
                    return .double(symbolic == "maximum" ? range.maximum : range.minimum)
                } ?? .null
                var event: ControlEvent?, page: ControlEventPage?, error: String?
                do {
                    switch operation {
                    case "snapshot": break
                    case "hardware_input":
                        let row = control!
                        let input = ControlHardwareInput(expected: session.expected, controlID: row.id, encoding: row.encoding.rawValue, value: value)
                        try session.validateHardwareInput(input, at: time)
                        event = try session.recordHardwareInput(input, disposition: ControlDisposition(rawValue: step["disposition"] as? String ?? "accepted")!, reason: step["reason"] as? String, at: time)
                    case "hardware_link": try session.transitionHardware(epoch: "transition-\(index)", linkState: ControlLink.State(rawValue: step["link_state"] as! String)!, at: time)
                    case "feedback":
                        let row = control!, kind = row.feedback_kinds[0]
                        event = try session.recordFeedback(.init(expected: session.expected, expectedSequence: session.discovery().latest_sequence, controlID: row.id, kind: kind.rawValue, value: kind == .indicator ? .string(symbolic!) : value), origin: .remote, at: time)
                    case "input":
                        let row = control!
                        try session.validateInput(.init(expected: session.expected, expectedSequence: session.discovery().latest_sequence, controlID: row.id, encoding: row.encoding.rawValue, value: value), at: time)
                    case "renew": try session.validateRenew(.init(expected: session.expected, controlID: control!.id, holdSeconds: step["hold_s"] as! Double), at: time)
                    case "reset": try session.reset(expected: session.expected, expectedSequence: session.discovery().latest_sequence, epoch: "forbidden", at: time)
                    case "events": page = try session.events(instanceID: "fixture", epoch: step["expected_scope"] as? String == "initial" ? initial.epoch : session.expected.epoch, afterSequence: step["after_sequence"] as? String ?? "0", at: time)
                    default: XCTFail("unsupported fixture operation \(operation)")
                    }
                } catch let failure as ControlContractError { error = failure.code }
                XCTAssertEqual(error, expect["error"] as? String, "\(scene["id"]!) step \(index)")
                let after = try session.snapshot(at: time)
                for (key, expected) in expect {
                    switch key {
                    case "error": break
                    case "atomic": XCTAssertEqual(before, after)
                    case "unknown_inputs": for role in expected as! [String] { XCTAssertNil(after.inputs[roles[role]!]) }
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
        XCTAssertEqual(count, 32)
    }
}
