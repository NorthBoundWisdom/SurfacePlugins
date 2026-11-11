import Foundation
import XCTest
import SurfacePluginContracts
import ParameterOutputPlugin

final class JSONParameterLinkTests: XCTestCase {
    func testHeartbeatFreshnessSessionAndReplayProtection() throws {
        var link = JSONParameterLink(session: "test")
        let now = 100.0
        let ping = link.ping(at: now)
        let pong: JSONValue = .object(["type": .string("pong"), "session": .string("test"), "epoch": .string("peer"),
                                       "sequence": ping.objectValue!["sequence"]!])
        XCTAssertEqual(try link.receive(pong, at: now), .heartbeat(now, peerReset: false))
        XCTAssertEqual(try link.receive(pong, at: now), .ignored)
        let state: JSONValue = .object(["type": .string("state"), "session": .string("test"), "epoch": .string("peer"),
                                        "sequence": .string("1"), "values": .object(["arm.j1": .double(40)])])
        XCTAssertEqual(try link.receive(state, at: now), .samples([.init(id: "arm.j1", value: 40, receivedAt: now)]))
        XCTAssertEqual(try link.receive(state, at: now), .ignored)
        let next = link.ping(at: now)
        let stale: JSONValue = .object(["type": .string("pong"), "session": .string("test"), "epoch": .string("peer"),
                                        "sequence": next.objectValue!["sequence"]!])
        XCTAssertEqual(try link.receive(stale, at: (now + 1)), .ignored)
    }

    func testOutputRequiresPeerAndStopCannotContainMotionValues() throws {
        var link = JSONParameterLink(session: "test")
        XCTAssertThrowsError(try link.command(.init(enabled: true, values: [:])))
        let now = 100.0
        let ping = link.ping(at: now)
        _ = try link.receive(.object(["type": .string("pong"), "session": .string("test"), "epoch": .string("peer"),
                                      "sequence": ping.objectValue!["sequence"]!]), at: now)
        XCTAssertThrowsError(try link.command(.init(enabled: false, values: ["arm.j1": 40])))
        let command = try link.command(.init(enabled: true, values: ["arm.j1": 40]))
        XCTAssertEqual(command.objectValue?["values"]?.objectValue?["arm.j1"], .double(40))
    }

    func testPeerRestartInvalidatesOldStateEpoch() throws {
        var link = JSONParameterLink(session: "test")
        let now = 100.0
        for (index, epoch) in ["old", "new"].enumerated() {
            let ping = link.ping(at: now)
            XCTAssertEqual(
                try link.receive(.object(["type": .string("pong"), "session": .string("test"), "epoch": .string(epoch),
                                          "sequence": ping.objectValue!["sequence"]!]), at: now),
                .heartbeat(now, peerReset: index == 1)
            )
        }
        XCTAssertEqual(
            try link.receive(.object([
                "type": .string("state"),
                "session": .string("test"),
                "epoch": .string("old"),
                "sequence": .string("999"),
                "values": .object(["arm.j1": .double(40)])
            ]), at: now),
            .ignored
        )
    }
}
