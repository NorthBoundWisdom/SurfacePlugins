import Foundation

/// Identifiers retain the single-string JSON representation used by saved bindings.
public protocol StringIdentifier: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral where RawValue == String, StringLiteralType == String {
    init(rawValue: String)
}
public extension StringIdentifier {
    init(stringLiteral value: String) { self.init(rawValue: value) }
    init(from decoder: any Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}
public struct PluginID: StringIdentifier { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct ParameterID: StringIdentifier { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct ActionID: StringIdentifier { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct IndicatorID: StringIdentifier { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
