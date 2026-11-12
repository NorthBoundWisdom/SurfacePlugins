import XCTest
import SurfacePluginContracts
import RemoteToolContracts
import SimulationContracts
import RobotPlugin
import RobotRemoteBinding
import ChassisPlugin
import ChassisRemoteBinding
import ParameterOutputPlugin
import OutputRemoteBinding

final class EventNoiseTests: XCTestCase {
    func testSilentCommitUsesIndependentClockAndAtomicFailure() throws {
        var registry = try RemoteRegistry(epoch: "test")
        let plugin = try ParameterOutputPlugin(limits: [.init(id: "x", minimum: 0, maximum: 1, maximumChange: 1, maximumVelocity: 1)])
        var binding = OutputRemoteBinding(instanceID: "output", plugin: plugin)
        try registry.install(binding)
        _ = try binding.handle(.start, at: 0)
        try registry.replace(binding, at: 10, event: nil)
        let page = try registry.journal.read(epoch: "test", after: 0)
        XCTAssertTrue(page.events.isEmpty)
        _ = try binding.handle(.stop, at: 1)
        for time in [9.0, .nan, .infinity] { XCTAssertThrowsError(try registry.replace(binding, at: time, event: nil)) }
        XCTAssertEqual(registry.snapshot(instanceID: "output")?.isStarted, true)
        XCTAssertEqual(try registry.journal.read(epoch: "test", after: 0), page)
        _ = try registry.call("surface_capabilities", arguments: .object([:]), context: .init(time: 999))
        try registry.replace(binding, at: 10, event: nil)
        XCTAssertEqual(registry.snapshot(instanceID: "output")?.isStarted, false)
        XCTAssertThrowsError(try registry.handle(instanceID: "output", input: .start, at: 9))
    }
    func testIdleTenThousandTicksHaveNoEventsAndPreserveCounters() throws {
        var registry = try RemoteRegistry(epoch: "test")
        var robot = try RobotPlugin(instanceID: "robot")
        var chassis = try ChassisPlugin(instanceID: "chassis")
        _ = try robot.handle(.start, at: 0); _ = try chassis.handle(.start, at: 0)
        // Initialized but disabled actuals and traces still follow legacy integration bookkeeping.
        try robot.simulator.initialize([0,0,0,0,0,0], generation: robot.simulator.control.generation)
        try chassis.simulator.initialize([0,0,0], generation: chassis.simulator.control.generation)
        _ = try robot.simulationEvent(at: 0); _ = try chassis.simulationEvent(at: 0)
        try registry.install([RobotRemoteBinding(instanceID: "robot", plugin: robot), ChassisRemoteBinding(instanceID: "chassis", plugin: chassis)])
        for i in 1...10_000 {
            _ = try registry.handle(instanceID: "robot", input: .advance, at: Double(i) * 0.02)
            _ = try registry.handle(instanceID: "chassis", input: .advance, at: Double(i) * 0.02)
        }
        XCTAssertTrue(try registry.journal.read(epoch: "test", after: 0).events.isEmpty)
        let current = try XCTUnwrap(registry.binding("robot", as: RobotRemoteBinding.self))
        XCTAssertEqual(current.plugin.simulator.control.time, 200, accuracy: 1e-9)
        XCTAssertGreaterThan(current.plugin.simulator.control.revision, 10_000)
        XCTAssertEqual(current.plugin.simulator.trace.count, 512)
    }
    func testSteadyOutputBookkeepingCanStaySilent() throws {
        var registry = try RemoteRegistry(epoch: "test")
        var plugin = try ParameterOutputPlugin(limits: [.init(id: "x", minimum: 0, maximum: 1, maximumChange: 1, maximumVelocity: 1)])
        _ = try plugin.handle(.start, at: 0); plugin.setConnected(true, at: 0); plugin.receiveHeartbeat(at: 0)
        plugin.receiveActual([.init(id: "x", value: 0, receivedAt: 0)])
        _ = plugin.evaluate(targets: [:], at: 0); try plugin.setEnabled(true); _ = plugin.evaluate(targets: ["x": 0], at: 0)
        var binding = OutputRemoteBinding(instanceID: "output", plugin: plugin)
        try registry.install(binding)
        for i in 1...1_000 {
            let time = Double(i) * 0.02
            binding.plugin.receiveHeartbeat(at: time); binding.plugin.receiveActual([.init(id: "x", value: 0, receivedAt: time)])
            XCTAssertEqual(binding.plugin.evaluate(targets: ["x": 0], at: time).status, .ready)
            try registry.replace(binding, at: time, event: nil)
        }
        XCTAssertTrue(try registry.journal.read(epoch: "test", after: 0).events.isEmpty)
    }
    func testMotionEventsCoalesceButControlPhaseAndFaultAreImmediate() throws {
        var plugin = try RobotPlugin(instanceID: "robot")
        _ = try plugin.handle(.start, at: 0)
        try plugin.simulator.initialize([0,0,0,0,0,0], generation: plugin.simulator.control.generation)
        _ = try plugin.simulationEvent(at: 0)
        let grant = try plugin.simulator.acquire(generation: plugin.simulator.control.generation, owner: "test", ttl: 5, controlToken: "secret")
        XCTAssertNotNil(try plugin.simulationEvent(at: 0))
        try plugin.simulator.enable(.init(generation: grant.generation, token: grant.control_token, sequence: 1))
        _ = try plugin.simulationEvent(at: 0)
        try plugin.simulator.move(.init(generation: grant.generation, token: grant.control_token, sequence: 2), target: [1,0,0,0,0,0], duration: 1.5, validFor: 2)
        XCTAssertNotNil(try plugin.simulationEvent(at: 0)) // first motion, without throttling a critical transition
        var emitted: [Double] = []
        for i in 1...74 {
            let time = Double(i) * 0.02
            if !(try plugin.handle(.advance, at: time)).events.isEmpty { emitted.append(time) }
        }
        XCTAssertLessThanOrEqual(emitted.count, 5)
        for pair in zip(emitted, emitted.dropFirst()) { XCTAssertGreaterThanOrEqual(pair.1 - pair.0, 0.25 - 1e-12) }
        XCTAssertFalse(try plugin.handle(.advance, at: 1.5).events.isEmpty) // terminal phase is immediate
        try plugin.simulator.fault("test_fault", generation: plugin.simulator.control.generation)
        XCTAssertNotNil(try plugin.simulationEvent(at: 1.5))
    }
    func testDefaultHistoryRetainsTwoInstancesForTwoMinutes() throws {
        var journal = try RemoteEventJournal(epoch: "test")
        XCTAssertEqual(journal.capacity, 1024)
        for i in 0..<480 {
            for id in ["robot", "chassis"] { try journal.append(instanceID: id, event: .init(code: "motion"), at: Double(i) * 0.25) }
        }
        let page = try journal.read(epoch: "test", after: 0, limit: 1024)
        XCTAssertFalse(page.gap); XCTAssertEqual(page.events.count, 960)
    }
}

final class MotionCadenceBoundaryTests: XCTestCase {
    func testExactCadenceAndRejectedPolicyTimeDoNotLoseObservation() throws {
        var simulator = try RobotSimulator(instanceID: "test")
        func state(_ value: Double) -> SimulationEventState {
            .init(metadata: simulator.snapshot().metadata, motionActive: true, actual: [value])
        }
        var policy = try SimulationEventPolicy(initial: state(0))
        XCTAssertNotNil(try policy.update(state(1), at: 0, code: "motion"))
        XCTAssertNil(try policy.update(state(2), at: 0.2, code: "motion"))
        XCTAssertNotNil(try policy.update(state(3), at: 0.25, code: "motion"))
        XCTAssertThrowsError(try policy.update(state(4), at: .nan, code: "motion"))
        XCTAssertThrowsError(try policy.update(state(4), at: 0.1, code: "motion"))
        XCTAssertNotNil(try policy.update(state(4), at: 0.5, code: "motion"))
        // idle clock/revision changes are deliberately outside the projection.
        try simulator.advance(0.1)
    }
}

final class CommandBaselineTests: XCTestCase {
    func testTypedCommandObservationPreventsDuplicateIdleEvent() throws {
        var robot = try RobotPlugin(instanceID: "robot")
        _ = try robot.handle(.start, at: 0)
        try robot.simulator.initialize([0,0,0,0,0,0], generation: robot.simulator.control.generation)
        _ = try robot.simulationEvent(at: 0)
        _ = try robot.simulator.acquire(generation: robot.simulator.control.generation, owner: "test", ttl: 1, controlToken: "secret")
        XCTAssertNotNil(try robot.simulationEvent(at: 0)) // explicit command event is logged by the host
        XCTAssertTrue(try robot.handle(.advance, at: 0.02).events.isEmpty)
        var chassis = try ChassisPlugin(instanceID: "chassis")
        _ = try chassis.handle(.start, at: 0)
        try chassis.simulator.initialize([0,0,0], generation: chassis.simulator.control.generation)
        _ = try chassis.simulationEvent(at: 0)
        _ = try chassis.simulator.acquire(generation: chassis.simulator.control.generation, owner: "test", ttl: 1, controlToken: "secret")
        XCTAssertNotNil(try chassis.simulationEvent(at: 0))
        XCTAssertTrue(try chassis.handle(.advance, at: 0.02).events.isEmpty)
    }
    func testRemoteCommandsSynchronizePolicyWithoutDuplicateIdleEvents() throws {
        for domain in ["robot", "chassis"] {
            var registry = try RemoteRegistry(epoch: "test")
            if domain == "robot" {
                var plugin = try RobotPlugin(instanceID: domain); _ = try plugin.handle(.start, at: 0)
                try registry.install(RobotRemoteBinding(instanceID: domain, plugin: plugin))
            } else {
                var plugin = try ChassisPlugin(instanceID: domain); _ = try plugin.handle(.start, at: 0)
                try registry.install(ChassisRemoteBinding(instanceID: domain, plugin: plugin))
            }
            let state = try registry.call("surface_"+domain+"_snapshot", arguments: .object(["instance_id": .string(domain)]), context: .init(time: 0))
            let generation = try XCTUnwrap(state.objectValue?["metadata"]?.objectValue?["generation"])
            let initialized = try registry.call("surface_"+domain+"_initialize", arguments: .object([
                "instance_id": .string(domain), "generation": generation,
                domain == "robot" ? "joints_rad" : "pose_m_rad": .array(Array(repeating: .number(0), count: domain == "robot" ? 6 : 3))
            ]), context: .init(time: 0))
            let nextGeneration = try XCTUnwrap(initialized.objectValue?["metadata"]?.objectValue?["generation"])
            _ = try registry.call("surface_"+domain+"_acquire", arguments: .object([
                "instance_id": .string(domain), "generation": nextGeneration, "owner": .string("test"), "ttl_s": .number(1)
            ]), context: .init(time: 0, controlToken: "secret"))
            let before = try registry.journal.read(epoch: "test", after: 0)
            XCTAssertEqual(before.events.count, 2)
            _ = try registry.handle(instanceID: domain, input: .advance, at: 0.02)
            XCTAssertEqual(try registry.journal.read(epoch: "test", after: 0), before)
        }
    }
}

final class PendingStopClockGapTests: XCTestCase {
    func testGapWhileStoppingCannotRestoreWriteLifecycle() throws {
        for domain in ["robot", "chassis"] {
            var registry = try RemoteRegistry(epoch: "test")
            if domain == "robot" {
                var plugin = try RobotPlugin(instanceID: domain)
                _ = try plugin.handle(.start, at: 0)
                try plugin.simulator.initialize([0,0,0,0,0,0], generation: plugin.simulator.control.generation)
                let g = try plugin.simulator.acquire(generation: plugin.simulator.control.generation, owner: "test", ttl: 5, controlToken: "secret")
                try plugin.simulator.enable(.init(generation: g.generation, token: g.control_token, sequence: 1))
                try plugin.simulator.move(.init(generation: g.generation, token: g.control_token, sequence: 2), target: [1,0,0,0,0,0], duration: 1.5, validFor: 2)
                try registry.install(RobotRemoteBinding(instanceID: domain, plugin: plugin))
            } else {
                var plugin = try ChassisPlugin(instanceID: domain)
                _ = try plugin.handle(.start, at: 0)
                try plugin.simulator.initialize([0,0,0], generation: plugin.simulator.control.generation)
                let g = try plugin.simulator.acquire(generation: plugin.simulator.control.generation, owner: "test", ttl: 5, controlToken: "secret")
                try plugin.simulator.enable(.init(generation: g.generation, token: g.control_token, sequence: 1))
                try plugin.simulator.drive(.init(generation: g.generation, token: g.control_token, sequence: 2), speed: 0.8, steering: 0.3, validFor: 2)
                try registry.install(ChassisRemoteBinding(instanceID: domain, plugin: plugin))
            }
            _ = try registry.handle(instanceID: domain, input: .advance, at: 0.5)
            _ = try registry.handle(instanceID: domain, input: .stop, at: 0.5)
            XCTAssertEqual(registry.snapshot(instanceID: domain)?.isStarted, true)
            _ = try registry.handle(instanceID: domain, input: .advance, at: 100)
            XCTAssertEqual(registry.snapshot(instanceID: domain)?.isStarted, false)
            if domain == "robot" { XCTAssertEqual(registry.binding(domain, as: RobotRemoteBinding.self)?.plugin.acceptsWrites, false) }
            else { XCTAssertEqual(registry.binding(domain, as: ChassisRemoteBinding.self)?.plugin.acceptsWrites, false) }
            let snapshotArgs: JSONValue = .object(["instance_id": .string(domain)])
            let snapshot = try registry.call("surface_"+domain+"_snapshot", arguments: snapshotArgs, context: .init(time: 100))
            let generation = try XCTUnwrap(snapshot.objectValue?["metadata"]?.objectValue?["generation"])
            XCTAssertEqual(snapshot.objectValue?["metadata"]?.objectValue?["fault"], .string("host_clock_gap"))
            let reset: JSONValue = .object(["instance_id": .string(domain), "generation": generation])
            let acquire: JSONValue = .object(["instance_id": .string(domain), "generation": generation, "owner": .string("new"), "ttl_s": .number(1)])
            for (name, arguments) in [("reset", reset), ("acquire", acquire)] {
                XCTAssertThrowsError(try registry.call("surface_"+domain+"_"+name, arguments: arguments, context: .init(time: 100, controlToken: "next-secret"))) {
                    XCTAssertEqual(($0 as? RemoteFailure)?.code, "stopped")
                }
            }
            XCTAssertEqual(try registry.call("surface_"+domain+"_snapshot", arguments: snapshotArgs, context: .init(time: 100)), snapshot)
            XCTAssertNoThrow(try registry.call("surface_"+domain+"_trace", arguments: snapshotArgs, context: .init(time: 100)))
        }
    }
}
