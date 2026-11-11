import Foundation

public indirect enum JSONValue: Equatable, Codable, Sendable {
    case null
    case bool(Bool)
    case number(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Int.self) {
            self = .number(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .double(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
            return
        }
        if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported JSON value"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .double(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(values):
            try container.encode(values)
        case let .object(values):
            try container.encode(values)
        }
    }

    public var stringValue: String? {
        if case let .string(value) = self {
            value
        } else {
            nil
        }
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self {
            value
        } else {
            nil
        }
    }

    public var intValue: Int? {
        switch self {
        case let .number(value):
            value
        case let .double(value):
            Int(exactly: value.rounded())
        default:
            nil
        }
    }

    public var objectValue: [String: JSONValue]? {
        if case let .object(value) = self {
            value
        } else {
            nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case let .array(value) = self {
            value
        } else {
            nil
        }
    }

    public func value(for key: String) -> JSONValue? {
        objectValue?[key]
    }
}

public extension JSONValue {
    var finiteNumber: Double? {
        let value: Double
        switch self {
        case let .number(n): value = Double(n)
        case let .double(n): value = n
        default: return nil
        }
        return value.isFinite ? value : nil
    }

    static func encoded<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    func decoded<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }

    var jsonText: String {
        // All values admitted by the service are finite and therefore JSON encodable.
        get throws { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
    }
}
