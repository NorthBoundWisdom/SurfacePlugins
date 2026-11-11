import Foundation
import SurfacePluginContracts

public struct TimedInput: Sendable {
    public let input: PluginInput
    public let time: PluginTime
    public init(_ input: PluginInput, at time: PluginTime) { self.input = input; self.time = time }
}
public struct ConformanceFailure: Error, Equatable, Sendable {
    public let check: String
    public init(_ check: String) { self.check = check }
}
/// Test support only. The supplied invalid inputs must target this plugin's unknown action,
/// an indexed action outside its declared range, and a writable operation after stop.
public enum PluginConformance {
    public static func check<P: ControlPlugin>(make: () throws -> P, sequence: [TimedInput],
                                               unknownAction: PluginInput, outOfRange: PluginInput,
                                               writeAfterStop: PluginInput) throws {
        var a = try make(), b = try make()
        try declarations(a)
        for item in sequence {
            let before = a.snapshot()
            guard before == a.snapshot(), before == a.snapshot() else { throw ConformanceFailure("snapshot.purity") }
            let left = Result { try a.handle(item.input, at: item.time) }
            let right = Result { try b.handle(item.input, at: item.time) }
            switch (left, right) {
            case let (.success(x), .success(y)):
                guard x == y else { throw ConformanceFailure("replay.update") }
            case let (.failure(x as PluginError), .failure(y as PluginError)):
                guard x == y, a.snapshot() == before else { throw ConformanceFailure("replay.error") }
            default: throw ConformanceFailure("replay.result")
            }
            guard a.snapshot() == b.snapshot() else { throw ConformanceFailure("replay.snapshot") }
        }
        var probe = try make()
        _ = try probe.handle(.start, at: 0)
        try rejects(&probe, input: unknownAction, time: 0, code: .unknownAction)
        try rejects(&probe, input: outOfRange, time: 0, code: .indexOutOfRange)
        try rejects(&probe, input: .advance, time: .nan, code: .invalidTime)
        _ = try probe.handle(.advance, at: 1)
        try rejects(&probe, input: .advance, time: 0, code: .invalidTime)
        _ = try probe.handle(.stop, at: 1)
        guard !probe.snapshot().isStarted else { throw ConformanceFailure("stop.snapshot") }
        try rejects(&probe, input: writeAfterStop, time: 1, code: .stopped)
    }
    public static func declarations<P: ControlPlugin>(_ plugin: P) throws {
        let namespace = plugin.manifest.id.rawValue + "."
        guard namespace != "." else { throw ConformanceFailure("namespace.empty") }
        let groups = [plugin.surface.parameters.map { $0.id.rawValue }, plugin.surface.actions.map { $0.id.rawValue }, plugin.surface.indicators.map { $0.id.rawValue }]
        for ids in groups {
            guard Set(ids).count == ids.count else { throw ConformanceFailure("identifier.duplicate") }
            guard ids.allSatisfy({ $0.hasPrefix(namespace) && $0.count > namespace.count }) else { throw ConformanceFailure("identifier.namespace") }
        }
        guard plugin.surface.actions.allSatisfy({ $0.indexCount == nil || $0.indexCount! > 0 }) else { throw ConformanceFailure("action.indexCount") }
    }
    private static func rejects<P: ControlPlugin>(_ plugin: inout P, input: PluginInput, time: PluginTime, code: PluginErrorCode) throws {
        let before = plugin.snapshot()
        do { _ = try plugin.handle(input, at: time); throw ConformanceFailure("reject.\(code.rawValue)") }
        catch let error as PluginError {
            guard error.code == code, plugin.snapshot() == before else { throw ConformanceFailure("error.\(code.rawValue).atomicity") }
        }
    }
}
