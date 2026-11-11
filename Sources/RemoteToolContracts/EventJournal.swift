import Foundation
import SurfacePluginContracts

public struct RemoteEvent: Equatable, Codable, Sendable {
    public let sequence: UInt64
    public let time: Double
    public let instanceID: String
    public let event: PluginEvent
}
public struct RemoteEventPage: Equatable, Codable, Sendable {
    public let epoch: String
    public let gap: Bool
    public let events: [RemoteEvent]
    public let latestSequence: UInt64
}
/// Caller-injected epoch isolates independent lifetimes. Reading never mutates or replays input.
public struct RemoteEventJournal: Sendable {
    public let epoch: String
    public let capacity: Int
    private var records: [RemoteEvent] = []
    private var sequence: UInt64 = 0
    public init(epoch: String, capacity: Int = 256) throws {
        guard !epoch.isEmpty, capacity > 0, capacity <= 65536 else { throw PluginError(code: .invalidParameter) }
        self.epoch = epoch; self.capacity = capacity
    }
    public mutating func append(instanceID: String, event: PluginEvent, at time: Double) throws {
        guard time.isFinite, records.last.map({ time >= $0.time }) ?? true, sequence < UInt64.max else { throw PluginError(code: .invalidTime) }
        sequence += 1; records.append(.init(sequence: sequence, time: time, instanceID: instanceID, event: event))
        if records.count > capacity { records.removeFirst(records.count - capacity) }
    }
    public func read(epoch requestedEpoch: String, after cursor: UInt64, limit: Int = 128) throws -> RemoteEventPage {
        guard limit > 0, limit <= 65536 else { throw PluginError(code: .invalidParameter) }
        let first = records.first?.sequence ?? sequence
        let gap = requestedEpoch != epoch || cursor > sequence || (cursor < first && first - cursor > 1)
        return .init(epoch: epoch, gap: gap, events: Array(records.filter { $0.sequence > cursor || requestedEpoch != epoch }.prefix(limit)), latestSequence: sequence)
    }
}
