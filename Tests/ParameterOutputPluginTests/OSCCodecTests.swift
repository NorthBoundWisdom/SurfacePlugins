import Foundation
import XCTest
import SurfacePluginContracts
import ParameterOutputPlugin

final class OSCCodecTests: XCTestCase {
    func testFloatMessageMatchesBigEndianAlignedWireBytes() throws {
        let packet = OSCPacket.message(OSCMessage("/x", [.float(1)]))
        let data = try OSCCodec.encode(packet)
        XCTAssertEqual(Array(data), [47, 120, 0, 0, 44, 102, 0, 0, 63, 128, 0, 0])
        XCTAssertEqual(try OSCCodec.decode(data), packet)
    }

    func testIntegerStringAndNestedBundleRoundTrip() throws {
        let packet = OSCPacket.bundle(timetag: 1, elements: [
            .message(OSCMessage("/heartbeat", [.int(-1)])),
            .bundle(timetag: 1, elements: [.message(OSCMessage("/value", [.float(-3.5), .string("text")]))])
        ])
        XCTAssertEqual(try OSCCodec.decode(OSCCodec.encode(packet)), packet)
        XCTAssertEqual(try OSCCodec.immediateMessages(packet).count, 2)
        XCTAssertThrowsError(try OSCCodec.immediateMessages(.bundle(timetag: 2, elements: [])))
    }

    func testParameterIDsUseAnUnambiguousASCIIPathComponent() throws {
        for id in ["arm.j1", "custom /含空格%"] {
            let encoded = OSCCodec.parameterAddress(ParameterID(rawValue: id), prefix: "/bcr/state/")
            XCTAssertTrue(encoded.utf8.allSatisfy { $0 < 128 })
            XCTAssertEqual(try OSCCodec.parameterID(encoded, prefix: "/bcr/state/"), ParameterID(rawValue: id))
        }
        XCTAssertThrowsError(try OSCCodec.parameterID("/other/x", prefix: "/bcr/state/"))
        XCTAssertThrowsError(try OSCCodec.parameterID("/bcr/state/%ZZ", prefix: "/bcr/state/"))
    }

    func testMalformedPaddingTruncationTypesAndNonfiniteNumbersAreRejected() throws {
        let good = try OSCCodec.encode(.message(OSCMessage("/x", [.float(1)])))
        XCTAssertThrowsError(try OSCCodec.decode(good.dropLast()))
        var badPadding = good
        badPadding[3] = 1
        XCTAssertThrowsError(try OSCCodec.decode(badPadding))
        var badType = good
        badType[5] = 113
        XCTAssertThrowsError(try OSCCodec.decode(badType))
        var nan = good
        nan.replaceSubrange(8 ..< 12, with: [0x7f, 0xc0, 0, 0])
        XCTAssertThrowsError(try OSCCodec.decode(nan))
        XCTAssertThrowsError(try OSCCodec.encode(.message(OSCMessage("/x", [.float(.infinity)]))))
        XCTAssertThrowsError(try OSCCodec.encode(.message(OSCMessage("invalid", []))))
        XCTAssertThrowsError(try OSCCodec.encode(.message(OSCMessage("/x", [.string("bad\u{0}text")]))))
        XCTAssertThrowsError(try OSCCodec.decode(Data(repeating: 0, count: 4)))
    }

    func testBundleLengthAndNestingAreBounded() throws {
        var packet = OSCPacket.message(OSCMessage("/x", [.int(1)]))
        for _ in 0 ..< 10 { packet = .bundle(timetag: 1, elements: [packet]) }
        XCTAssertThrowsError(try OSCCodec.encode(packet))
        var encoded = try OSCCodec.encode(.bundle(timetag: 1, elements: [.message(OSCMessage("/x", [.int(1)]))]))
        encoded.replaceSubrange(16 ..< 20, with: [0x7f, 0xff, 0xff, 0xff])
        XCTAssertThrowsError(try OSCCodec.decode(encoded))
    }

}
