import SurfacePluginContracts
import Foundation

public enum OSCArgument: Equatable, Sendable {
    case int(Int32), float(Float), string(String)
}

public struct OSCMessage: Equatable, Sendable {
    public let address: String
    public let arguments: [OSCArgument]
    public init(_ address: String, _ arguments: [OSCArgument]) { self.address = address; self.arguments = arguments }
}

public indirect enum OSCPacket: Equatable, Sendable {
    case message(OSCMessage)
    case bundle(timetag: UInt64, elements: [OSCPacket])
}

public enum OSCCodec {
    public static func encode(_ packet: OSCPacket) throws -> Data { try encode(packet, depth: 0) }

    private static func encode(_ packet: OSCPacket, depth: Int) throws -> Data {
        guard depth <= 8 else { throw MotionSafetyError("output.reason.017") }
        var data = Data()
        switch packet {
        case let .message(message):
            guard message.address.hasPrefix("/"), message.address.utf8.count <= 512 else { throw MotionSafetyError("output.reason.018") }
            try string(message.address, into: &data)
            let tags = "," + message.arguments.map { argument in
                switch argument { case .int: "i"; case .float: "f"; case .string: "s" }
            }.joined()
            try string(tags, into: &data)
            for argument in message.arguments {
                switch argument {
                case let .int(value): integer(UInt32(bitPattern: value), into: &data)
                case let .float(value):
                    guard value.isFinite else { throw MotionSafetyError("output.reason.019") }
                    integer(value.bitPattern, into: &data)
                case let .string(value): try string(value, into: &data)
                }
            }
        case let .bundle(timetag, elements):
            try string("#bundle", into: &data)
            integer(UInt32(timetag >> 32), into: &data)
            integer(UInt32(timetag & 0xffff_ffff), into: &data)
            for element in elements {
                let child = try encode(element, depth: depth + 1)
                guard child.count <= 65_507 else { throw MotionSafetyError("output.reason.020") }
                integer(UInt32(child.count), into: &data)
                data.append(child)
            }
        }
        guard data.count <= 65_507 else { throw MotionSafetyError("output.reason.021") }
        return data
    }

    public static func decode(_ data: Data) throws -> OSCPacket {
        try decode(data, depth: 0)
    }

    public static func immediateMessages(_ packet: OSCPacket) throws -> [OSCMessage] {
        switch packet {
        case let .message(message): return [message]
        case let .bundle(timetag, elements):
            guard timetag == 1 else { throw MotionSafetyError("output.reason.022") }
            return try elements.flatMap(immediateMessages)
        }
    }

    public static func parameterAddress(_ id: ParameterID, prefix: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-".utf8)
        return prefix + id.rawValue.utf8.map {
            allowed.contains($0) ? String(UnicodeScalar($0)) : String(format: "%%%02X", Int($0))
        }.joined()
    }

    public static func parameterID(_ address: String, prefix: String) throws -> ParameterID {
        guard address.hasPrefix(prefix), let id = String(address.dropFirst(prefix.count)).removingPercentEncoding,
              !id.isEmpty
        else {
            throw MotionSafetyError("output.reason.023")
        }
        return ParameterID(rawValue: id)
    }

    private static func decode(_ data: Data, depth: Int) throws -> OSCPacket {
        guard depth <= 8, !data.isEmpty, data.count % 4 == 0, data.count <= 65_507 else {
            throw MotionSafetyError("output.reason.024")
        }
        var cursor = Cursor(bytes: Array(data))
        let address = try cursor.string()
        if address == "#bundle" {
            let high = try cursor.integer(), low = try cursor.integer()
            let timetag = UInt64(high) << 32 | UInt64(low)
            var elements: [OSCPacket] = []
            while cursor.index < cursor.bytes.count {
                let count = Int(try cursor.integer())
                guard count > 0, count % 4 == 0, count <= cursor.bytes.count - cursor.index else {
                    throw MotionSafetyError("output.reason.025")
                }
                let child = Data(cursor.bytes[cursor.index ..< (cursor.index + count)])
                cursor.index += count
                elements.append(try decode(child, depth: depth + 1))
            }
            return .bundle(timetag: timetag, elements: elements)
        }
        guard address.hasPrefix("/") else { throw MotionSafetyError("output.reason.026") }
        let tags = try cursor.string()
        guard tags.hasPrefix(",") else { throw MotionSafetyError("output.reason.027") }
        var arguments: [OSCArgument] = []
        for tag in tags.dropFirst() {
            switch tag {
            case "i": arguments.append(.int(Int32(bitPattern: try cursor.integer())))
            case "f":
                let value = Float(bitPattern: try cursor.integer())
                guard value.isFinite else { throw MotionSafetyError("output.reason.028") }
                arguments.append(.float(value))
            case "s": arguments.append(.string(try cursor.string()))
            default: throw MotionSafetyError("output.reason.029")
            }
        }
        guard cursor.index == cursor.bytes.count else { throw MotionSafetyError("output.reason.030") }
        return .message(OSCMessage(address, arguments))
    }

    private static func integer(_ value: UInt32, into data: inout Data) {
        data.append(contentsOf: [
            UInt8(value >> 24),
            UInt8((value >> 16) & 255),
            UInt8((value >> 8) & 255),
            UInt8(value & 255)
        ])
    }

    private static func string(_ value: String, into data: inout Data) throws {
        guard !value.utf8.contains(0),
              value.utf8.allSatisfy({ $0 < 128 }) else { throw MotionSafetyError("output.reason.031") }
        data.append(contentsOf: value.utf8); data.append(0)
        while data.count % 4 != 0 { data.append(0) }
    }

    private struct Cursor {
        let bytes: [UInt8]
        var index = 0
        mutating func integer() throws -> UInt32 {
            guard bytes.count - index >= 4 else { throw MotionSafetyError("output.reason.032") }
            let value = UInt32(bytes[index]) << 24 | UInt32(bytes[index + 1]) << 16 | UInt32(bytes[index + 2]) << 8 |
                UInt32(bytes[index + 3])
            index += 4
            return value
        }

        mutating func string() throws -> String {
            let start = index
            guard let end = bytes[index...].firstIndex(of: 0)
            else { throw MotionSafetyError("output.reason.033") }
            guard bytes[start ..< end].allSatisfy({ $0 < 128 })
            else { throw MotionSafetyError("output.reason.034") }
            let padded = (end + 4) & ~3
            guard padded <= bytes.count,
                  bytes[end ..< padded].allSatisfy({ $0 == 0 })
            else { throw MotionSafetyError("output.reason.035") }
            index = padded
            return String(decoding: bytes[start ..< end], as: UTF8.self)
        }
    }
}
