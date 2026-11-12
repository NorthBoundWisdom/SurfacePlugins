import Foundation
import SurfacePluginContracts

/// A separate input/feedback journal, not the plugin business journal. No device I/O or mapping engine.
/// Hosts clone this value and their engine, validate first, process, record, then commit both values.
public struct SurfaceControlSession: Sendable {
    public private(set) var expected: ControlExpected
    public private(set) var profile: ControlProfile
    public let eventCapacity: Int
    private var sequence: UInt64 = 0
    private var records: [ControlEvent] = []
    private var inputs: [String: JSONValue] = [:]
    private var feedback: [String: [String: JSONValue]] = [:]
    private var lastTime: Double?
    private var seeded = false

    public init(instanceID: String, epoch: String, mappingRevision: String, profile: ControlProfile, eventCapacity: Int = 1024) throws {
        guard !instanceID.isEmpty, !epoch.isEmpty, !mappingRevision.isEmpty, eventCapacity > 0, eventCapacity <= 65536 else { throw ControlContractError("invalid_argument") }
        try profile.validate()
        expected = .init(instanceID: instanceID, epoch: epoch, mappingRevision: mappingRevision, profileID: profile.id, profileVersion: profile.version)
        self.profile = profile; self.eventCapacity = eventCapacity
    }
    public func discovery() -> ControlDiscovery { .init(expected: expected, profile: profile, latestSequence: String(sequence)) }
    public func snapshot(at time: Double) throws -> ControlSnapshot {
        try validateReadTime(time)
        return .init(discovery: discovery(), server_time: time, latest_sequence: String(sequence), inputs: inputs, feedback: feedback)
    }

    public func validateExpected(_ value: ControlExpected) throws {
        guard value.instance_id == expected.instance_id else { throw ControlContractError("instance_mismatch") }
        guard value.profile_id == expected.profile_id, value.profile_version == expected.profile_version else { throw ControlContractError("unsupported_profile") }
        guard value.epoch == expected.epoch else { throw ControlContractError("stale_epoch") }
        guard value.mapping_revision == expected.mapping_revision else { throw ControlContractError("stale_mapping") }
    }
    /// Validate before calling the host engine. No clamping, rounding, or encoding fallback.
    @discardableResult public func validateInput(_ input: ControlInput, at time: Double? = nil) throws -> ControlDescriptor {
        try validateExpected(input.expected)
        try validateSequence(input.expected_sequence)
        if let time { try validateTime(time) }
        guard let control = profile.controls.first(where: { $0.id == input.control_id }) else { throw ControlContractError("unsupported_control") }
        guard input.encoding == control.encoding.rawValue else { throw ControlContractError("unsupported_encoding") }
        switch control.encoding {
        case .boolean: guard input.value.boolValue != nil else { throw ControlContractError("invalid_value") }
        case .scalar, .signedDelta:
            guard let value = input.value.finiteNumber, control.range?.contains(value) == true else { throw ControlContractError("invalid_value") }
        }
        return control
    }
    public func validateFeedback(_ update: ControlFeedback, at time: Double? = nil) throws {
        try validateExpected(update.expected)
        try validateSequence(update.expected_sequence)
        if let time { try validateTime(time) }
        guard let control = profile.controls.first(where: { $0.id == update.control_id }) else { throw ControlContractError("unsupported_control") }
        guard let kind = ControlFeedbackKind(rawValue: update.kind), control.feedback_kinds.contains(kind) else { throw ControlContractError("unsupported_feedback") }
        switch kind {
        case .indicator:
            guard let value = update.value.stringValue, ["off", "on", "blink"].contains(value) else { throw ControlContractError("invalid_value") }
        case .value:
            if control.encoding == .boolean {
                guard update.value.boolValue != nil else { throw ControlContractError("invalid_value") }
            } else {
                guard let value = update.value.finiteNumber, (control.feedback_range ?? control.range)?.contains(value) == true else { throw ControlContractError("invalid_value") }
            }
        }
    }
    private func validateReadTime(_ time: Double) throws {
        guard time.isFinite, lastTime.map({ time >= $0 }) ?? true else { throw ControlContractError("invalid_time") }
    }
    public func validateSequence(_ value: String) throws {
        guard let parsed = UInt64(value), String(parsed) == value else { throw ControlContractError("invalid_argument") }
        guard parsed == sequence else { throw ControlContractError("stale_sequence") }
    }
    /// Trusted host bootstrap from the current Mock model only. Unknown controls may be omitted.
    /// This is not a remotely callable observation API and never creates an input event.
    public mutating func seedInputs(_ values: [String: JSONValue], at time: Double) throws {
        guard sequence == 0, !seeded else { throw ControlContractError("invalid_transition") }
        try validateTime(time)
        for (id, value) in values {
            guard let control = profile.controls.first(where: { $0.id == id }) else { throw ControlContractError("unsupported_control") }
            try validateInput(.init(expected: expected, expectedSequence: "0", controlID: id, encoding: control.encoding.rawValue, value: value), at: time)
        }
        inputs = values; seeded = true; lastTime = time
    }
    private func validateTime(_ time: Double) throws {
        try validateReadTime(time)
        guard sequence < UInt64.max else { throw ControlContractError("sequence_exhausted") }
    }
    private func validateResult(_ disposition: ControlDisposition, mappedValue: JSONValue?, reason: String?) throws {
        guard reason.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true,
              disposition != .ignored || reason != nil else { throw ControlContractError("invalid_result") }
        if let mappedValue {
            guard mappedValue.finiteNumber != nil || mappedValue.boolValue != nil || mappedValue.stringValue.map({ !$0.isEmpty }) == true else { throw ControlContractError("invalid_result") }
        }
    }
    @discardableResult public mutating func recordInput(_ input: ControlInput, disposition: ControlDisposition,
        mappedValue: JSONValue? = nil, reason: String? = nil, origin: InputOrigin, at time: Double) throws -> ControlEvent {
        try validateInput(input, at: time)
        try validateResult(disposition, mappedValue: mappedValue, reason: reason)
        let event = append(kind: .input, controlID: input.control_id, encoding: input.encoding, value: input.value,
                           disposition: disposition, mappedValue: mappedValue, reason: reason, origin: origin, at: time)
        if disposition == .accepted { inputs[input.control_id] = input.value }
        return event
    }
    /// Observation only: this method never records a control input or changes its accepted value.
    @discardableResult public mutating func recordFeedback(_ update: ControlFeedback, disposition: ControlDisposition = .accepted,
        reason: String? = nil, origin: InputOrigin, at time: Double) throws -> ControlEvent {
        try validateFeedback(update, at: time)
        try validateResult(disposition, mappedValue: nil, reason: reason)
        let event = append(kind: .feedback, controlID: update.control_id, encoding: update.kind, value: update.value,
                           disposition: disposition, mappedValue: nil, reason: reason, origin: origin, at: time)
        if disposition == .accepted { feedback[update.control_id, default: [:]][update.kind] = update.value }
        return event
    }
    private mutating func append(kind: ControlEventKind, controlID: String, encoding: String, value: JSONValue,
        disposition: ControlDisposition, mappedValue: JSONValue?, reason: String?, origin: InputOrigin, at time: Double) -> ControlEvent {
        sequence += 1
        let event = ControlEvent(expected: expected, sequence: String(sequence), time: time, source: .simulation,
                                 origin: origin, kind: kind, control_id: controlID, encoding: encoding, value: value,
                                 disposition: disposition, mapped_value: mappedValue, reason: reason)
        records.append(event)
        if records.count > eventCapacity { records.removeFirst(records.count - eventCapacity) }
        lastTime = time
        return event
    }
    public func events(instanceID: String, epoch: String, afterSequence: String, limit: Int = 128, at time: Double) throws -> ControlEventPage {
        try validateReadTime(time)
        guard instanceID == expected.instance_id else { throw ControlContractError("instance_mismatch") }
        guard epoch == expected.epoch else { throw ControlContractError("stale_epoch") }
        guard !afterSequence.isEmpty, afterSequence.utf8.allSatisfy({ (48...57).contains($0) }),
              let cursor = UInt64(afterSequence), String(cursor) == afterSequence, limit > 0, limit <= 1024 else { throw ControlContractError("invalid_argument") }
        let first = records.first.flatMap { UInt64($0.sequence) } ?? sequence
        guard cursor <= sequence, !(cursor < first && first - cursor > 1) else { throw ControlContractError("event_gap") }
        return .init(server_time: time, expected: expected, latest_sequence: String(sequence), events: Array(records.filter { UInt64($0.sequence)! > cursor }.prefix(limit)))
    }
    /// The host supplies fresh identity. No automatic replay or input-state restoration after reset.
    public mutating func reset(expected old: ControlExpected, expectedSequence: String, epoch: String, mappingRevision: String, profile: ControlProfile? = nil, at time: Double) throws {
        try validateExpected(old)
        try validateSequence(expectedSequence)
        try validateTime(time)
        guard !epoch.isEmpty, epoch != expected.epoch else { throw ControlContractError("invalid_argument") }
        var next = try SurfaceControlSession(instanceID: expected.instance_id, epoch: epoch, mappingRevision: mappingRevision,
                                             profile: profile ?? self.profile, eventCapacity: eventCapacity)
        next.lastTime = time
        self = next
    }
}
