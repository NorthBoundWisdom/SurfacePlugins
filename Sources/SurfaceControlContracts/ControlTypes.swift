import Foundation
import SurfacePluginContracts

public struct ControlContractError: Error, Equatable, Codable, Sendable {
    public let code: String
    public init(_ code: String) { self.code = code }
}

public enum ControlInputKind: String, Codable, Sendable { case absolute, relative, button }
public enum ControlEncoding: String, Codable, Sendable { case scalar, signedDelta, boolean }
public enum ControlFeedbackKind: String, Codable, Sendable { case value, indicator }
public enum ControlDisposition: String, Codable, Sendable { case accepted, ignored }
public enum ControlEventKind: String, Codable, Sendable { case input, feedback }

public struct ControlValueRange: Equatable, Codable, Sendable {
    public let minimum: Double
    public let maximum: Double
    public let step: Double?
    public init(minimum: Double, maximum: Double, step: Double? = nil) {
        self.minimum = minimum; self.maximum = maximum; self.step = step
    }
    public func validate() throws {
        guard minimum.isFinite, maximum.isFinite, minimum < maximum,
              step.map({ $0.isFinite && $0 > 0 }) ?? true else { throw ControlContractError("invalid_profile") }
    }
    public func contains(_ value: Double) -> Bool {
        guard value.isFinite, value >= minimum, value <= maximum else { return false }
        guard let step else { return true }
        // The public encoding grid is anchored at zero. Endpoints are always admitted.
        return value == minimum || value == maximum || (value / step).isFinite && (value / step).rounded() * step == value
    }
}

public struct ControlMapping: Equatable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case parameter, action }
    public let kind: Kind
    public let id: String
    public init(kind: Kind, id: String) { self.kind = kind; self.id = id }
}

public struct ControlDescriptor: Equatable, Codable, Sendable {
    public let id: String
    public let input_kind: ControlInputKind
    public let encoding: ControlEncoding
    public let range: ControlValueRange?
    public let feedback_range: ControlValueRange?
    public let feedback_kinds: [ControlFeedbackKind]
    public let mapping: ControlMapping?
    public init(id: String, inputKind: ControlInputKind, encoding: ControlEncoding,
                range: ControlValueRange? = nil, feedbackRange: ControlValueRange? = nil, feedbackKinds: [ControlFeedbackKind] = [], mapping: ControlMapping? = nil) {
        self.id = id; input_kind = inputKind; self.encoding = encoding; self.range = range
        feedback_range = feedbackRange; feedback_kinds = feedbackKinds; self.mapping = mapping
    }
}

public struct ControlProfile: Equatable, Codable, Sendable {
    public let id: String
    public let version: String
    public let controls: [ControlDescriptor]
    public let capabilities: [String]
    public init(id: String, version: String, controls: [ControlDescriptor], capabilities: [String] = []) {
        self.id = id; self.version = version; self.controls = controls; self.capabilities = capabilities
    }
    public func validate() throws {
        guard Self.validID(id), !version.isEmpty, version.utf8.count <= 64, !controls.isEmpty, controls.count <= 4096,
              Set(controls.map(\.id)).count == controls.count, Set(capabilities).count == capabilities.count,
              capabilities.allSatisfy(Self.validID) else { throw ControlContractError("invalid_profile") }
        for control in controls {
            guard Self.validID(control.id), Set(control.feedback_kinds).count == control.feedback_kinds.count,
                  control.mapping.map({ Self.validID($0.id) }) ?? true else { throw ControlContractError("invalid_profile") }
            if let feedbackRange = control.feedback_range {
                try feedbackRange.validate()
                guard control.feedback_kinds.contains(.value), control.encoding != .boolean else { throw ControlContractError("invalid_profile") }
            }
            switch (control.input_kind, control.encoding) {
            case (.button, .boolean):
                guard control.range == nil else { throw ControlContractError("invalid_profile") }
            case (.absolute, .scalar), (.relative, .signedDelta):
                guard let range = control.range else { throw ControlContractError("invalid_profile") }
                try range.validate()
                if control.input_kind == .relative && !(range.minimum < 0 && range.maximum > 0) { throw ControlContractError("invalid_profile") }
            default: throw ControlContractError("unsupported_encoding")
            }
        }
    }
    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
        }
    }
}

/// All five fields are pinned by consumers. They never authorize a source or an operation.
public struct ControlExpected: Equatable, Codable, Sendable {
    public let instance_id: String
    public let epoch: String
    public let mapping_revision: String
    public let profile_id: String
    public let profile_version: String
    public init(instanceID: String, epoch: String, mappingRevision: String, profileID: String, profileVersion: String) {
        instance_id = instanceID; self.epoch = epoch; mapping_revision = mappingRevision
        profile_id = profileID; profile_version = profileVersion
    }
}

public struct ControlInput: Equatable, Codable, Sendable {
    public let expected: ControlExpected
    public let expected_sequence: String
    public let control_id: String
    public let encoding: String
    public let value: JSONValue
    public init(expected: ControlExpected, expectedSequence: String, controlID: String, encoding: String, value: JSONValue) {
        self.expected = expected; expected_sequence = expectedSequence; control_id = controlID; self.encoding = encoding; self.value = value
    }
}

public struct ControlFeedback: Equatable, Codable, Sendable {
    public let expected: ControlExpected
    public let expected_sequence: String
    public let control_id: String
    public let kind: String
    public let value: JSONValue
    public init(expected: ControlExpected, expectedSequence: String, controlID: String, kind: String, value: JSONValue) {
        self.expected = expected; expected_sequence = expectedSequence; control_id = controlID; self.kind = kind; self.value = value
    }
}

public struct ControlDiscovery: Equatable, Codable, Sendable {
    public let schema_version: Int
    public let contract_version: String
    public let source: PluginSource
    public let expected: ControlExpected
    public let profile: ControlProfile
    public let latest_sequence: String
    public init(expected: ControlExpected, profile: ControlProfile, latestSequence: String) {
        latest_sequence = latestSequence
        schema_version = 1; contract_version = "1.0"; source = .simulation; self.expected = expected; self.profile = profile
    }
}

public struct ControlEvent: Equatable, Codable, Sendable {
    public let expected: ControlExpected
    /// Decimal strings preserve the complete cursor across JSON clients.
    public let sequence: String
    public let time: Double
    public let source: PluginSource
    public let origin: InputOrigin
    public let kind: ControlEventKind
    public let control_id: String
    public let encoding: String
    public let value: JSONValue
    public let disposition: ControlDisposition
    public let mapped_value: JSONValue?
    public let reason: String?
}

public struct ControlSnapshot: Equatable, Codable, Sendable {
    public let discovery: ControlDiscovery
    public let server_time: Double
    public let latest_sequence: String
    public let inputs: [String: JSONValue]
    public let feedback: [String: [String: JSONValue]]
}
public struct ControlEventPage: Equatable, Codable, Sendable {
    public let server_time: Double
    public let expected: ControlExpected
    public let latest_sequence: String
    public let events: [ControlEvent]
}
