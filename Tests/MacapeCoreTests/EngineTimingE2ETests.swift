import XCTest
import ApplicationServices
@testable import MacapeCore

/// End-to-end timing tests.
///
/// The unit tests in `StateMachineTests` drive the state machine with synthetic
/// integer timestamps. These tests exercise the *real* integration that the
/// timing bug lived in:
///
///   real CGEvent  --(.timestamp, mach-absolute)-->  Clock.eventMs()
///                                                       |
///                                          handleKeyEvent(nowMs:)
///                                                       |
///                                          tap vs hold classification
///
/// They build genuine `CGEvent` keyDown/keyUp objects, stamp their `.timestamp`
/// with real `mach_absolute_time()` values (and real wall-clock sleeps), and run
/// them through the *production* timestamp-extraction + state-machine path. This
/// catches:
///   • CGEvent.timestamp round-trip / settable-ness bugs
///   • mach→ms timebase conversion bugs (would make a real 200 ms hold read as
///     ~120 ms or ~300 ms — the exact reported symptom)
///   • the hold/tap boundary landing at the configured timeout over real time
final class EngineTimingE2ETests: XCTestCase {

    private func makeSnapshot(holdMs: Int = 200) -> StateMachineSnapshot {
        StateMachineSnapshot(keys: [
            HRKey(keyCode: 0x00, modifier: .maskCommand, holdTimeoutMs: holdMs)
        ])
    }

    /// Build a real CGEvent and stamp its `.timestamp` with a mach-absolute
    /// value `ms` milliseconds after `epoch`. Returns (event, extractedMs).
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

    // MARK: - Clock sanity (the foundation the fix rests on)

    func testClockMachToMsRoundTrip() {
        // 1000 ms must survive ms->mach->ms.
        let mach = Clock.msToMach(1000)
        XCTAssertEqual(Clock.machToMs(mach), 1000)
    }

    func testCGEventTimestampIsSettableAndReadable() {
        // If CGEvent.timestamp weren't settable/readable, the whole
        // event-timestamp strategy would be undermined. Guard it.
        let src = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(keyboardEventSource: src, virtualKey: 0x00, keyDown: true)!
        let stamp = mach_absolute_time()
        event.timestamp = stamp
        XCTAssertEqual(event.timestamp, stamp, "CGEvent.timestamp must round-trip the mach value we set")
    }

    func testClockEventMsMatchesSetTimestamp() {
        // Setting a mach timestamp on a real CGEvent and reading it back through
        // the production Clock.eventMs must give the expected ms.
        let src = CGEventSource(stateID: .hidSystemState)
        let epoch = Clock.msToMach(5_000_000) // arbitrary large epoch in mach
        let event = makeStampedEvent(virtualKey: 0x00, keyDown: true, epochMach: epoch, offsetMs: 250, source: src)
        XCTAssertEqual(Clock.eventMs(event) - Clock.machToMs(epoch), 250, accuracy: 1)
    }

    // MARK: - Hold/tap boundary over SYNTHESIZED real timestamps

    func testHoldTapBoundaryWithRealCGEventTimestamps() {
        // Sweep hold durations across the configured 200 ms boundary using real
        // CGEvent.timestamp values. Classification must match the configured
        // timeout exactly — this is the direct regression for "200ms reads as
        // 120ms / 300ms".
        let src = CGEventSource(stateID: .hidSystemState)
        let epoch = mach_absolute_time()

        for holdMs in stride(from: 40, through: 360, by: 5) {
            var snapshot = makeSnapshot(holdMs: 200)

            let down = makeStampedEvent(virtualKey: 0x00, keyDown: true, epochMach: epoch, offsetMs: 0, source: src)
            let up = makeStampedEvent(virtualKey: 0x00, keyDown: false, epochMach: epoch, offsetMs: UInt64(holdMs), source: src)

            let _ = HomeRowStateMachine.handleKeyEvent(
                snapshot: &snapshot, layer: .default, swaps: .empty,
                keyCode: 0x00, down: true, isRepeat: false, userMods: [],
                nowMs: Clock.eventMs(down)
            )
            let outcome = HomeRowStateMachine.handleKeyEvent(
                snapshot: &snapshot, layer: .default, swaps: .empty,
                keyCode: 0x00, down: false, isRepeat: false, userMods: [],
                nowMs: Clock.eventMs(up)
            )

            let emittedLetter = outcome.actions.contains { action in
                if case .postKey(0x00, _, _) = action { return true }
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
        // Queue path: press 'e' BEFORE A's hold timeout elapses, so it parks in
        // the queue. Then hold A past the timeout and release it. The reap that
        // runs at A-up must promote A and flush the queued 'e' with .maskCommand.
        // This is the real-timestamp regression for Problem D (stranded queue).
        let src = CGEventSource(stateID: .hidSystemState)
        let epoch = mach_absolute_time()
        var snapshot = makeSnapshot(holdMs: 100)

        func drive(_ vk: CGKeyCode, down: Bool, offsetMs: UInt64) -> KeyEventOutcome {
            let event = makeStampedEvent(virtualKey: vk, keyDown: down, epochMach: epoch, offsetMs: offsetMs, source: src)
            return HomeRowStateMachine.handleKeyEvent(
                snapshot: &snapshot, layer: .default, swaps: .empty,
                keyCode: vk, down: down, isRepeat: false, userMods: [],
                nowMs: Clock.eventMs(event)
            )
        }

        _ = drive(0x00, down: true, offsetMs: 0)    // A down  @0ms   -> pending
        let eDown = drive(0x0E, down: true, offsetMs: 50)  // e down @50ms  -> queued (before timeout)
        XCTAssertEqual(snapshot.queue.count, 1, "'e' pressed before timeout must be queued")
        XCTAssertTrue(eDown.actions.allSatisfy { if case .swallow = $0 { return true }; return false },
                      "queued key press itself emits nothing yet")

        let aUp = drive(0x00, down: false, offsetMs: 150) // A up   @150ms -> reap promotes A, flushes queue

        // The queued 'e' key-down must be flushed with the cmd modifier.
        let eDownWithCmd = aUp.actions.contains {
            if case .postKey(0x0E, down: true, let flags) = $0 { return flags.contains(.maskCommand) }
            return false
        }
        XCTAssertTrue(eDownWithCmd, "queued 'e' key-down must be flushed with the cmd modifier; got \(aUp.actions)")
        XCTAssertTrue(snapshot.queue.isEmpty, "queue must be drained after flush")
        XCTAssertEqual(snapshot.keys[0].state, .idle)
    }

    func testKeyAfterLiveModifierPassedThroughWithFlagOverRealTimestamps() {
        // Ideal path: hold A past its timeout so reap promotes it to a live
        // modifier, THEN press 'e'. 'e' arrives while A is already a modifier,
        // so it is passed through in-flight with cmd applied (no queueing, no
        // added latency). Validates the common shortcut case over real timestamps.
        let src = CGEventSource(stateID: .hidSystemState)
        let epoch = mach_absolute_time()
        var snapshot = makeSnapshot(holdMs: 100)

        func drive(_ vk: CGKeyCode, down: Bool, offsetMs: UInt64) -> KeyEventOutcome {
            let event = makeStampedEvent(virtualKey: vk, keyDown: down, epochMach: epoch, offsetMs: offsetMs, source: src)
            return HomeRowStateMachine.handleKeyEvent(
                snapshot: &snapshot, layer: .default, swaps: .empty,
                keyCode: vk, down: down, isRepeat: false, userMods: [],
                nowMs: Clock.eventMs(event)
            )
        }

        _ = drive(0x00, down: true, offsetMs: 0)    // A down @0ms
        // 'e' arrives at 120ms: reap-on-event promotes A (120>=100) first.
        let eDown = drive(0x0E, down: true, offsetMs: 120)
        let passedThroughWithCmd = eDown.actions.contains {
            if case .passThrough(let flags) = $0 { return flags.contains(.maskCommand) }
            return false
        }
        XCTAssertTrue(passedThroughWithCmd,
                      "'e' pressed after A is a live modifier must pass through with cmd; got \(eDown.actions)")
        XCTAssertEqual(snapshot.keys[0].state, .modifier, "A must be promoted by the time 'e' is handled")
    }

    // MARK: - Hold/tap boundary over REAL wall-clock time

    func testRealWallClockShortTapIsATap() {
        // Actually sleep ~80 ms between down and up. Confirms mach_absolute_time
        // correlates with wall clock as expected (a timebase bug would misread
        // this duration). 80 ms must be a tap for a 200 ms threshold.
        let src = CGEventSource(stateID: .hidSystemState)
        var snapshot = makeSnapshot(holdMs: 200)

        let down = CGEvent(keyboardEventSource: src, virtualKey: 0x00, keyDown: true)!
        down.timestamp = mach_absolute_time()
        _ = HomeRowStateMachine.handleKeyEvent(
            snapshot: &snapshot, layer: .default, swaps: .empty,
            keyCode: 0x00, down: true, isRepeat: false, userMods: [],
            nowMs: Clock.eventMs(down)
        )

        usleep(80_000) // 80 ms real wall-clock

        let up = CGEvent(keyboardEventSource: src, virtualKey: 0x00, keyDown: false)!
        up.timestamp = mach_absolute_time()
        let outcome = HomeRowStateMachine.handleKeyEvent(
            snapshot: &snapshot, layer: .default, swaps: .empty,
            keyCode: 0x00, down: false, isRepeat: false, userMods: [],
            nowMs: Clock.eventMs(up)
        )

        XCTAssertTrue(outcome.actions.contains { if case .postKey(0x00, _, _) = $0 { return true }; return false },
                      "an 80 ms real tap must emit the letter")
        XCTAssertEqual(snapshot.keys[0].state, .idle)
    }

    func testRealWallClockLongHoldIsAModifier() {
        // Actually sleep ~250 ms between down and up. Must classify as a hold
        // (modifier) for a 200 ms threshold — no letter emitted.
        let src = CGEventSource(stateID: .hidSystemState)
        var snapshot = makeSnapshot(holdMs: 200)

        let down = CGEvent(keyboardEventSource: src, virtualKey: 0x00, keyDown: true)!
        down.timestamp = mach_absolute_time()
        _ = HomeRowStateMachine.handleKeyEvent(
            snapshot: &snapshot, layer: .default, swaps: .empty,
            keyCode: 0x00, down: true, isRepeat: false, userMods: [],
            nowMs: Clock.eventMs(down)
        )

        usleep(250_000) // 250 ms real wall-clock

        let up = CGEvent(keyboardEventSource: src, virtualKey: 0x00, keyDown: false)!
        up.timestamp = mach_absolute_time()
        let outcome = HomeRowStateMachine.handleKeyEvent(
            snapshot: &snapshot, layer: .default, swaps: .empty,
            keyCode: 0x00, down: false, isRepeat: false, userMods: [],
            nowMs: Clock.eventMs(up)
        )

        XCTAssertFalse(outcome.actions.contains { if case .postKey(0x00, _, _) = $0 { return true }; return false },
                       "a 250 ms real hold must NOT emit the letter (it's a modifier)")
        XCTAssertEqual(snapshot.keys[0].state, .idle)
    }
}
