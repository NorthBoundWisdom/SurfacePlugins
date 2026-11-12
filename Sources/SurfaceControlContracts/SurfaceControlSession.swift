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
    /// Contract 1.1 active lease deadlines by control ID.
    private var holds: [String: Double] = [:]
    private var lastTime: Double?
    private var seeded = false

    public init(instanceID: String, epoch: String, mappingRevision: String, profile: ControlProfile, eventCapacity: Int = 1024) throws {
        guard !instanceID.isEmpty, !epoch.isEmpty, !mappingRevision.isEmpty, eventCapacity > 0, eventCapacity <= 65536 else { throw ControlContractError("invalid_argument") }
        try profile.validate()
        expected = .init(instanceID: instanceID, epoch: epoch, mappingRevision: mappingRevision, profileID: profile.id, profileVersion: profile.version)
        self.profile = profile; self.eventCapacity = eventCapacity
    }
    /// Contract 1.1 convenience: uses the deterministic `profile.mappingRevision`.
    public init(instanceID: String, epoch: String, profile: ControlProfile, eventCapacity: Int = 1024) throws {
        try self.init(instanceID: instanceID, epoch: epoch, mappingRevision: profile.mappingRevision, profile: profile, eventCapacity: eventCapacity)
    }
    /// Session numeric form: integral values representable as Int become `.number`, other numbers `.double`.
    /// Applied recursively, so equal numbers compare equal regardless of their wire representation.
    public static func normalized(_ value: JSONValue) -> JSONValue {
        switch value {
        case .double(let number): if let integer = Int(exactly: number) { return .number(integer) } else { return value }
        case .array(let items): return .array(items.map(normalized))
        case .object(let fields): return .object(fields.mapValues(normalized))
        default: return value
        }
    }
    public func discovery() -> ControlDiscovery { .init(expected: expected, profile: profile, latestSequence: String(sequence)) }
    public func snapshot(at time: Double) throws -> ControlSnapshot {
        try validateReadTime(time)
        try validateNoPendingExpiry(at: time)
        return .init(discovery: discovery(), server_time: time, latest_sequence: String(sequence), inputs: inputs, feedback: feedback,
                     holds: holds.isEmpty ? nil : holds)
    }

    /// Contract 1.1 order: instance, profile, mapping, then epoch, so a mapping change is distinguishable from a new epoch.
    public func validateExpected(_ value: ControlExpected) throws {
        guard value.instance_id == expected.instance_id else { throw ControlContractError("instance_mismatch") }
        guard value.profile_id == expected.profile_id, value.profile_version == expected.profile_version else { throw ControlContractError("unsupported_profile") }
        guard value.mapping_revision == expected.mapping_revision else { throw ControlContractError("stale_mapping") }
        guard value.epoch == expected.epoch else { throw ControlContractError("stale_epoch") }
    }
    /// Fail closed while any lease with deadline <= time has not been processed through `recordHoldExpiry`.
    public func validateNoPendingExpiry(at time: Double) throws {
        guard !holds.values.contains(where: { $0 <= time }) else { throw ControlContractError("hold_expiry_pending") }
    }
    /// Due leases ordered by deadline, then control ID. Pure: the host applies each rest value, then records it.
    public func dueHoldExpiries(at time: Double) -> [ControlHoldExpiry] {
        holds.filter { $0.value <= time }.sorted { ($0.value, $0.key) < ($1.value, $1.key) }.compactMap { id, deadline in
            profile.controls.first(where: { $0.id == id })?.hold.map { .init(controlID: id, restValue: Self.normalized($0.rest_value), deadline: deadline) }
        }
    }
    /// The next pending lease deadline, for host scheduling. Nil when no lease is held.
    public var nextHoldDeadline: Double? { holds.values.min() }
    /// True when recording this valid input as accepted would change neither the input value nor any lease.
    /// Hosts use it for `no_change`. Relative input is unchanged only for a zero delta.
    public func isUnchanged(_ input: ControlInput) -> Bool {
        guard let control = profile.controls.first(where: { $0.id == input.control_id }) else { return false }
        let value = Self.normalized(input.value)
        if control.input_kind == .relative { return value.finiteNumber == 0 }
        guard inputs[input.control_id] == value, holds[input.control_id] == nil else { return false }
        return input.hold_s == nil || control.hold.map { Self.normalized($0.rest_value) == value } == true
    }
    /// Validate before calling the host engine. No clamping, rounding, or encoding fallback.
    @discardableResult public func validateInput(_ input: ControlInput, at time: Double? = nil) throws -> ControlDescriptor {
        try validateExpected(input.expected)
        try validateSequence(input.expected_sequence)
        if let time { try validateTime(time); try validateNoPendingExpiry(at: time) }
        guard let control = profile.controls.first(where: { $0.id == input.control_id }) else { throw ControlContractError("unsupported_control") }
        guard control.accepts_input != false else { throw ControlContractError("permission_denied") }
        guard input.encoding == control.encoding.rawValue else { throw ControlContractError("unsupported_encoding") }
        guard control.admits(input.value) else { throw ControlContractError("invalid_value") }
        if let seconds = input.hold_s { try validateHoldSeconds(seconds, control: control) }
        return control
    }
    private func validateHoldSeconds(_ seconds: Double, control: ControlDescriptor) throws {
        guard let hold = control.hold else { throw ControlContractError("unsupported_hold") }
        guard seconds.isFinite, seconds > 0, seconds <= hold.max_hold_s else { throw ControlContractError("invalid_argument") }
    }
    public func validateFeedback(_ update: ControlFeedback, at time: Double? = nil) throws {
        try validateExpected(update.expected)
        if let sequence = update.expected_sequence { try validateSequence(sequence) }
        else if !profile.capabilities.contains("feedback.unsequenced") { throw ControlContractError("invalid_argument") }
        if let time { try validateTime(time); try validateNoPendingExpiry(at: time) }
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
            guard control.admits(value) else { throw ControlContractError("invalid_value") }
        }
        inputs = values.mapValues(Self.normalized); seeded = true; lastTime = time
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
        let control = try validateInput(input, at: time)
        try validateResult(disposition, mappedValue: mappedValue, reason: reason)
        let value = Self.normalized(input.value)
        var deadline: Double?
        if disposition == .accepted, let hold = control.hold {
            // Accepting a value replaces any lease. Only a non-rest value with hold_s acquires a new one.
            if let seconds = input.hold_s, value != Self.normalized(hold.rest_value) { deadline = time + seconds }
            holds[input.control_id] = deadline
        }
        let event = append(kind: .input, controlID: input.control_id, encoding: input.encoding, value: value,
                           disposition: disposition, mappedValue: mappedValue, reason: reason, origin: origin, at: time, holdDeadline: deadline)
        if disposition == .accepted { inputs[input.control_id] = value }
        return event
    }
    /// Validate a silent renewal without changing state. Hosts check permission/write budget around this call.
    public func validateRenew(_ request: ControlRenew, at time: Double) throws {
        try validateExpected(request.expected)
        try validateReadTime(time)
        try validateNoPendingExpiry(at: time)
        guard let control = profile.controls.first(where: { $0.id == request.control_id }) else { throw ControlContractError("unsupported_control") }
        try validateHoldSeconds(request.hold_s, control: control)
        guard let deadline = holds[request.control_id], deadline > time else { throw ControlContractError("hold_expired") }
    }
    /// Contract 1.1 renewal: sets the lease deadline to `time + hold_s`. Consumes no sequence and writes no event.
    /// It advances the write clock, so later writes cannot use an earlier time.
    public mutating func renew(_ request: ControlRenew, at time: Double) throws -> ControlRenewResult {
        try validateRenew(request, at: time)
        let deadline = time + request.hold_s
        holds[request.control_id] = deadline; lastTime = time
        return .init(control_id: request.control_id, hold_deadline: deadline, server_time: time)
    }
    /// Record a due lease after the host applied its rest value: `input/accepted/origin remote/reason hold_expired`.
    /// This is the only accepted input carrying a reason defined by this contract.
    @discardableResult public mutating func recordHoldExpiry(controlID: String, mappedValue: JSONValue? = nil, at time: Double) throws -> ControlEvent {
        try validateTime(time)
        guard let deadline = holds[controlID], deadline <= time,
              let control = profile.controls.first(where: { $0.id == controlID }), let hold = control.hold else { throw ControlContractError("invalid_transition") }
        try validateResult(.accepted, mappedValue: mappedValue, reason: Self.holdExpiredReason)
        let rest = Self.normalized(hold.rest_value)
        holds[controlID] = nil
        inputs[controlID] = rest
        return append(kind: .input, controlID: controlID, encoding: control.encoding.rawValue, value: rest, disposition: .accepted,
                      mappedValue: mappedValue, reason: Self.holdExpiredReason, origin: .remote, at: time, holdDeadline: nil)
    }
    public static let holdExpiredReason = "hold_expired"
    /// Observation only: this method never records a control input or changes its accepted value.
    @discardableResult public mutating func recordFeedback(_ update: ControlFeedback, disposition: ControlDisposition = .accepted,
        reason: String? = nil, origin: InputOrigin, at time: Double) throws -> ControlEvent {
        try validateFeedback(update, at: time)
        try validateResult(disposition, mappedValue: nil, reason: reason)
        let value = Self.normalized(update.value)
        let event = append(kind: .feedback, controlID: update.control_id, encoding: update.kind, value: value,
                           disposition: disposition, mappedValue: nil, reason: reason, origin: origin, at: time, holdDeadline: nil)
        if disposition == .accepted { feedback[update.control_id, default: [:]][update.kind] = value }
        return event
    }
    private mutating func append(kind: ControlEventKind, controlID: String, encoding: String, value: JSONValue,
        disposition: ControlDisposition, mappedValue: JSONValue?, reason: String?, origin: InputOrigin, at time: Double, holdDeadline: Double?) -> ControlEvent {
        sequence += 1
        let event = ControlEvent(expected: expected, sequence: String(sequence), time: time, source: .simulation,
                                 origin: origin, kind: kind, control_id: controlID, encoding: encoding, value: value,
                                 disposition: disposition, mapped_value: mappedValue.map(Self.normalized), reason: reason, hold_deadline: holdDeadline)
        records.append(event)
        if records.count > eventCapacity { records.removeFirst(records.count - eventCapacity) }
        lastTime = time
        return event
    }
    public func events(instanceID: String, epoch: String, afterSequence: String, limit: Int = 128, at time: Double) throws -> ControlEventPage {
        try validateReadTime(time)
        try validateNoPendingExpiry(at: time)
        guard instanceID == expected.instance_id else { throw ControlContractError("instance_mismatch") }
        guard epoch == expected.epoch else { throw ControlContractError("stale_epoch") }
        guard !afterSequence.isEmpty, afterSequence.utf8.allSatisfy({ (48...57).contains($0) }),
              let cursor = UInt64(afterSequence), String(cursor) == afterSequence, limit > 0, limit <= 1024 else { throw ControlContractError("invalid_argument") }
        let first = records.first.flatMap { UInt64($0.sequence) } ?? sequence
        guard cursor <= sequence, !(cursor < first && first - cursor > 1) else { throw ControlContractError("event_gap") }
        return .init(server_time: time, expected: expected, latest_sequence: String(sequence), events: Array(records.filter { UInt64($0.sequence)! > cursor }.prefix(limit)), holds: holds.isEmpty ? nil : holds)
    }
    /// Contract 1.1 convenience: uses the deterministic mapping revision of the new (or current) profile.
    public mutating func reset(expected old: ControlExpected, expectedSequence: String, epoch: String, profile: ControlProfile? = nil, at time: Double) throws {
        try reset(expected: old, expectedSequence: expectedSequence, epoch: epoch,
                  mappingRevision: (profile ?? self.profile).mappingRevision, profile: profile, at: time)
    }
    /// The host supplies fresh identity. No automatic replay or input-state restoration after reset.
    /// Reset clears every lease; it is rejected while a due lease is unprocessed.
    public mutating func reset(expected old: ControlExpected, expectedSequence: String, epoch: String, mappingRevision: String, profile: ControlProfile? = nil, at time: Double) throws {
        try validateExpected(old)
        try validateSequence(expectedSequence)
        try validateTime(time)
        try validateNoPendingExpiry(at: time)
        guard !epoch.isEmpty, epoch != expected.epoch else { throw ControlContractError("invalid_argument") }
        var next = try SurfaceControlSession(instanceID: expected.instance_id, epoch: epoch, mappingRevision: mappingRevision,
                                             profile: profile ?? self.profile, eventCapacity: eventCapacity)
        next.lastTime = time
        self = next
    }
}
