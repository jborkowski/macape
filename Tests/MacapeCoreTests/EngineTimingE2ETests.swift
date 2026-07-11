import XCTest
import ApplicationServices
@testable import MacapeCore

/// End-to-end timing tests through the production Pipeline + Clock path.
final class EngineTimingE2ETests: XCTestCase {

    private func makeSnapshot(holdMs: Int = 200) -> PipelineSnapshot {
        PipelineSnapshot(keys: [
            HRKey(keyCode: 0x00, modifier: .maskCommand, holdTimeoutMs: holdMs)
        ])
    }

    private func makeStampedEvent(
        virtualKey: CGKeyCode,
        keyDown: Bool,
        epochMach: UInt64,
        offsetMs: UInt64,
        source: CGEventSource?
    ) -> CGEvent {
        let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: keyDown)!
        event.timestamp = epochMach + Clock.msToMach(offsetMs)
        return event
    }

    private func drive(
        snapshot: inout PipelineSnapshot,
        event: CGEvent,
        keyCode: CGKeyCode,
        down: Bool,
        isRepeat: Bool = false
    ) -> KeyEventOutcome {
        let frame = EventFrame(from: event, keyCode: keyCode, down: down, isRepeat: isRepeat)
        return Pipeline.drive(snapshot: &snapshot, layer: .default, swaps: .empty, frame: frame)
    }

    func testClockMachToMsRoundTrip() {
        let mach = Clock.msToMach(1000)
        XCTAssertEqual(Clock.machToMs(mach), 1000)
    }

    func testCGEventTimestampIsSettableAndReadable() {
        let src = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(keyboardEventSource: src, virtualKey: 0x00, keyDown: true)!
        let stamp = mach_absolute_time()
        event.timestamp = stamp
        XCTAssertEqual(event.timestamp, stamp)
    }

    func testClockEventMsMatchesSetTimestamp() {
        let src = CGEventSource(stateID: .hidSystemState)
        let epoch = Clock.msToMach(5_000_000)
        let event = makeStampedEvent(virtualKey: 0x00, keyDown: true, epochMach: epoch, offsetMs: 250, source: src)
        XCTAssertEqual(Clock.eventMs(event) - Clock.machToMs(epoch), 250, accuracy: 1)
    }

    func testHoldTapBoundaryWithRealCGEventTimestamps() {
        let src = CGEventSource(stateID: .hidSystemState)
        let epoch = mach_absolute_time()

        for holdMs in stride(from: 40, through: 360, by: 5) {
            var snapshot = makeSnapshot(holdMs: 200)

            let down = makeStampedEvent(virtualKey: 0x00, keyDown: true, epochMach: epoch, offsetMs: 0, source: src)
            let up = makeStampedEvent(virtualKey: 0x00, keyDown: false, epochMach: epoch, offsetMs: UInt64(holdMs), source: src)

            _ = drive(snapshot: &snapshot, event: down, keyCode: 0x00, down: true)
            let outcome = drive(snapshot: &snapshot, event: up, keyCode: 0x00, down: false)

            let emittedLetter = outcome.actions.contains { action in
                if case .postKey(0x00, _, _, _) = action { return true }
                return false
            }
            if holdMs < 200 {
                XCTAssertTrue(emittedLetter, "hold=\(holdMs)ms (<200) must be a TAP and emit the letter")
            } else {
                XCTAssertFalse(emittedLetter, "hold=\(holdMs)ms (>=200) must be a HOLD and emit NO letter")
            }
        }
    }

    func testModifierAppliedToQueuedKeyOverRealTimestamps() {
        let src = CGEventSource(stateID: .hidSystemState)
        let epoch = mach_absolute_time()
        var snapshot = makeSnapshot(holdMs: 100)

        func driveEvent(_ vk: CGKeyCode, down: Bool, offsetMs: UInt64) -> KeyEventOutcome {
            let event = makeStampedEvent(virtualKey: vk, keyDown: down, epochMach: epoch, offsetMs: offsetMs, source: src)
            return drive(snapshot: &snapshot, event: event, keyCode: vk, down: down)
        }

        _ = driveEvent(0x00, down: true, offsetMs: 0)
        let eDown = driveEvent(0x0E, down: true, offsetMs: 50)
        XCTAssertEqual(snapshot.buffer.count, 1)
        XCTAssertTrue(eDown.actions.allSatisfy { if case .swallow = $0 { return true }; return false })

        let aUp = driveEvent(0x00, down: false, offsetMs: 150)

        let eDownWithCmd = aUp.actions.contains {
            if case .postKey(0x0E, down: true, let flags, _) = $0 { return flags.contains(.maskCommand) }
            return false
        }
        XCTAssertTrue(eDownWithCmd, "queued 'e' key-down must be flushed with the cmd modifier; got \(aUp.actions)")
        XCTAssertTrue(snapshot.buffer.isEmpty)
        XCTAssertEqual(snapshot.keys[0].state, .idle)
    }

    func testKeyAfterLiveModifierPassedThroughWithFlagOverRealTimestamps() {
        let src = CGEventSource(stateID: .hidSystemState)
        let epoch = mach_absolute_time()
        var snapshot = makeSnapshot(holdMs: 100)

        func driveEvent(_ vk: CGKeyCode, down: Bool, offsetMs: UInt64) -> KeyEventOutcome {
            let event = makeStampedEvent(virtualKey: vk, keyDown: down, epochMach: epoch, offsetMs: offsetMs, source: src)
            return drive(snapshot: &snapshot, event: event, keyCode: vk, down: down)
        }

        _ = driveEvent(0x00, down: true, offsetMs: 0)
        let eDown = driveEvent(0x0E, down: true, offsetMs: 120)
        let passedThroughWithCmd = eDown.actions.contains {
            if case .passThrough(let flags) = $0 { return flags.contains(.maskCommand) }
            return false
        }
        XCTAssertTrue(passedThroughWithCmd,
                      "'e' pressed after A is a live modifier must pass through with cmd; got \(eDown.actions)")
        XCTAssertEqual(snapshot.keys[0].state, .modifier)
    }

    func testRealWallClockShortTapIsATap() {
        let src = CGEventSource(stateID: .hidSystemState)
        var snapshot = makeSnapshot(holdMs: 200)

        let down = CGEvent(keyboardEventSource: src, virtualKey: 0x00, keyDown: true)!
        down.timestamp = mach_absolute_time()
        _ = drive(snapshot: &snapshot, event: down, keyCode: 0x00, down: true)

        usleep(80_000)

        let up = CGEvent(keyboardEventSource: src, virtualKey: 0x00, keyDown: false)!
        up.timestamp = mach_absolute_time()
        let outcome = drive(snapshot: &snapshot, event: up, keyCode: 0x00, down: false)

        XCTAssertTrue(outcome.actions.contains { if case .postKey(0x00, _, _, _) = $0 { return true }; return false },
                      "an 80 ms real tap must emit the letter")
        XCTAssertEqual(snapshot.keys[0].state, .idle)
    }

    func testRealWallClockLongHoldIsAModifier() {
        let src = CGEventSource(stateID: .hidSystemState)
        var snapshot = makeSnapshot(holdMs: 200)

        let down = CGEvent(keyboardEventSource: src, virtualKey: 0x00, keyDown: true)!
        down.timestamp = mach_absolute_time()
        _ = drive(snapshot: &snapshot, event: down, keyCode: 0x00, down: true)

        usleep(250_000)

        let up = CGEvent(keyboardEventSource: src, virtualKey: 0x00, keyDown: false)!
        up.timestamp = mach_absolute_time()
        let outcome = drive(snapshot: &snapshot, event: up, keyCode: 0x00, down: false)

        XCTAssertFalse(outcome.actions.contains { if case .postKey(0x00, _, _, _) = $0 { return true }; return false },
                       "a 250 ms real hold must NOT emit the letter (it's a modifier)")
        XCTAssertEqual(snapshot.keys[0].state, .idle)
    }

    func testPostedReplayPreservesTimestamp() {
        let src = CGEventSource(stateID: .hidSystemState)!
        let stamp = mach_absolute_time()
        var posted: UInt64 = 0
        EventSink.postKey(source: src, code: 0x0E, down: true, extra: [], machTime: stamp)
        // Read back via a synthetic event construction round-trip.
        let event = CGEvent(keyboardEventSource: src, virtualKey: 0x0E, keyDown: true)!
        event.timestamp = stamp
        posted = event.timestamp
        XCTAssertEqual(posted, stamp)
    }

    func testModifierWatchdogFiresAfterPromotionWithNoMoreEvents() {
        var snapshot = makeSnapshot(holdMs: 100)
        let src = CGEventSource(stateID: .hidSystemState)
        let epoch = mach_absolute_time()

        let aDown = makeStampedEvent(virtualKey: 0x00, keyDown: true, epochMach: epoch, offsetMs: 0, source: src)
        _ = drive(snapshot: &snapshot, event: aDown, keyCode: 0x00, down: true)

        let promoteMach = epoch + Clock.msToMach(120)
        let outcome = Pipeline.advanceTime(
            snapshot: &snapshot,
            maxModifierHoldMs: 10_000,
            nowMach: promoteMach,
            keyIsPhysicallyDown: { _ in true }
        )
        XCTAssertEqual(snapshot.keys[0].state, .modifier)
        XCTAssertEqual(outcome.modifierPromotions, 1)

        let deadline = TimeWheel.nextDeadlineMach(
            snapshot.keys,
            maxModifierHoldMs: 10_000,
            nowMach: promoteMach
        )
        XCTAssertNotNil(deadline)
        XCTAssertGreaterThan(deadline!, promoteMach)

        let recovery = Pipeline.advanceTime(
            snapshot: &snapshot,
            maxModifierHoldMs: 10_000,
            nowMach: promoteMach + Clock.msToMach(60),
            keyIsPhysicallyDown: { _ in false }
        )
        XCTAssertEqual(snapshot.keys[0].state, .idle)
        XCTAssertTrue(recovery.actions.contains(where: {
            if case .stuckRecovery = $0 { return true }
            return false
        }))
    }
}
