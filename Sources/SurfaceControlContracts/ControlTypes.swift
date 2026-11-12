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

/// Optional contract 1.1 lease description. Only absolute/scalar and button/boolean controls may declare it.
public struct ControlHold: Equatable, Codable, Sendable {
    /// The value the host restores when a lease expires. Must be a valid input for the control.
    public let rest_value: JSONValue
    /// Upper bound for `hold_s`, in seconds, within (0, 10].
    public let max_hold_s: Double
    public init(restValue: JSONValue, maxHoldSeconds: Double) { rest_value = restValue; max_hold_s = maxHoldSeconds }
    public static let maximumHoldSeconds = 10.0
}

public struct ControlDescriptor: Equatable, Codable, Sendable {
    public let id: String
    public let input_kind: ControlInputKind
    public let encoding: ControlEncoding
    public let range: ControlValueRange?
    public let feedback_range: ControlValueRange?
    public let feedback_kinds: [ControlFeedbackKind]
    public let mapping: ControlMapping?
    /// Contract 1.1, optional. Absent descriptors encode exactly as contract 1.0.
    public let hold: ControlHold?
    /// Contract 1.2: absent means input policy is not declared.
    public let accepts_input: Bool?
    public init(id: String, inputKind: ControlInputKind, encoding: ControlEncoding,
                range: ControlValueRange? = nil, feedbackRange: ControlValueRange? = nil, feedbackKinds: [ControlFeedbackKind] = [],
                mapping: ControlMapping? = nil, hold: ControlHold? = nil, acceptsInput: Bool? = nil) {
        self.id = id; input_kind = inputKind; self.encoding = encoding; self.range = range
        feedback_range = feedbackRange; feedback_kinds = feedbackKinds; self.mapping = mapping; self.hold = hold; accepts_input = acceptsInput
    }
    /// True when `value` is a valid, unclamped input for this control's encoding and range.
    public func admits(_ value: JSONValue) -> Bool {
        switch encoding {
        case .boolean: value.boolValue != nil
        case .scalar, .signedDelta: value.finiteNumber.map { range?.contains($0) == true } ?? false
        }
    }
}

/// Registered contract 1.1 capability vocabulary. Host-private values use `x.<host>.<name>`.
public enum ControlCapability {
    public static let registered: Set<String> = [
        "simulation", "controls.stable_ids", "controls.layered", "input.absolute", "input.relative",
        "input.button", "input.hold", "feedback.value", "feedback.indicator",
        "feedback.unsequenced", "controls.input_declared", "input.independent_sequence",
        "events.writer_id", "writes.independent_limits"
    ]
    /// `x.<host>.<name>`: three or more nonempty dot-separated components starting with `x`.
    public static func isHostPrivate(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 3 && parts[0] == "x" && parts.allSatisfy { !$0.isEmpty }
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
    /// Contract 1.1: capabilities must be registered or `x.<host>.` private and must cover every declared
    /// input kind, feedback kind, and hold. `input.hold` requires at least one control with `hold`.
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
            if let hold = control.hold {
                // A relative delta has no resting position, so a lease cannot restore one.
                guard control.input_kind != .relative, hold.max_hold_s.isFinite, hold.max_hold_s > 0,
                      hold.max_hold_s <= ControlHold.maximumHoldSeconds, control.admits(hold.rest_value) else { throw ControlContractError("invalid_profile") }
            }
        }
        let declared = Set(capabilities)
        guard declared.allSatisfy({ ControlCapability.registered.contains($0) || ControlCapability.isHostPrivate($0) }) else {
            throw ControlContractError("invalid_profile")
        }
        guard controls.allSatisfy({ ($0.accepts_input != nil) == declared.contains("controls.input_declared") }) else {
            throw ControlContractError("invalid_profile")
        }
        var required: Set<String> = []
        for control in controls {
            required.insert("input." + control.input_kind.rawValue)
            for kind in control.feedback_kinds { required.insert("feedback." + kind.rawValue) }
            if control.hold != nil { required.insert("input.hold") }
        }
        guard required.isSubset(of: declared),
              !declared.contains("input.hold") || controls.contains(where: { $0.hold != nil }) else { throw ControlContractError("invalid_profile") }
    }
    /// Deterministic contract 1.1 mapping revision: FNV-1a 64 of the canonical mapping document,
    /// as 16 lowercase hex digits. See docs/surface-control.md for the exact canonical form.
    public var mappingRevision: String { ControlCanonicalJSON.fnv1a64Hex(ControlCanonicalJSON.mappingDocument(self)) }
    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
        }
    }
}

/// Canonical JSON used only for the mapping revision. Independent of JSONEncoder formatting.
public enum ControlCanonicalJSON {
    /// Sorted-key, whitespace-free JSON array of every control's mapping-relevant fields, ordered by control ID.
    public static func mappingDocument(_ profile: ControlProfile) -> String {
        let rows = profile.controls.sorted { Array($0.id.unicodeScalars.map(\.value)).lexicographicallyPrecedes($1.id.unicodeScalars.map(\.value)) }
            .map { control -> JSONValue in
                var row: [String: JSONValue] = [
                    "id": .string(control.id), "input_kind": .string(control.input_kind.rawValue),
                    "encoding": .string(control.encoding.rawValue),
                    "feedback_kinds": .array(control.feedback_kinds.map(\.rawValue).sorted().map(JSONValue.string))
                ]
                if let range = control.range { row["range"] = rangeValue(range) }
                if let range = control.feedback_range { row["feedback_range"] = rangeValue(range) }
                if let mapping = control.mapping { row["mapping"] = .object(["kind": .string(mapping.kind.rawValue), "id": .string(mapping.id)]) }
                if let accepts = control.accepts_input { row["accepts_input"] = .bool(accepts) }
                if let hold = control.hold { row["hold"] = .object(["rest_value": hold.rest_value, "max_hold_s": .double(hold.max_hold_s)]) }
                return .object(row)
            }
        return serialize(.array(rows))
    }
    private static func rangeValue(_ range: ControlValueRange) -> JSONValue {
        var value: [String: JSONValue] = ["minimum": .double(range.minimum), "maximum": .double(range.maximum)]
        if let step = range.step { value["step"] = .double(step) }
        return .object(value)
    }
    /// Numbers: integral values with magnitude below 2^53 print as integers; others use the shortest
    /// round-trip decimal (Swift `Double.description`, identical to Python `repr(float)`).
    public static func serialize(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let number): return number_(Double(number))
        case .double(let number): return number_(number)
        case .string(let text): return quote(text)
        case .array(let items): return "[" + items.map(serialize).joined(separator: ",") + "]"
        case .object(let fields):
            let keys = fields.keys.sorted { Array($0.unicodeScalars.map(\.value)).lexicographicallyPrecedes($1.unicodeScalars.map(\.value)) }
            return "{" + keys.map { quote($0) + ":" + serialize(fields[$0]!) }.joined(separator: ",") + "}"
        }
    }
    private static func number_(_ value: Double) -> String {
        // Profile validation admits finite values only; nonfinite input never reaches a revision.
        if value.rounded() == value, abs(value) < 9_007_199_254_740_992 { return String(Int64(value)) }
        return value.description
    }
    private static func quote(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    result += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else { result.unicodeScalars.append(scalar) }
            }
        }
        return result + "\""
    }
    public static func fnv1a64Hex(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash ^= UInt64(byte); hash = hash &* 0x0000_0100_0000_01b3 }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
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
    public let expected_sequence: String?
    public let expected_input_sequence: String?
    public let control_id: String
    public let encoding: String
    public let value: JSONValue
    /// Contract 1.1, optional lease duration in seconds, (0, hold.max_hold_s]. Absent in 1.0 requests.
    public let hold_s: Double?
    public init(expected: ControlExpected, expectedSequence: String? = nil, expectedInputSequence: String? = nil, controlID: String, encoding: String, value: JSONValue, holdSeconds: Double? = nil) {
        self.expected = expected; expected_sequence = expectedSequence; expected_input_sequence = expectedInputSequence
        control_id = controlID; self.encoding = encoding; self.value = value
        hold_s = holdSeconds
    }
}

/// Contract 1.1 silent lease renewal: consumes no sequence and writes no event.
public struct ControlRenew: Equatable, Codable, Sendable {
    public let expected: ControlExpected
    public let control_id: String
    public let hold_s: Double
    public init(expected: ControlExpected, controlID: String, holdSeconds: Double) {
        self.expected = expected; control_id = controlID; hold_s = holdSeconds
    }
}
public struct ControlRenewResult: Equatable, Codable, Sendable {
    public let control_id: String
    public let hold_deadline: Double
    public let server_time: Double
}
/// A due lease. The host applies `rest_value` to its engine, then calls `recordHoldExpiry`.
public struct ControlHoldExpiry: Equatable, Sendable {
    public let controlID: String
    public let restValue: JSONValue
    public let deadline: Double
}

public struct ControlFeedback: Equatable, Codable, Sendable {
    public let expected: ControlExpected
    public let expected_sequence: String?
    public let control_id: String
    public let kind: String
    public let value: JSONValue
    public init(expected: ControlExpected, expectedSequence: String? = nil, controlID: String, kind: String, value: JSONValue) {
        self.expected = expected; expected_sequence = expectedSequence; control_id = controlID; self.kind = kind; self.value = value
    }
}

public struct ControlDiscovery: Equatable, Codable, Sendable {
    /// Additive minor version. `schema_version` stays 1: 1.0 requests remain valid and 1.1 fields are optional.
    public static let contractVersion = "1.3"
    public let schema_version: Int
    public let contract_version: String
    public let source: PluginSource
    public let expected: ControlExpected
    public let profile: ControlProfile
    public let latest_sequence: String
    public let latest_input_sequence: String?
    public let write_limits: ControlWriteLimits?
    public init(expected: ControlExpected, profile: ControlProfile, latestSequence: String, latestInputSequence: String? = nil, writeLimits: ControlWriteLimits? = nil) {
        latest_sequence = latestSequence; latest_input_sequence = latestInputSequence; write_limits = writeLimits
        schema_version = 1; contract_version = Self.contractVersion; source = .simulation; self.expected = expected; self.profile = profile
    }
}

public struct ControlEvent: Equatable, Codable, Sendable {
    public let expected: ControlExpected
    /// Decimal strings preserve the complete cursor across JSON clients.
    public let sequence: String
    public let input_sequence: String?
    public let writer_id: String?
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
    /// Contract 1.1, present only on an accepted input that acquired a lease.
    public let hold_deadline: Double?
}

public struct ControlSnapshot: Equatable, Codable, Sendable {
    public let discovery: ControlDiscovery
    public let server_time: Double
    public let latest_sequence: String
    public let latest_input_sequence: String?
    public let inputs: [String: JSONValue]
    public let feedback: [String: [String: JSONValue]]
    /// Contract 1.1: active lease deadlines by control ID. Omitted when no lease is held.
    public let holds: [String: Double]?
}
public struct ControlEventPage: Equatable, Codable, Sendable {
    public let server_time: Double
    public let expected: ControlExpected
    public let latest_sequence: String
    public let latest_input_sequence: String?
    public let events: [ControlEvent]
    /// Contract 1.2: current leases at page read time, omitted when empty.
    public let holds: [String: Double]?
}

/// Host-owned fixed-window write policy; no clock, counters, credentials, or I/O in the contract.
public struct ControlWriteLimits: Equatable, Codable, Sendable {
    public let window_s: Int
    public let input_per_window: Int
    public let feedback_per_window: Int
    public let renew_per_window: Int
    public let admin_per_window: Int
    public init(windowSeconds: Int = 1, inputPerWindow: Int, feedbackPerWindow: Int, renewPerWindow: Int, adminPerWindow: Int) {
        window_s = windowSeconds; input_per_window = inputPerWindow; feedback_per_window = feedbackPerWindow
        renew_per_window = renewPerWindow; admin_per_window = adminPerWindow
    }
    public func validate() throws {
        guard window_s == 1, [input_per_window, feedback_per_window, renew_per_window, admin_per_window].allSatisfy({ (1...10000).contains($0) }) else {
            throw ControlContractError("invalid_argument")
        }
    }
}
