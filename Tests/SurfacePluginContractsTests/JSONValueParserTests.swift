import Foundation
@testable import SurfacePluginContracts
import XCTest

final class JSONValueParserTests: XCTestCase {
    private func reference(_ text: String) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// The fast reader must classify every literal exactly like JSONDecoder + JSONValue.init(from:).
    func testLiteralsMatchJSONDecoder() {
        let literals = [
            "0", "-0", "5", "-5", "5.0", "-5.0", "5.5", "0.1", "1e2", "1E+2", "1e-05", "1.5e1", "2.5e0",
            "1e20", "-1e20", "9223372036854775807", "-9223372036854775808", "9223372036854775808",
            "-9223372036854775809", "123456789012345678901234567890", "9007199254740993", "9007199254740993.0",
            "0.30000000000000004", "1.7976931348623157e308", "4.9e-324", "true", "false", "null",
            #""""#, #""a\"b\\c\/d\b\f\n\r\t""#, #""\u00e9\ud83d\ude00é😀""#, #""\u0000\u001f""#,
            "[]", "{}", " [ 1 , 2.5 , \"x\" , [ ] , { } ] ", #"{"a":{"b":[null,true,{"c":-0.0}]},"d":"e"}"#
        ]
        for text in literals {
            XCTAssertEqual(JSONValueParser.parse(Data(text.utf8)), reference(text), text)
        }
    }

    func testMalformedOrAmbiguousInputIsRefusedForTheFallback() {
        for text in ["", "01", "1.", ".5", "1e", "-", "+1", "tru", "[1,]", "{\"a\":1,}", "{\"a\":1,\"a\":2}",
                     "\"\\x\"", "\"\\ud83d\"", "\"unterminated", "[1] 2", "NaN", "1e400"]
        {
            XCTAssertNil(JSONValueParser.parse(Data(text.utf8)), text)
        }
    }

    /// `encoded` keeps JSONEncoder's own encoding rules (dates, data, URLs, nesting) unchanged.
    func testEncodedMatchesTheJSONDecoderRoundTrip() throws {
        struct Sample: Encodable {
            let date = Date(timeIntervalSinceReferenceDate: 12.5)
            let data = Data([0, 1, 2, 250])
            let url = URL(string: "https://example.invalid/a b?x=1")
            let numbers: [Double] = [1, 0.5, -0.0, 1e-05, 1e20, 100]
            let integers: [Int] = [.min, -1, 0, .max]
            let text = "slash/quote\"tab\tunicode é😀"
            let nested: [String: [String: Bool?]] = ["a": ["b": true, "c": nil]]
            let optional: Int? = nil
        }
        let data = try JSONEncoder().encode(Sample())
        XCTAssertEqual(try JSONValue.encoded(Sample()), try JSONDecoder().decode(JSONValue.self, from: data))
        var generator = SystemRandomNumberGenerator()
        for _ in 0 ..< 200 {
            let value = randomValue(depth: 0, using: &generator)
            let bytes = try JSONEncoder().encode(value)
            XCTAssertEqual(try JSONValue.encoded(value), try JSONDecoder().decode(JSONValue.self, from: bytes))
        }
    }

    private func randomValue(depth: Int, using generator: inout SystemRandomNumberGenerator) -> JSONValue {
        switch Int.random(in: 0 ..< (depth > 3 ? 5 : 7), using: &generator) {
        case 0: return .null
        case 1: return .bool(Bool.random(using: &generator))
        case 2: return .number(Int.random(in: -1_000_000 ... 1_000_000, using: &generator))
        case 3: return .double(Double.random(in: -1e6 ... 1e6, using: &generator))
        case 4: return .string(String((0 ..< Int.random(in: 0 ... 8, using: &generator)).map { _ in
                "aZ0 \"\\/\né😀".randomElement(using: &generator)!
            }))
        case 5: return .array((0 ..< Int.random(in: 0 ... 4, using: &generator)).map { _ in
                randomValue(depth: depth + 1, using: &generator)
            })
        default:
            var object: [String: JSONValue] = [:]
            for index in 0 ..< Int.random(in: 0 ... 4, using: &generator) {
                object["k\(index)"] = randomValue(depth: depth + 1, using: &generator)
            }
            return .object(object)
        }
    }
}
