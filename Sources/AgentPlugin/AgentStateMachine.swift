import Foundation
import SurfacePluginContracts

public enum AgentRunState: String, Codable, CaseIterable, Sendable {
    case idle, queued, running, waitingApproval, completed, interrupted, error
    public var isActive: Bool { self == .queued || self == .running || self == .waitingApproval }
    public var nameKey: String { "agent.state.\(rawValue)" }
    public var indicatorSemantic: IndicatorSemantic {
        switch self {
        case .idle: .idle
        case .queued: .queued
        case .running: .active
        case .waitingApproval: .attention
        case .completed: .done
        case .interrupted: .stopped
        case .error: .fault
        }
    }
}
public struct AgentSlot: Equatable, Sendable {
    public let id: Int
    public internal(set) var state: AgentRunState
    public internal(set) var progress: Double
    public internal(set) var statusKey: String
    public internal(set) var lastUpdated: PluginTime
}
public struct AgentStateMachine: Sendable {
    public private(set) var slots: [AgentSlot]
    public init(slotCount: Int = 8, at time: PluginTime = 0) throws {
        guard slotCount > 0 else { throw PluginError(code: .invalidParameter, fields: ["slotCount": .number(slotCount)]) }
        guard time.isFinite else { throw PluginError(code: .invalidTime) }
        slots = (1...slotCount).map { AgentSlot(id: $0, state: .idle, progress: 0, statusKey: "agent.awaitingTask", lastUpdated: time) }
    }
    public func slot(_ id: Int) -> AgentSlot? { slots.first { $0.id == id } }
    @discardableResult
    public mutating func transition(_ id: Int, to state: AgentRunState, progress: Double? = nil,
                                    statusKey: String? = nil, at time: PluginTime) throws -> AgentSlot {
        guard let i = slots.firstIndex(where: { $0.id == id }) else { throw PluginError(code: .indexOutOfRange, fields: ["index": .number(id)]) }
        let old = slots[i]
        guard time.isFinite, time >= old.lastUpdated else { throw PluginError(code: .invalidTime) }
        guard Self.allows(from: old.state, to: state) else {
            throw PluginError(code: .invalidTransition, fields: ["index": .number(id), "from": .string(old.state.rawValue), "to": .string(state.rawValue)])
        }
        if let progress, !progress.isFinite { throw PluginError(code: .invalidParameter, fields: ["field": .string("progress")]) }
        slots[i].state = state
        if let progress { slots[i].progress = min(max(progress, 0), 1) }
        if let statusKey { slots[i].statusKey = statusKey }
        slots[i].lastUpdated = time
        return slots[i]
    }
    @discardableResult
    public mutating func updateProgress(_ id: Int, progress: Double, statusKey: String, at time: PluginTime) throws -> AgentSlot {
        guard let slot = slot(id) else { throw PluginError(code: .indexOutOfRange, fields: ["index": .number(id)]) }
        guard slot.state == .running else { throw PluginError(code: .invalidTransition) }
        return try transition(id, to: .running, progress: progress, statusKey: statusKey, at: time)
    }
    public static func allows(from old: AgentRunState, to new: AgentRunState) -> Bool {
        if old == new || new == .error { return true }
        return switch (old, new) {
        case (.idle, .queued), (.completed, .queued), (.interrupted, .queued), (.error, .queued),
             (.queued, .running), (.queued, .interrupted), (.running, .waitingApproval),
             (.running, .completed), (.running, .interrupted), (.waitingApproval, .running),
             (.waitingApproval, .interrupted): true
        default: false
        }
    }
}
