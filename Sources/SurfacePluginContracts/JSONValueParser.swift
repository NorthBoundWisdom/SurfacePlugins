import Foundation

/// Deterministic, non-throwing-by-trial reader for JSON text produced by `JSONEncoder`.
///
/// `JSONValue.init(from:)` must probe each value type in turn, and every failed probe is a
/// thrown error. Test runners hook `swift_willThrow` and record a backtrace per throw, which made
/// `JSONValue.encoded` dominate host test time. This reader classifies each value from its first
/// byte instead, using the same numeric rule as `JSONDecoder` + `JSONValue.init(from:)`: a literal
/// whose value is an exact integer in `Int` range is `.number`, anything else is `.double`.
/// It returns nil on any input it does not fully accept; callers then fall back to `JSONDecoder`.
struct JSONValueParser {
    private let bytes: [UInt8]
    private var index = 0

    static func parse(_ data: Data) -> JSONValue? {
        var parser = JSONValueParser(bytes: [UInt8](data))
        guard let value = parser.value() else { return nil }
        parser.skipWhitespace()
        return parser.index == parser.bytes.count ? value : nil
    }

    private init(bytes: [UInt8]) { self.bytes = bytes }

    private var current: UInt8? { index < bytes.count ? bytes[index] : nil }

    private mutating func skipWhitespace() {
        while let byte = current, byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 { index += 1 }
    }

    private mutating func literal(_ text: StaticString, _ value: JSONValue) -> JSONValue? {
        let count = text.utf8CodeUnitCount
        guard index + count <= bytes.count else { return nil }
        let matches = text.withUTF8Buffer { expected in
            (0 ..< count).allSatisfy { bytes[index + $0] == expected[$0] }
        }
        guard matches else { return nil }
        index += count
        return value
    }

    private mutating func value(depth: Int = 0) -> JSONValue? {
        guard depth < 512 else { return nil }
        skipWhitespace()
        switch current {
        case UInt8(ascii: "{"): return object(depth: depth)
        case UInt8(ascii: "["): return array(depth: depth)
        case UInt8(ascii: "\""): return string().map(JSONValue.string)
        case UInt8(ascii: "t"): return literal("true", .bool(true))
        case UInt8(ascii: "f"): return literal("false", .bool(false))
        case UInt8(ascii: "n"): return literal("null", .null)
        case let byte? where byte == UInt8(ascii: "-") || (0x30 ... 0x39).contains(byte): return number()
        default: return nil
        }
    }

    private mutating func object(depth: Int) -> JSONValue? {
        index += 1
        var result: [String: JSONValue] = [:]
        skipWhitespace()
        if current == UInt8(ascii: "}") { index += 1; return .object(result) }
        while true {
            skipWhitespace()
            guard current == UInt8(ascii: "\""), let key = string() else { return nil }
            skipWhitespace()
            guard current == UInt8(ascii: ":") else { return nil }
            index += 1
            guard let value = value(depth: depth + 1) else { return nil }
            // JSONEncoder never emits duplicate keys; refuse rather than pick a winner.
            guard result.updateValue(value, forKey: key) == nil else { return nil }
            skipWhitespace()
            switch current {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "}"): index += 1; return .object(result)
            default: return nil
            }
        }
    }

    private mutating func array(depth: Int) -> JSONValue? {
        index += 1
        var result: [JSONValue] = []
        skipWhitespace()
        if current == UInt8(ascii: "]") { index += 1; return .array(result) }
        while true {
            guard let value = value(depth: depth + 1) else { return nil }
            result.append(value)
            skipWhitespace()
            switch current {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "]"): index += 1; return .array(result)
            default: return nil
            }
        }
    }

    private mutating func hex4() -> UInt32? {
        guard index + 4 <= bytes.count else { return nil }
        var value: UInt32 = 0
        for byte in bytes[index ..< index + 4] {
            let digit: UInt32
            switch byte {
            case 0x30 ... 0x39: digit = UInt32(byte - 0x30)
            case 0x41 ... 0x46: digit = UInt32(byte - 0x41 + 10)
            case 0x61 ... 0x66: digit = UInt32(byte - 0x61 + 10)
            default: return nil
            }
            value = value << 4 | digit
        }
        index += 4
        return value
    }

    private mutating func string() -> String? {
        index += 1
        var utf8: [UInt8] = []
        while let byte = current {
            index += 1
            switch byte {
            case UInt8(ascii: "\""):
                return String(bytes: utf8, encoding: .utf8)
            case UInt8(ascii: "\\"):
                guard let escaped = current else { return nil }
                index += 1
                let scalar: UInt32
                switch escaped {
                case UInt8(ascii: "\""): scalar = 0x22
                case UInt8(ascii: "\\"): scalar = 0x5C
                case UInt8(ascii: "/"): scalar = 0x2F
                case UInt8(ascii: "b"): scalar = 0x08
                case UInt8(ascii: "f"): scalar = 0x0C
                case UInt8(ascii: "n"): scalar = 0x0A
                case UInt8(ascii: "r"): scalar = 0x0D
                case UInt8(ascii: "t"): scalar = 0x09
                case UInt8(ascii: "u"):
                    guard let high = hex4() else { return nil }
                    if (0xD800 ... 0xDBFF).contains(high) {
                        guard current == UInt8(ascii: "\\"), index + 1 < bytes.count,
                              bytes[index + 1] == UInt8(ascii: "u") else { return nil }
                        index += 2
                        guard let low = hex4(), (0xDC00 ... 0xDFFF).contains(low) else { return nil }
                        scalar = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
                    } else {
                        guard !(0xDC00 ... 0xDFFF).contains(high) else { return nil }
                        scalar = high
                    }
                default: return nil
                }
                guard let unicode = Unicode.Scalar(scalar) else { return nil }
                utf8.append(contentsOf: Array(String(Character(unicode)).utf8))
            case 0x00 ..< 0x20:
                return nil
            default:
                utf8.append(byte)
            }
        }
        return nil
    }

    private mutating func number() -> JSONValue? {
        let start = index
        var integral = true
        if current == UInt8(ascii: "-") { index += 1 }
        guard let first = current, (0x30 ... 0x39).contains(first) else { return nil }
        if first == 0x30 {
            index += 1
        } else {
            while let byte = current, (0x30 ... 0x39).contains(byte) { index += 1 }
        }
        if current == UInt8(ascii: ".") {
            integral = false
            index += 1
            guard let byte = current, (0x30 ... 0x39).contains(byte) else { return nil }
            while let byte = current, (0x30 ... 0x39).contains(byte) { index += 1 }
        }
        if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
            integral = false
            index += 1
            if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { index += 1 }
            guard let byte = current, (0x30 ... 0x39).contains(byte) else { return nil }
            while let byte = current, (0x30 ... 0x39).contains(byte) { index += 1 }
        }
        let text = String(decoding: bytes[start ..< index], as: UTF8.self) // ASCII digits and signs only
        guard let value = Double(text), value.isFinite else { return nil }
        if integral { return Int(text).map(JSONValue.number) ?? .double(value) }
        // Like JSONDecoder, a fraction or exponent still decodes as an integer when its exact
        // decimal value is one (e.g. "5.0", "1e2", "9007199254740993.0"); judge it exactly.
        guard let decimal = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
            // Beyond Decimal's exponent range: far outside Int, or a value that rounds to zero.
            return Int(exactly: value).map(JSONValue.number) ?? .double(value)
        }
        var rounded = Decimal(), source = decimal
        NSDecimalRound(&rounded, &source, 0, .plain)
        if rounded == decimal, let exact = Int(decimal.description) { return .number(exact) }
        return .double(value)
    }
}
