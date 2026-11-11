import XCTest
import SurfacePluginContracts
import SurfacePluginConformance
import AgentPlugin

final class AgentTests: XCTestCase {
    func primary(_ id: Int = 1, origin: InputOrigin = .hardware) -> PluginInput {
        .invoke(.init(pluginID: AgentPlugin.pluginID, actionID: AgentPlugin.primaryActionID, index: id), origin: origin)
    }
    func started(slotCount: Int = 8, policy: AgentApprovalPolicy = .anyOrigin) throws -> AgentPlugin {
        var p = try AgentPlugin(slotCount: slotCount, approvalPolicy: policy)
        _ = try p.handle(.start, at: 0)
        return p
    }
    func testAll49TransitionPairs() throws {
        let permitted: Set<String> = ["idle:queued", "completed:queued", "interrupted:queued", "error:queued", "queued:running", "queued:interrupted", "running:waitingApproval", "running:completed", "running:interrupted", "waitingApproval:running", "waitingApproval:interrupted"]
        for old in AgentRunState.allCases {
            for new in AgentRunState.allCases {
                let expected = old == new || new == .error || permitted.contains("\(old.rawValue):\(new.rawValue)")
                XCTAssertEqual(AgentStateMachine.allows(from: old, to: new), expected, "\(old):\(new)")
                var machine = try AgentStateMachine(slotCount: 1)
                if old != .idle {
                    try machine.transition(1, to: .queued, at: 0)
                    if old != .queued {
                        try machine.transition(1, to: .running, at: 0)
                        if old != .running { try machine.transition(1, to: old, at: 0) }
                    }
                }
                let before = machine.slots
                if expected { XCTAssertNoThrow(try machine.transition(1, to: new, at: 1)) }
                else { XCTAssertThrowsError(try machine.transition(1, to: new, at: 1)); XCTAssertEqual(machine.slots, before) }
            }
        }
    }
    func testInitialTimelineEveryStageAndBoundary() throws {
        var p = try started()
        let queued = try p.handle(primary(), at: 0)
        XCTAssertEqual(queued.events.first?.fields["progress"], .double(0))
        let stages: [(Double, Double, AgentRunState, String)] = [
            (0.45,0.08,.running,"agent.mock.analyze"), (1,0.20,.running,"agent.mock.context"),
            (1.55,0.34,.running,"agent.mock.plan"), (2.10,0.48,.running,"agent.mock.patch"),
            (2.65,0.60,.waitingApproval,"agent.mock.awaitingApproval")]
        var previous = 0.0
        for (time, progress, state, key) in stages {
            _ = try p.handle(.advance, at: time - 0.0001)
            XCTAssertEqual(p.slots[0].progress, previous)
            let update = try p.handle(.advance, at: time)
            XCTAssertEqual(p.slots[0].state, state); XCTAssertEqual(p.slots[0].progress, progress)
            XCTAssertEqual(p.slots[0].statusKey, key); XCTAssertEqual(p.slots[0].lastUpdated, time)
            if time == 2.65 {
                XCTAssertEqual(update.events.count, 2)
                XCTAssertEqual(update.events[0].fields["progress"], .double(0.58))
                XCTAssertEqual(update.events[0].fields["statusKey"], .string("agent.mock.prepare"))
            }
            previous = progress
        }
    }
    func testApprovalTimelineEveryStage() throws {
        var p = try started()
        _ = try p.handle(primary(), at: 0); _ = try p.handle(.advance, at: 3)
        _ = try p.handle(primary(), at: 10)
        XCTAssertEqual(p.slots[0].progress, 0.64); XCTAssertEqual(p.slots[0].statusKey, "agent.mock.approved")
        for (time, progress, key) in [(10.6,0.72,"agent.mock.test"), (11.2,0.84,"agent.mock.build"), (11.8,0.94,"agent.mock.summarize"), (12.25,1.0,"agent.mock.completed")] {
            _ = try p.handle(.advance, at: time)
            XCTAssertEqual(p.slots[0].progress, progress); XCTAssertEqual(p.slots[0].statusKey, key)
            XCTAssertEqual(p.slots[0].lastUpdated, time, accuracy: 1e-12)
        }
        XCTAssertEqual(p.slots[0].state, .completed)
        _ = try p.handle(primary(), at: 13); XCTAssertEqual(p.slots[0].state, .queued)
    }
    func testLargeJumpPreservesAllEventsAndApprovalWait() throws {
        var p = try started()
        _ = try p.handle(primary(), at: 0)
        let update = try p.handle(.advance, at: 100)
        XCTAssertEqual(update.events.map { $0.fields["progress"] }, [0.08,0.20,0.34,0.48,0.58,0.60].map(JSONValue.double))
        XCTAssertEqual(p.slots[0].state, .waitingApproval)
        XCTAssertTrue(try p.handle(.advance, at: 200).events.isEmpty)
        _ = try p.handle(primary(), at: 200)
        XCTAssertEqual(try p.handle(.advance, at: 300).events.count, 4)
        XCTAssertEqual(p.slots[0].state, .completed)
    }
    func testPrimaryInterruptsQueuedAndRunningAndCancelsSchedule() throws {
        for advance in [false, true] {
            var p = try started(); _ = try p.handle(primary(), at: 0)
            if advance { _ = try p.handle(.advance, at: 1) }
            _ = try p.handle(primary(), at: 2)
            XCTAssertEqual(p.slots[0].state, .interrupted)
            XCTAssertTrue(try p.handle(.advance, at: 100).events.isEmpty)
            _ = try p.handle(primary(), at: 101); XCTAssertEqual(p.slots[0].state, .queued)
        }
    }
    func testApprovalPolicyAndAtomicRejection() throws {
        var p = try started(policy: .interfaceOnly)
        _ = try p.handle(primary(), at: 0); _ = try p.handle(.advance, at: 3)
        let before = p.slots
        for origin in [InputOrigin.hardware, .remote] {
            XCTAssertThrowsError(try p.handle(primary(origin: origin), at: 100)) { XCTAssertEqual(($0 as? PluginError)?.code, .permissionDenied) }
            XCTAssertEqual(p.slots, before)
        }
        _ = try p.handle(primary(origin: .interface), at: 4)
        XCTAssertEqual(p.slots[0].state, .running)
    }
    func testConformance() throws {
        try PluginConformance.check(make: { try AgentPlugin(slotCount: 2) }, sequence: [
            .init(.start, at: 0), .init(primary(), at: 0), .init(.advance, at: 3), .init(primary(), at: 4), .init(.advance, at: 8), .init(.stop, at: 9)],
            unknownAction: .invoke(.init(pluginID: "agent", actionID: "agent.unknown"), origin: .hardware),
            outOfRange: primary(3), writeAfterStop: primary())
    }
    func testConfigurationAndInvalidInputs() throws {
        XCTAssertThrowsError(try AgentPlugin(slotCount: 0)); XCTAssertThrowsError(try AgentPlugin(slotCount: -1))
        XCTAssertThrowsError(try AgentPlugin(at: .infinity))
        var p = try started(slotCount: 12)
        XCTAssertEqual(p.slots.count, 12); _ = try p.handle(primary(12), at: 0)
        for id in [0,-1,13,Int.max] { XCTAssertThrowsError(try p.handle(primary(id), at: 0)) }
        XCTAssertThrowsError(try p.handle(.parameterChanged("agent.unknown", .nan, origin: .remote), at: 0))
        let old = p.slots
        for t in [Double.nan, .infinity, -.infinity, -1] { XCTAssertThrowsError(try p.handle(.advance, at: t)); XCTAssertEqual(p.slots, old) }
    }
    func testStopInterruptsAllActiveSlotsAndRestartDoesNotResume() throws {
        var p = try started(slotCount: 2)
        _ = try p.handle(primary(1), at: 0); _ = try p.handle(.advance, at: 3)
        _ = try p.handle(primary(2), at: 3)
        _ = try p.handle(.stop, at: 4)
        XCTAssertTrue(p.slots.allSatisfy { $0.state == .interrupted })
        XCTAssertThrowsError(try p.handle(primary(), at: 5))
        _ = try p.handle(.start, at: 5); _ = try p.handle(.advance, at: 100)
        XCTAssertTrue(p.slots.allSatisfy { $0.state == .interrupted })
    }
    func testAbsoluteDeadlineAtNonzeroAndLargeAnchors() throws {
        for anchor in [10.0, 1_000_000.0] {
            var p = try started()
            _ = try p.handle(primary(), at: anchor)
            for (offset, progress) in [(0.45,0.08), (1.0,0.20), (1.55,0.34), (2.10,0.48), (2.65,0.60)] {
                _ = try p.handle(.advance, at: anchor + offset)
                XCTAssertEqual(p.slots[0].progress, progress)
            }
            let approval = anchor + 3
            _ = try p.handle(primary(), at: approval)
            for (offset, progress) in [(0.60,0.72), (1.20,0.84), (1.80,0.94), (2.25,1.0)] {
                _ = try p.handle(.advance, at: approval + offset)
                XCTAssertEqual(p.slots[0].progress, progress)
            }
        }
    }
    func testExplicitInterruptDoesNotApproveOrAffectOtherSlots() throws {
        var p = try started(slotCount: 2)
        _ = try p.handle(primary(1), at: 0)
        _ = try p.handle(.advance, at: 3)
        _ = try p.handle(primary(2), at: 3)
        _ = try p.interrupt(1, at: 3)
        XCTAssertEqual(p.slots[0].state, .interrupted)
        XCTAssertEqual(p.slots[1].state, .queued)
        XCTAssertTrue(try p.interrupt(1, at: 3).events.isEmpty)
        _ = try p.handle(.advance, at: 6)
        XCTAssertEqual(p.slots[0].state, .interrupted)
        XCTAssertEqual(p.slots[1].state, .waitingApproval)
        let before = p.slots
        XCTAssertThrowsError(try p.interrupt(3, at: 100))
        XCTAssertThrowsError(try p.interrupt(2, at: .nan))
        XCTAssertEqual(p.slots, before)
        _ = try p.interrupt(2, at: 6)
        XCTAssertEqual(p.slots[1].state, .interrupted)
        _ = try p.handle(.stop, at: 6)
        XCTAssertThrowsError(try p.interrupt(1, at: 6))
    }
    func testStateMachineInvalidProgressAndTimesAreAtomic() throws {
        var m = try AgentStateMachine(slotCount: 1)
        XCTAssertThrowsError(try m.updateProgress(1, progress: 0.5, statusKey: "x", at: 0))
        try m.transition(1, to: .queued, at: 1); try m.transition(1, to: .running, at: 2)
        let before = m.slots
        XCTAssertThrowsError(try m.transition(1, to: .error, progress: .nan, at: 3))
        XCTAssertThrowsError(try m.transition(1, to: .error, at: 1))
        XCTAssertThrowsError(try m.transition(2, to: .error, at: 3))
        XCTAssertEqual(m.slots, before)
        try m.updateProgress(1, progress: 99, statusKey: "x", at: 3)
        XCTAssertEqual(m.slots[0].progress, 1)
        XCTAssertEqual(Set(AgentRunState.allCases.map(\.indicatorSemantic)), Set(IndicatorSemantic.allCases))
    }
}
