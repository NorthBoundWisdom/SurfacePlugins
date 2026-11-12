import Foundation
import XCTest
import SurfacePluginContracts

final class ParameterTests: XCTestCase {
    func definition(min: Double = -2, max: Double = 3, step: Double? = nil, kind: ParameterKind = .continuous) throws -> ParameterDefinition {
        try .init(id: "test.value", nameKey: "test.value", minimum: min, maximum: max, defaultValue: 0, kind: kind, step: step)
    }
    func testContinuousClampAndNormalize() throws {
        let d = try definition()
        XCTAssertEqual(try d.clamp(-99), -2); XCTAssertEqual(try d.clamp(99), 3)
        XCTAssertEqual(try d.normalized(-2), 0); XCTAssertEqual(try d.normalized(3), 1)
        XCTAssertEqual(try d.clamp(0.234), 0.234)
    }
    func testZeroAnchoredGridIncludesEndpointsAndLowerTies() throws {
        let d = try definition(min: -1.3, max: 2.3, step: 1)
        for (input, output) in [(-9.0,-1.3),(-1.2,-1.3),(-0.5,-1),(0.5,0),(1.5,1),(2.2,2.3),(9,2.3)] {
            XCTAssertEqual(try d.clamp(input), output, accuracy: 1e-12)
        }
        let positive = try definition(min: 1.2, max: 4.2, step: 1)
        XCTAssertEqual(try positive.clamp(1.6), 2); XCTAssertEqual(try positive.clamp(1.2), 1.2)
    }
    func testToggleMidpoint() throws {
        let d = try definition(kind: .toggle)
        XCTAssertEqual(try d.clamp(0.499), -2); XCTAssertEqual(try d.clamp(0.5), 3)
    }
    func testNonfiniteAndUnrepresentableStep() throws {
        for v in [Double.nan, .infinity, -.infinity] { XCTAssertThrowsError(try definition().clamp(v)) }
        for s in [0.0,-1,.nan,.infinity,Double.leastNonzeroMagnitude] { XCTAssertThrowsError(try definition(step: s)) }
        XCTAssertThrowsError(try definition(min: -.greatestFiniteMagnitude, max: .greatestFiniteMagnitude))
        XCTAssertNoThrow(try definition(step: .greatestFiniteMagnitude).clamp(0))
    }
    func testStringIdentifierAndValidatedDecoding() throws {
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(ParameterID(rawValue: "old.value")), as: UTF8.self), "\"old.value\"")
        let original = try definition(step: 0.5)
        let bytes = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(ParameterDefinition.self, from: bytes), original)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for (key, value) in [("step", 0.0), ("maximum", -3.0)] {
            var invalid = json; invalid[key] = value
            XCTAssertThrowsError(try JSONDecoder().decode(ParameterDefinition.self, from: JSONSerialization.data(withJSONObject: invalid)))
        }
        json.removeValue(forKey: "defaultValue")
        XCTAssertThrowsError(try JSONDecoder().decode(ParameterDefinition.self, from: JSONSerialization.data(withJSONObject: json)))
    }
}

final class ReviewContractTests: XCTestCase {
    func testLegacyRoundedAndNewExactIntegerSemantics() {
        XCTAssertEqual(JSONValue.double(1.6).intValue, 2)
        XCTAssertEqual(JSONValue.double(-1.5).roundedIntValue, -2)
        XCTAssertNil(JSONValue.double(1.6).exactIntValue)
        for value in [Int.min, 9_007_199_254_740_993, Int.max] {
            XCTAssertEqual(JSONValue.number(value).exactIntValue, value)
            XCTAssertEqual(JSONValue.number(value).roundedIntValue, value)
        }
        XCTAssertEqual(JSONValue.double(2).exactIntValue, 2)
        XCTAssertNil(JSONValue.double(.nan).exactIntValue)
        XCTAssertNil(JSONValue.double(.infinity).exactIntValue)
    }
    func testLegacyOutOfRangeDefaultsRemainDecodableAndHostCanonicalizes() throws {
        let definition = try ParameterDefinition(id: "positive.value", nameKey: "positive.value", minimum: 10, maximum: 20, defaultValue: 0, step: 2)
        let decoded = try JSONDecoder().decode(ParameterDefinition.self, from: JSONEncoder().encode(definition))
        XCTAssertEqual(decoded.defaultValue, 0)
        XCTAssertEqual(try decoded.clamp(decoded.defaultValue), 10)
        let upper = try ParameterDefinition(id: "positive.value", nameKey: "positive.value", minimum: 10, maximum: 20, defaultValue: 999)
        XCTAssertEqual(try upper.clamp(upper.defaultValue), 20)
    }
}
