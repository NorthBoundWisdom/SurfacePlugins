import Foundation
import SurfacePluginContracts

/// Entry-path policy only; it is not a substitute for the host's identity checks.
public enum AgentApprovalPolicy: String, Codable, Sendable { case anyOrigin, localOrigins, interfaceOnly }

public struct AgentPlugin: ControlPlugin {
    public static let pluginID: PluginID = "agent"
    public static let primaryActionID: ActionID = "agent.primary"
    public let manifest = PluginManifest(id: Self.pluginID, version: "0.1.0", source: .mock)
    public let approvalPolicy: AgentApprovalPolicy
    public private(set) var machine: AgentStateMachine
    public private(set) var isStarted = false
    private var lastTime: PluginTime
    private struct Stage: Sendable {
        let offset: Double
        let state: AgentRunState
        let progress: Double
        let key: String
    }
    private struct Timeline: Sendable { let anchor: Double; var stages: [Stage] }
    private var timelines: [Int: Timeline] = [:]

    public init(slotCount: Int = 8, approvalPolicy: AgentApprovalPolicy = .anyOrigin, at time: PluginTime = 0) throws {
        machine = try AgentStateMachine(slotCount: slotCount, at: time)
        self.approvalPolicy = approvalPolicy; lastTime = time
    }
    public var slots: [AgentSlot] { machine.slots }
    public static func indicatorID(for slot: Int) -> IndicatorID { .init(rawValue: "agent.slot.\(slot)") }
    public var surface: SurfaceDescriptor {
        .init(actions: [.init(id: Self.primaryActionID, nameKey: "agent.primary", indexCount: slots.count)],
              indicators: slots.map { .init(id: Self.indicatorID(for: $0.id), nameKey: "agent.slot") })
    }
    public func snapshot() -> PluginSnapshot {
        .init(isStarted: isStarted, indicators: Dictionary(uniqueKeysWithValues: slots.map {
            (Self.indicatorID(for: $0.id), .init(semantic: $0.state.indicatorSemantic, progress: $0.progress))
        }))
    }
    /// Stage advancement occurs only on .advance. Large jumps emit every due stage in order.
    /// A failed call commits neither state nor clock changes.
    public mutating func handle(_ input: PluginInput, at time: PluginTime) throws -> PluginUpdate {
        guard time.isFinite, time >= lastTime else { throw PluginError(code: .invalidTime) }
        var next = self
        let update = try next.apply(input, at: time)
        next.lastTime = time
        self = next
        return update
    }
    /// Explicit interruption never approves a pending request and affects only this slot.
    public mutating func interrupt(_ id: Int, at time: PluginTime) throws -> PluginUpdate {
        guard time.isFinite, time >= lastTime else { throw PluginError(code: .invalidTime) }
        guard isStarted else { throw PluginError(code: .stopped) }
        guard let slot = machine.slot(id) else { throw PluginError(code: .indexOutOfRange, fields: ["index": .number(id)]) }
        var next = self
        var events: [PluginEvent] = []
        if slot.state.isActive {
            events.append(next.event(try next.machine.transition(id, to: .interrupted, statusKey: "agent.interrupted", at: time)))
            next.timelines[id] = nil
        }
        next.lastTime = time
        self = next
        return .init(indicators: snapshot().indicators, events: events)
    }
    private mutating func apply(_ input: PluginInput, at time: PluginTime) throws -> PluginUpdate {
        var events: [PluginEvent] = []
        switch input {
        case .start: isStarted = true
        case .stop:
            for slot in slots where slot.state.isActive {
                let changed = try machine.transition(slot.id, to: .interrupted, statusKey: "agent.stopped", at: time)
                events.append(event(changed))
            }
            timelines.removeAll(); isStarted = false
        case .advance:
            if isStarted {
                for id in timelines.keys.sorted() {
                    guard var timeline = timelines[id] else { continue }
                    while let stage = timeline.stages.first, time >= timeline.anchor + stage.offset {
                        let changed = try machine.transition(id, to: stage.state, progress: stage.progress,
                                                            statusKey: stage.key, at: timeline.anchor + stage.offset)
                        events.append(event(changed)); timeline.stages.removeFirst()
                    }
                    timelines[id] = timeline.stages.isEmpty ? nil : timeline
                }
            }
        case let .invoke(ref, origin):
            guard isStarted else { throw PluginError(code: .stopped) }
            guard ref.pluginID == Self.pluginID, ref.actionID == Self.primaryActionID else { throw PluginError(code: .unknownAction) }
            guard let id = ref.index, let slot = machine.slot(id) else {
                throw PluginError(code: .indexOutOfRange, fields: ["index": ref.index.map(JSONValue.number) ?? .null])
            }
            switch slot.state {
            case .idle, .completed, .interrupted, .error:
                events.append(event(try machine.transition(id, to: .queued, progress: 0, statusKey: "agent.mock.queued", at: time)))
                timelines[id] = .init(anchor: time, stages: Self.initialStages)
            case .queued, .running:
                events.append(event(try machine.transition(id, to: .interrupted, statusKey: "agent.interrupted", at: time)))
                timelines[id] = nil
            case .waitingApproval:
                guard (approvalPolicy != .interfaceOnly || origin == .interface) && (approvalPolicy != .localOrigins || origin != .remote) else {
                    let fields: [String: JSONValue] = approvalPolicy == .localOrigins
                        ? ["allowedOrigins": .array([.string(InputOrigin.hardware.rawValue), .string(InputOrigin.interface.rawValue)])]
                        : ["requiredOrigin": .string(InputOrigin.interface.rawValue)]
                    throw PluginError(code: .permissionDenied, fields: fields)
                }
                events.append(event(try machine.transition(id, to: .running, progress: 0.64, statusKey: "agent.mock.approved", at: time)))
                timelines[id] = .init(anchor: time, stages: Self.approvedStages)
            }
        case let .parameterChanged(id, _, _):
            guard isStarted else { throw PluginError(code: .stopped) }
            throw PluginError(code: .invalidParameter, fields: ["parameter": .string(id.rawValue)])
        }
        return .init(indicators: snapshot().indicators, events: events)
    }
    private func event(_ slot: AgentSlot) -> PluginEvent {
        .init(code: "agent.updated", fields: ["slot": .number(slot.id), "state": .string(slot.state.rawValue),
              "progress": .double(slot.progress), "statusKey": .string(slot.statusKey), "time": .double(slot.lastUpdated)])
    }
    private static var initialStages: [Stage] {
        [.init(offset: 0.45, state: .running, progress: 0.08, key: "agent.mock.analyze"),
         .init(offset: 1, state: .running, progress: 0.20, key: "agent.mock.context"),
         .init(offset: 1.55, state: .running, progress: 0.34, key: "agent.mock.plan"),
         .init(offset: 2.10, state: .running, progress: 0.48, key: "agent.mock.patch"),
         .init(offset: 2.65, state: .running, progress: 0.58, key: "agent.mock.prepare"),
         .init(offset: 2.65, state: .waitingApproval, progress: 0.60, key: "agent.mock.awaitingApproval")]
    }
    private static var approvedStages: [Stage] {
        [.init(offset: 0.60, state: .running, progress: 0.72, key: "agent.mock.test"),
         .init(offset: 1.20, state: .running, progress: 0.84, key: "agent.mock.build"),
         .init(offset: 1.80, state: .running, progress: 0.94, key: "agent.mock.summarize"),
         .init(offset: 2.25, state: .completed, progress: 1, key: "agent.mock.completed")]
    }
}
