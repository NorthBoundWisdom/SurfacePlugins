import Foundation
import SurfacePluginContracts

/// Wire-ready stable error data. Message localization belongs to hosts.
public struct RemoteFailure: Error, Equatable, Codable, Sendable {
    public let code: String
    public let fields: [String: JSONValue]
    public init(code: String, fields: [String: JSONValue] = [:]) { self.code = code; self.fields = fields }
    public static func from(_ error: any Error) -> RemoteFailure {
        if let failure = error as? RemoteFailure { return failure }
        if let failure = error as? PluginError { return .init(code: failure.code.rawValue, fields: failure.fields) }
        return .init(code: "outcomeUnknown")
    }
}
