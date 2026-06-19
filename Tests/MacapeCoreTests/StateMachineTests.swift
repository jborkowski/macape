import XCTest
import ApplicationServices
@testable import MacapeCore

final class StateMachineTests: XCTestCase {
    private func key(_ code: CGKeyCode, modifier: CGEventFlags = .maskCommand, hold: Int = 200) -> HRKey {
        HRKey(keyCode: code, modifier: modifier, holdTimeoutMs: hold)
    }

    private func handle(
        snapshot: inout StateMachineSnapshot,
        layer: LayerConfig = .default,
        swaps: SwapConfig = .empty,
        keyCode: CGKeyCode,
        down: Bool,
        isRepeat: Bool = false,
        userMods: CGEventFlags = [],
        nowMs: UInt64
    ) -> [EngineAction] {
        HomeRowStateMachine.handleKeyEvent(
            snapshot: &snapshot,
            layer: layer,
            swaps: swaps,
            keyCode: keyCode,
            down: down,
            isRepeat: isRepeat,
            userMods: userMods,
            nowMs: nowMs
        ).actions
    }

    func testTapEmitsOnRelease() {
        var snapshot = StateMachineSnapshot(keys: [key(0x00)])
        _ = handle(snapshot: &snapshot, keyCode: 0x00, down: true, nowMs: 1000)
        let actions = handle(snapshot: &snapshot, keyCode: 0x00, down: false, nowMs: 1100)
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(snapshot.keys[0].state, .idle)
    }

    func testHoldPromotesOnTick() {
        var snapshot = StateMachineSnapshot(keys: [key(0x00, hold: 100)])
        _ = handle(snapshot: &snapshot, keyCode: 0x00, down: true, nowMs: 1000)
        let actions = HomeRowStateMachine.tick(
            snapshot: &snapshot,
            layer: LayerConfig.default,
            maxModifierHoldMs: 10_000,
            nowMs: 1200,
            keyIsPhysicallyDown: { _ in true }
        ).actions
        XCTAssertEqual(snapshot.keys[0].state, .modifier)
        XCTAssertTrue(actions.isEmpty || actions.contains(where: {
            if case .postKey = $0 { return true }
            return false
        }))
    }

    func testMultipleHomeRowKeysCanPromoteTogether() {
        var snapshot = StateMachineSnapshot(keys: [
            key(0x00, modifier: .maskCommand, hold: 100),
            key(0x01, modifier: .maskAlternate, hold: 100),
        ])
        _ = handle(snapshot: &snapshot, keyCode: 0x00, down: true, nowMs: 1000)
        _ = handle(snapshot: &snapshot, keyCode: 0x01, down: true, nowMs: 1010)

        _ = HomeRowStateMachine.tick(
            snapshot: &snapshot,
            layer: LayerConfig.default,
            maxModifierHoldMs: 10_000,
            nowMs: 1200,
            keyIsPhysicallyDown: { _ in true }
        )

        XCTAssertEqual(snapshot.keys[0].state, .modifier)
        XCTAssertEqual(snapshot.keys[1].state, .modifier)
        XCTAssertEqual(HomeRowStateMachine.activeModifiers(snapshot.keys), [.maskCommand, .maskAlternate])
    }

    func testSpaceLayerEmitsArrowAndReleasesIt() {
        var snapshot = StateMachineSnapshot(keys: [key(0x00)])

        let spaceDown = handle(snapshot: &snapshot, keyCode: 49, down: true, nowMs: 1000)
        XCTAssertEqual(spaceDown, [.swallow])
        XCTAssertTrue(snapshot.layerDown)

        let jDown = handle(snapshot: &snapshot, keyCode: 38, down: true, nowMs: 1010)
        XCTAssertTrue(jDown.contains(where: {
            if case .postKey(123, down: true, _) = $0 { return true }
            return false
        }))

        let jUp = handle(snapshot: &snapshot, keyCode: 38, down: false, nowMs: 1020)
        XCTAssertTrue(jUp.contains(where: {
            if case .postKey(123, down: false, _) = $0 { return true }
            return false
        }))

        let spaceUp = handle(snapshot: &snapshot, keyCode: 49, down: false, nowMs: 1030)
        XCTAssertEqual(spaceUp, [.swallow])
        XCTAssertFalse(snapshot.layerDown)
    }

    func testSpaceLayerDoesNotUsePhysicalKeyStateToCancelSwallowedSpace() {
        var snapshot = StateMachineSnapshot(keys: [key(0x00)], layerDown: true)
        _ = HomeRowStateMachine.tick(
            snapshot: &snapshot,
            layer: LayerConfig.default,
            maxModifierHoldMs: 10_000,
            nowMs: 1100,
            keyIsPhysicallyDown: { _ in false }
        )
        XCTAssertTrue(snapshot.layerDown)
    }

    func testModifierStuckRecoveryUsesMaxHoldTimeout() {
        var snapshot = StateMachineSnapshot(keys: [key(0x00)])
        snapshot.keys[0].state = .modifier
        snapshot.keys[0].modifierSinceMs = 1000
        let actions = HomeRowStateMachine.tick(
            snapshot: &snapshot,
            layer: LayerConfig.default,
            maxModifierHoldMs: 500,
            nowMs: 1600,
            keyIsPhysicallyDown: { _ in false }
        ).actions
        XCTAssertEqual(snapshot.keys[0].state, .idle)
        XCTAssertTrue(actions.contains(where: {
            if case .stuckRecovery = $0 { return true }
            return false
        }))
    }

    func testResetAllClearsLayerOwnedKeys() {
        var snapshot = StateMachineSnapshot(
            keys: [key(0x00)],
            layerDown: true,
            layerOwnedKeys: [38]
        )
        snapshot.keys[0].state = .modifier
        let actions = HomeRowStateMachine.resetAll(
            snapshot: &snapshot,
            layer: LayerConfig.default,
            swaps: .empty
        )
        XCTAssertTrue(snapshot.layerOwnedKeys.isEmpty)
        XCTAssertFalse(snapshot.layerDown)
        XCTAssertEqual(snapshot.keys[0].state, .idle)
        XCTAssertTrue(actions.contains(where: {
            if case .postKey(123, down: false, _) = $0 { return true }
            return false
        }))
    }

    func testLayerArrowStripsHomeRowModifiers() {
        var snapshot = StateMachineSnapshot(keys: [key(40, modifier: .maskControl)])
        snapshot.keys[0].state = .modifier

        _ = handle(snapshot: &snapshot, keyCode: 49, down: true, nowMs: 1000)
        let actions = handle(snapshot: &snapshot, keyCode: 40, down: true, nowMs: 1010)
        XCTAssertTrue(actions.contains(where: {
            if case .postKey(125, down: true, let flags) = $0 {
                return !flags.contains(.maskControl)
            }
            return false
        }))
    }

    func testReverseRolloverSwallowedWhenLayerActive() {
        var snapshot = StateMachineSnapshot(keys: [key(38)])

        let jDown = handle(snapshot: &snapshot, keyCode: 38, down: true, nowMs: 1000)
        XCTAssertEqual(jDown, [.swallow])
        XCTAssertEqual(snapshot.keys[0].state, .pending)

        _ = handle(snapshot: &snapshot, keyCode: 49, down: true, nowMs: 1010)

        let jUp = handle(snapshot: &snapshot, keyCode: 38, down: false, nowMs: 1020)
        XCTAssertEqual(jUp, [.swallow])
        XCTAssertFalse(jUp.contains(where: {
            if case .postKey = $0 { return true }
            return false
        }))
        XCTAssertEqual(snapshot.keys[0].state, .idle)
    }

    func testLayerClaimClearsHomeRowState() {
        var snapshot = StateMachineSnapshot(keys: [key(38)])

        _ = handle(snapshot: &snapshot, keyCode: 49, down: true, nowMs: 1000)
        _ = handle(snapshot: &snapshot, keyCode: 38, down: true, nowMs: 1010)
        XCTAssertEqual(snapshot.keys[0].state, .idle)
    }

    func testSwapEmitsTargetKey() {
        var snapshot = StateMachineSnapshot(keys: [])
        let swaps = SwapConfig(mappings: [57: 53]) // caps_lock -> escape

        let down = handle(snapshot: &snapshot, swaps: swaps, keyCode: 57, down: true, nowMs: 1000)
        XCTAssertEqual(down, [.postKey(53, down: true, flags: [])])
        XCTAssertTrue(snapshot.swapOwnedKeys.contains(57))

        let up = handle(snapshot: &snapshot, swaps: swaps, keyCode: 57, down: false, nowMs: 1010)
        XCTAssertEqual(up, [.postKey(53, down: false, flags: [])])
        XCTAssertFalse(snapshot.swapOwnedKeys.contains(57))
    }

    func testSwapModifierKey() {
        var snapshot = StateMachineSnapshot(keys: [])
        let swaps = SwapConfig(mappings: [54: 59]) // right_command -> left_control

        let down = handle(snapshot: &snapshot, swaps: swaps, keyCode: 54, down: true, nowMs: 1000)
        XCTAssertEqual(down, [.postKey(59, down: true, flags: [])])

        let up = handle(snapshot: &snapshot, swaps: swaps, keyCode: 54, down: false, nowMs: 1010)
        XCTAssertEqual(up, [.postKey(59, down: false, flags: [])])
    }

    func testResetAllClearsSwapOwnedKeys() {
        var snapshot = StateMachineSnapshot(keys: [], swapOwnedKeys: [57])
        let swaps = SwapConfig(mappings: [57: 53])

        let actions = HomeRowStateMachine.resetAll(
            snapshot: &snapshot,
            layer: LayerConfig.default,
            swaps: swaps
        )
        XCTAssertTrue(snapshot.swapOwnedKeys.isEmpty)
        XCTAssertTrue(actions.contains(where: {
            if case .postKey(53, down: false, _) = $0 { return true }
            return false
        }))
    }

    // MARK: - Reap (authoritative event-driven promotion)

    func testReapPromotesExpiredPendingAndLeavesUnexpiredAlone() {
        var snapshot = StateMachineSnapshot(keys: [key(0x00, hold: 100)])
        _ = handle(snapshot: &snapshot, keyCode: 0x00, down: true, nowMs: 1000)

        // Before timeout: no promotion.
        let early = HomeRowStateMachine.reapPendingModifiers(snapshot: &snapshot, nowMs: 1050)
        XCTAssertEqual(snapshot.keys[0].state, .pending)
        XCTAssertTrue(early.actions.isEmpty)

        // At/after timeout: promote, and flush the (empty) queue.
        let onTime = HomeRowStateMachine.reapPendingModifiers(snapshot: &snapshot, nowMs: 1100)
        XCTAssertEqual(snapshot.keys[0].state, .modifier)
        XCTAssertTrue(onTime.actions.isEmpty) // empty queue → no emitted actions
    }

    func testReapNoOpOnIdleAndModifier() {
        var snapshot = StateMachineSnapshot(keys: [key(0x00, hold: 100), key(0x01, hold: 100)])
        snapshot.keys[1].state = .modifier
        snapshot.keys[1].modifierSinceMs = 1000

        let actions = HomeRowStateMachine.reapPendingModifiers(snapshot: &snapshot, nowMs: 99_999)
        XCTAssertEqual(snapshot.keys[0].state, .idle)
        XCTAssertEqual(snapshot.keys[1].state, .modifier)
        XCTAssertTrue(actions.actions.isEmpty)
    }

    func testReapFlushesQueueWithModifierOnPromotion() {
        var snapshot = StateMachineSnapshot(keys: [key(0x00, modifier: .maskCommand, hold: 100)])
        _ = handle(snapshot: &snapshot, keyCode: 0x00, down: true, nowMs: 1000)
        // Non-home-row key pressed while pending -> queued.
        _ = handle(snapshot: &snapshot, keyCode: 0x0E, down: true, nowMs: 1050) // 'e'
        XCTAssertEqual(snapshot.queue.count, 1)

        let actions = HomeRowStateMachine.reapPendingModifiers(snapshot: &snapshot, nowMs: 1100)
        XCTAssertEqual(snapshot.keys[0].state, .modifier)
        XCTAssertTrue(snapshot.queue.isEmpty)
        XCTAssertTrue(actions.actions.contains(where: {
            if case .postKey(0x0E, down: true, let flags) = $0 { return flags.contains(.maskCommand) }
            return false
        }))
    }

    // MARK: - Hold/tap boundary (Problem A + B)

    func testHoldTapBoundaryIsSharpAtConfiguredTimeout() {
        // The fix measures duration from hardware event timestamps, so the
        // boundary lands exactly at the configured timeout regardless of when
        // the OS delivered the callbacks.
        for hold in stride(from: 50, through: 350, by: 5) {
            var snapshot = StateMachineSnapshot(keys: [key(0x00, modifier: .maskCommand, hold: 200)])
            _ = handle(snapshot: &snapshot, keyCode: 0x00, down: true, nowMs: 1000)
            let actions = handle(snapshot: &snapshot, keyCode: 0x00, down: false, nowMs: 1000 + UInt64(hold))

            let emittedLetter = actions.contains(where: {
                if case .postKey(0x00, _, _) = $0 { return true }
                return false
            })
            if hold < 200 {
                XCTAssertTrue(emittedLetter, "hold=\(hold)ms (< 200) should be a tap and emit the letter")
                XCTAssertEqual(snapshot.keys[0].state, .idle)
            } else {
                XCTAssertFalse(emittedLetter, "hold=\(hold)ms (>= 200) should be a modifier and emit NO letter")
                XCTAssertEqual(snapshot.keys[0].state, .idle)
            }
        }
    }

    // MARK: - Release-at-timeout race (Problem D regression)

    func testReleaseAtTimeoutDoesNotDropModifierOrStrandQueue() {
        // Before the fix, releasing exactly at the timeout with no intervening
        // timer tick hit a branch that swallowed the key and left the queue
        // stranded (queued key-up emitted with no matching key-down, and the
        // intended modifier silently lost).
        var snapshot = StateMachineSnapshot(keys: [key(0x00, modifier: .maskCommand, hold: 200)])
        _ = handle(snapshot: &snapshot, keyCode: 0x00, down: true, nowMs: 1000)
        // Queue a non-home-row key while A is pending.
        _ = handle(snapshot: &snapshot, keyCode: 0x0E, down: true, nowMs: 1100) // 'e'

        // Release exactly at the timeout, WITHOUT a tick in between.
        let actions = handle(snapshot: &snapshot, keyCode: 0x00, down: false, nowMs: 1200)

        // Reap-on-release promotes A and flushes the queue with cmd applied.
        XCTAssertTrue(actions.contains(where: {
            if case .postKey(0x0E, down: true, let flags) = $0 { return flags.contains(.maskCommand) }
            return false
        }), "queued 'e' must be emitted with the cmd modifier; got \(actions)")
        XCTAssertEqual(snapshot.keys[0].state, .idle)
        XCTAssertTrue(snapshot.queue.isEmpty)
    }

    func testTickStillActsAsSafetyNetForIsolatedHold() {
        // A key held with no further events must still promote via the timer.
        var snapshot = StateMachineSnapshot(keys: [key(0x00, modifier: .maskCommand, hold: 100)])
        _ = handle(snapshot: &snapshot, keyCode: 0x00, down: true, nowMs: 1000)

        _ = HomeRowStateMachine.tick(
            snapshot: &snapshot,
            layer: LayerConfig.default,
            maxModifierHoldMs: 10_000,
            nowMs: 1300,
            keyIsPhysicallyDown: { _ in true }
        )
        XCTAssertEqual(snapshot.keys[0].state, .modifier)
    }
}
