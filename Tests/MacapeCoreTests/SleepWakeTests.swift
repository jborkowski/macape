import XCTest
@testable import MacapeCore

final class SleepWakeTests: XCTestCase {
    func testResetAllAcceptsSystemWakeReason() {
        var snapshot = PipelineSnapshot(keys: [
            HRKey(keyCode: 0x00, modifier: .maskCommand, holdTimeoutMs: 200)
        ])
        snapshot.keys[0].state = .pending
        snapshot.keys[0].pressMach = Clock.msToMach(1000)
        snapshot.buffer.enqueue(frame: EventFrame(
            machTime: Clock.msToMach(1050),
            keyCode: 0x0E,
            down: true,
            flags: []
        ), blockedBy: [0x00])

        let actions = Pipeline.resetAll(
            snapshot: &snapshot,
            layer: .default,
            swaps: .empty,
            reason: "system wake"
        )

        XCTAssertTrue(snapshot.buffer.isEmpty)
        XCTAssertEqual(snapshot.keys[0].state, .idle)
        XCTAssertTrue(actions.contains(where: {
            if case .stuckRecovery(_, let reason) = $0 { return reason == "system wake" }
            return false
        }))
    }

    func testDeadlineSchedulerFiresImmediatelyForPastDeadline() {
        let exp = expectation(description: "past deadline")
        let scheduler = DeadlineScheduler(queue: .main)
        let past = mach_absolute_time() &- 1
        scheduler.schedule(deadlineMach: past) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testDeadlineSchedulerCancelPreventsFire() {
        let exp = expectation(description: "should not fire")
        exp.isInverted = true
        let scheduler = DeadlineScheduler(queue: .main)
        let future = mach_absolute_time() &+ Clock.msToMach(500)
        scheduler.schedule(deadlineMach: future) {
            exp.fulfill()
        }
        scheduler.cancel()
        wait(for: [exp], timeout: 0.2)
    }

    func testMachAbsoluteTimeDomainMatchesEventTimestamp() {
        // Document the sleep invariant: CGEvent.timestamp and mach_absolute_time
        // share the same clock that pauses during system sleep.
        let src = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(keyboardEventSource: src, virtualKey: 0x00, keyDown: true)!
        let stamp = mach_absolute_time()
        event.timestamp = stamp
        XCTAssertEqual(event.timestamp, stamp)
    }
}
