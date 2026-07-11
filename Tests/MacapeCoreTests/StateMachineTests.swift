import XCTest
import ApplicationServices
@testable import MacapeCore

final class StateMachineTests: XCTestCase {
    private func key(_ code: CGKeyCode, modifier: CGEventFlags = .maskCommand, hold: Int = 200) -> HRKey {
        HRKey(keyCode: code, modifier: modifier, holdTimeoutMs: hold)
    }

    private func handle(
        snapshot: inout PipelineSnapshot,
        layer: LayerConfig = .default,
        swaps: SwapConfig = .empty,
        keyCode: CGKeyCode,
        down: Bool,
        isRepeat: Bool = false,
        userMods: CGEventFlags = [],
        nowMs: UInt64
    ) -> [EngineAction] {
        Pipeline.handleKeyEvent(
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

    private func drive(
        snapshot: inout PipelineSnapshot,
        layer: LayerConfig = .default,
        swaps: SwapConfig = .empty,
        keyCode: CGKeyCode,
        down: Bool,
        isRepeat: Bool = false,
        userMods: CGEventFlags = [],
        nowMs: UInt64
    ) -> KeyEventOutcome {
        let frame = EventFrame(
            machTime: Clock.msToMach(nowMs),
            keyCode: keyCode,
            down: down,
            flags: userMods,
            isRepeat: isRepeat
        )
        return Pipeline.drive(snapshot: &snapshot, layer: layer, swaps: swaps, frame: frame)
    }

    func testTapEmitsOnRelease() {
        var snapshot = PipelineSnapshot(keys: [key(0x00)])
        _ = handle(snapshot: &snapshot, keyCode: 0x00, down: true, nowMs: 1000)
        let actions = handle(snapshot: &snapshot, keyCode: 0x00, down: false, nowMs: 1100)
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(snapshot.keys[0].state, .idle)
    }

    func testHoldPromotesOnTick() {
        var snapshot = PipelineSnapshot(keys: [key(0x00, hold: 100)])
        _ = handle(snapshot: &snapshot, keyCode: 0x00, down: true, nowMs: 1000)
        let actions = Pipeline.tick(
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
        var snapshot = PipelineSnapshot(keys: [
            key(0x00, modifier: .maskCommand, hold: 100),
            key(0x01, modifier: .maskAlternate, hold: 100),
        ])
        _ = handle(snapshot: &snapshot, keyCode: 0x00, down: true, nowMs: 1000)
        _ = handle(snapshot: &snapshot, keyCode: 0x01, down: true, nowMs: 1010)

        _ = Pipeline.tick(
            snapshot: &snapshot,
            layer: LayerConfig.default,
            maxModifierHoldMs: 10_000,
            nowMs: 1200,
            keyIsPhysicallyDown: { _ in true }
        )

        XCTAssertEqual(snapshot.keys[0].state, .modifier)
        XCTAssertEqual(snapshot.keys[1].state, .modifier)
        XCTAssertEqual(Pipeline.activeModifiers(snapshot.keys), [.maskCommand, .maskAlternate])
    }

    func testSpaceLayerEmitsArrowAndReleasesIt() {
        var snapshot = PipelineSnapshot(keys: [key(0x00)])

        let spaceDown = handle(snapshot: &snapshot, keyCode: 49, down: true, nowMs: 1000)
        XCTAssertEqual(spaceDown, [.swallow])
        XCTAssertTrue(snapshot.layerDown)

        let jDown = handle(snapshot: &snapshot, keyCode: 38, down: true, nowMs: 1010)
        XCTAssertTrue(jDown.contains(where: {
            if case .postKey(123, down: true, _, _) = $0 { return true }
            return false
        }))

        let jUp = handle(snapshot: &snapshot, keyCode: 38, down: false, nowMs: 1020)
        XCTAssertTrue(jUp.contains(where: {
            if case .postKey(123, down: false, _, _) = $0 { return true }
            return false
        }))

        let spaceUp = handle(snapshot: &snapshot, keyCode: 49, down: false, nowMs: 1030)
        XCTAssertEqual(spaceUp, [.swallow])
        XCTAssertFalse(snapshot.layerDown)
    }

    func testSpaceLayerDoesNotUsePhysicalKeyStateToCancelSwallowedSpace() {
        var snapshot = PipelineSnapshot(keys: [key(0x00)], layerDown: true)
        _ = Pipeline.tick(
            snapshot: &snapshot,
            layer: LayerConfig.default,
            maxModifierHoldMs: 10_000,
            nowMs: 1100,
            keyIsPhysicallyDown: { _ in false }
        )
        XCTAssertTrue(snapshot.layerDown)
    }

    func testModifierStuckRecoveryUsesMaxHoldTimeout() {
        var snapshot = PipelineSnapshot(keys: [key(0x00)])
        snapshot.keys[0].state = .modifier
        snapshot.keys[0].modifierSinceMach = Clock.msToMach(1000)
        let actions = Pipeline.tick(
            snapshot: &snapshot,
            layer: LayerConfig.default,
            maxModifierHoldMs: 500,
            nowMs: 1600,
            keyIsPhysicallyDown: { _ in true }
        ).actions
        XCTAssertEqual(snapshot.keys[0].state, .idle)
        XCTAssertTrue(actions.contains(where: {
            if case .stuckRecovery = $0 { return true }
            return false
        }))
    }

    func testModifierStuckRecoveryOnPhysicalKeyUpDesync() {
        var snapshot = PipelineSnapshot(keys: [key(0x00)])
        snapshot.keys[0].state = .modifier
        snapshot.keys[0].modifierSinceMach = Clock.msToMach(1000)
        let actions = Pipeline.tick(
            snapshot: &snapshot,
            layer: LayerConfig.default,
            maxModifierHoldMs: 10_000,
            nowMs: 1100,
            keyIsPhysicallyDown: { _ in false }
        ).actions
        XCTAssertEqual(snapshot.keys[0].state, .idle)
        XCTAssertTrue(actions.contains(where: {
            if case .stuckRecovery(_, let reason) = $0 { return reason.contains("desync") }
            return false
        }))
    }

    func testResetAllClearsLayerOwnedKeys() {
        var snapshot = PipelineSnapshot(
            keys: [key(0x00)],
            layerDown: true,
            layerOwnedKeys: [38]
        )
        snapshot.keys[0].state = .modifier
        let actions = Pipeline.resetAll(
            snapshot: &snapshot,
            layer: LayerConfig.default,
            swaps: .empty
        )
        XCTAssertTrue(snapshot.layerOwnedKeys.isEmpty)
        XCTAssertFalse(snapshot.layerDown)
        XCTAssertEqual(snapshot.keys[0].state, .idle)
        XCTAssertTrue(actions.contains(where: {
            if case .postKey(123, down: false, _, _) = $0 { return true }
            return false
        }))
    }

    func testLayerArrowStripsHomeRowModifiers() {
        var snapshot = PipelineSnapshot(keys: [key(40, modifier: .maskControl)])
        snapshot.keys[0].state = .modifier

        _ = handle(snapshot: &snapshot, keyCode: 49, down: true, nowMs: 1000)
        let actions = handle(snapshot: &snapshot, keyCode: 40, down: true, nowMs: 1010)
        XCTAssertTrue(actions.contains(where: {
            if case .postKey(125, down: true, let flags, _) = $0 {
                return !flags.contains(.maskControl)
            }
            return false
        }))
    }

    func testReverseRolloverSwallowedWhenLayerActive() {
        var snapshot = PipelineSnapshot(keys: [key(38)])

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
        var snapshot = PipelineSnapshot(keys: [key(38)])

        _ = handle(snapshot: &snapshot, keyCode: 49, down: true, nowMs: 1000)
        _ = handle(snapshot: &snapshot, keyCode: 38, down: true, nowMs: 1010)
        XCTAssertEqual(snapshot.keys[0].state, .idle)
    }

    func testSwapEmitsTargetKey() {
        var snapshot = PipelineSnapshot(keys: [])
        let swaps = SwapConfig(mappings: [57: 53])

        let down = handle(snapshot: &snapshot, swaps: swaps, keyCode: 57, down: true, nowMs: 1000)
        XCTAssertEqual(down, [.postKey(53, down: true, flags: [], machTime: Clock.msToMach(1000))])
        XCTAssertTrue(snapshot.swapOwnedKeys.contains(57))

        let up = handle(snapshot: &snapshot, swaps: swaps, keyCode: 57, down: false, nowMs: 1010)
        XCTAssertEqual(up, [.postKey(53, down: false, flags: [], machTime: Clock.msToMach(1010))])
        XCTAssertFalse(snapshot.swapOwnedKeys.contains(57))
    }

    func testSwapModifierKey() {
        var snapshot = PipelineSnapshot(keys: [])
        let swaps = SwapConfig(mappings: [54: 59])

        let down = handle(snapshot: &snapshot, swaps: swaps, keyCode: 54, down: true, nowMs: 1000)
        XCTAssertEqual(down, [.postKey(59, down: true, flags: .maskControl, machTime: Clock.msToMach(1000))])

        let up = handle(snapshot: &snapshot, swaps: swaps, keyCode: 54, down: false, nowMs: 1010)
        XCTAssertEqual(up, [.postKey(59, down: false, flags: .maskControl, machTime: Clock.msToMach(1010))])
    }

    func testSwapModifierStripsSourceFlagAndKeepsOthers() {
        var snapshot = PipelineSnapshot(keys: [])
        let swaps = SwapConfig(mappings: [54: 59])

        let solo = handle(snapshot: &snapshot, swaps: swaps, keyCode: 54,
                          down: true, userMods: .maskCommand, nowMs: 1000)
        XCTAssertEqual(solo, [.postKey(59, down: true, flags: .maskControl, machTime: Clock.msToMach(1000))])
        XCTAssertFalse(solo.contains { if case .postKey(_, _, let f, _) = $0 { return f.contains(.maskCommand) }; return false })

        let chord = handle(snapshot: &snapshot, swaps: swaps, keyCode: 54,
                           down: false, userMods: [.maskCommand, .maskShift], nowMs: 1010)
        XCTAssertEqual(chord, [.postKey(59, down: false, flags: [.maskControl, .maskShift], machTime: Clock.msToMach(1010))])
    }

    func testSwapEventFlagsHelper() {
        XCTAssertEqual(
            FeatureRouter.swapEventFlags(source: 54, target: 59, userMods: .maskCommand),
            .maskControl
        )
        XCTAssertEqual(
            FeatureRouter.swapEventFlags(source: 54, target: 59, userMods: [.maskCommand, .maskShift]),
            [.maskControl, .maskShift]
        )
        XCTAssertEqual(
            FeatureRouter.swapEventFlags(source: 57, target: 53, userMods: .maskShift),
            .maskShift
        )
    }

    func testResetAllClearsSwapOwnedKeys() {
        var snapshot = PipelineSnapshot(keys: [], swapOwnedKeys: [57])
        let swaps = SwapConfig(mappings: [57: 53])

        let actions = Pipeline.resetAll(
            snapshot: &snapshot,
            layer: LayerConfig.default,
            swaps: swaps
        )
        XCTAssertTrue(snapshot.swapOwnedKeys.isEmpty)
        XCTAssertTrue(actions.contains(where: {
            if case .postKey(53, down: false, _, _) = $0 { return true }
            return false
        }))
    }

    func testReapPromotesExpiredPendingAndLeavesUnexpiredAlone() {
        var snapshot = PipelineSnapshot(keys: [key(0x00, hold: 100)])
        _ = handle(snapshot: &snapshot, keyCode: 0x00, down: true, nowMs: 1000)

        let early = Pipeline.reapPendingModifiers(snapshot: &snapshot, nowMs: 1050)
        XCTAssertEqual(snapshot.keys[0].state, .pending)
        XCTAssertTrue(early.actions.isEmpty)

        let onTime = Pipeline.reapPendingModifiers(snapshot: &snapshot, nowMs: 1100)
        XCTAssertEqual(snapshot.keys[0].state, .modifier)
        XCTAssertTrue(onTime.actions.isEmpty)
    }

    func testReapNoOpOnIdleAndModifier() {
        var snapshot = PipelineSnapshot(keys: [key(0x00, hold: 100), key(0x01, hold: 100)])
        snapshot.keys[1].state = .modifier
        snapshot.keys[1].modifierSinceMach = Clock.msToMach(1000)

        let actions = Pipeline.reapPendingModifiers(snapshot: &snapshot, nowMs: 99_999)
        XCTAssertEqual(snapshot.keys[0].state, .idle)
        XCTAssertEqual(snapshot.keys[1].state, .modifier)
        XCTAssertTrue(actions.actions.isEmpty)
    }

    func testReapFlushesBufferWithModifierOnPromotion() {
        var snapshot = PipelineSnapshot(keys: [key(0x00, modifier: .maskCommand, hold: 100)])
        _ = handle(snapshot: &snapshot, keyCode: 0x00, down: true, nowMs: 1000)
        _ = handle(snapshot: &snapshot, keyCode: 0x0E, down: true, nowMs: 1050)
        XCTAssertEqual(snapshot.buffer.count, 1)

        let actions = Pipeline.reapPendingModifiers(snapshot: &snapshot, nowMs: 1100)
        XCTAssertEqual(snapshot.keys[0].state, .modifier)
        XCTAssertTrue(snapshot.buffer.isEmpty)
        XCTAssertTrue(actions.actions.contains(where: {
            if case .postKey(0x0E, down: true, let flags, _) = $0 { return flags.contains(.maskCommand) }
            return false
        }))
    }

    func testHoldTapBoundaryIsSharpAtConfiguredTimeout() {
        for hold in stride(from: 50, through: 350, by: 5) {
            var snapshot = PipelineSnapshot(keys: [key(0x00, modifier: .maskCommand, hold: 200)])
            _ = handle(snapshot: &snapshot, keyCode: 0x00, down: true, nowMs: 1000)
            let actions = handle(snapshot: &snapshot, keyCode: 0x00, down: false, nowMs: 1000 + UInt64(hold))

            let emittedLetter = actions.contains(where: {
                if case .postKey(0x00, _, _, _) = $0 { return true }
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

    func testReleaseAtTimeoutDoesNotDropModifierOrStrandQueue() {
        var snapshot = PipelineSnapshot(keys: [key(0x00, modifier: .maskCommand, hold: 200)])
        _ = handle(snapshot: &snapshot, keyCode: 0x00, down: true, nowMs: 1000)
        _ = handle(snapshot: &snapshot, keyCode: 0x0E, down: true, nowMs: 1100)

        let actions = handle(snapshot: &snapshot, keyCode: 0x00, down: false, nowMs: 1200)

        XCTAssertTrue(actions.contains(where: {
            if case .postKey(0x0E, down: true, let flags, _) = $0 { return flags.contains(.maskCommand) }
            return false
        }), "queued 'e' must be emitted with the cmd modifier; got \(actions)")
        XCTAssertEqual(snapshot.keys[0].state, .idle)
        XCTAssertTrue(snapshot.buffer.isEmpty)
    }

    func testTickStillActsAsSafetyNetForIsolatedHold() {
        var snapshot = PipelineSnapshot(keys: [key(0x00, modifier: .maskCommand, hold: 100)])
        _ = handle(snapshot: &snapshot, keyCode: 0x00, down: true, nowMs: 1000)

        _ = Pipeline.tick(
            snapshot: &snapshot,
            layer: LayerConfig.default,
            maxModifierHoldMs: 10_000,
            nowMs: 1300,
            keyIsPhysicallyDown: { _ in true }
        )
        XCTAssertEqual(snapshot.keys[0].state, .modifier)
    }

    // MARK: - New pipeline regression tests

    func testTwoPendingHomeRowKeysBufferFlushesWhenBothResolve() {
        var snapshot = PipelineSnapshot(keys: [
            key(0x00, modifier: .maskCommand, hold: 100),
            key(0x01, modifier: .maskAlternate, hold: 100),
        ])
        _ = handle(snapshot: &snapshot, keyCode: 0x00, down: true, nowMs: 1000)
        _ = handle(snapshot: &snapshot, keyCode: 0x01, down: true, nowMs: 1010)
        _ = handle(snapshot: &snapshot, keyCode: 0x0E, down: true, nowMs: 1020)
        XCTAssertEqual(snapshot.buffer.count, 1)

        _ = handle(snapshot: &snapshot, keyCode: 0x00, down: false, nowMs: 1050)
        XCTAssertEqual(snapshot.buffer.count, 1, "buffer must wait for S to resolve")

        let sUp = handle(snapshot: &snapshot, keyCode: 0x01, down: false, nowMs: 1060)
        XCTAssertTrue(snapshot.buffer.isEmpty)
        XCTAssertTrue(sUp.contains(where: {
            if case .postKey(0x0E, down: true, _, _) = $0 { return true }
            return false
        }))
    }

    func testTimerOnlyPromotionWithNoInterveningEvents() {
        var snapshot = PipelineSnapshot(keys: [key(0x00, hold: 100)])
        _ = handle(snapshot: &snapshot, keyCode: 0x00, down: true, nowMs: 1000)

        let outcome = Pipeline.advanceTime(
            snapshot: &snapshot,
            maxModifierHoldMs: 10_000,
            nowMach: Clock.msToMach(1200),
            keyIsPhysicallyDown: { _ in true }
        )
        XCTAssertEqual(snapshot.keys[0].state, .modifier)
        XCTAssertEqual(outcome.modifierPromotions, 1)
    }

    func testBufferedReplayPreservesMachTimestamp() {
        var snapshot = PipelineSnapshot(keys: [key(0x00, hold: 200)])
        _ = handle(snapshot: &snapshot, keyCode: 0x00, down: true, nowMs: 1000)
        _ = handle(snapshot: &snapshot, keyCode: 0x0E, down: true, nowMs: 1050)

        let actions = handle(snapshot: &snapshot, keyCode: 0x00, down: false, nowMs: 1100)
        let eAction = actions.first(where: {
            if case .postKey(0x0E, _, _, _) = $0 { return true }
            return false
        })
        guard case .postKey(_, _, _, let machTime?) = eAction else {
            return XCTFail("expected buffered e with mach timestamp; got \(String(describing: eAction))")
        }
        XCTAssertEqual(Clock.machToMs(machTime), 1050)
    }

    func testPerKeyTimeoutBoundariesAreIndependent() {
        var snapshot = PipelineSnapshot(keys: [
            key(0x00, modifier: .maskCommand, hold: 180),
            key(0x01, modifier: .maskAlternate, hold: 200),
        ])
        _ = handle(snapshot: &snapshot, keyCode: 0x00, down: true, nowMs: 1000)
        _ = handle(snapshot: &snapshot, keyCode: 0x01, down: true, nowMs: 1000)

        let aUp = handle(snapshot: &snapshot, keyCode: 0x00, down: false, nowMs: 1179)
        XCTAssertTrue(aUp.contains(where: { if case .postKey(0x00, _, _, _) = $0 { return true }; return false }))

        let bUp = handle(snapshot: &snapshot, keyCode: 0x01, down: false, nowMs: 1199)
        XCTAssertTrue(bUp.contains(where: { if case .postKey(0x01, _, _, _) = $0 { return true }; return false }))

        var holdSnapshot = PipelineSnapshot(keys: [
            key(0x00, modifier: .maskCommand, hold: 180),
            key(0x01, modifier: .maskAlternate, hold: 200),
        ])
        _ = handle(snapshot: &holdSnapshot, keyCode: 0x00, down: true, nowMs: 1000)
        _ = handle(snapshot: &holdSnapshot, keyCode: 0x01, down: true, nowMs: 1000)
        let aHold = handle(snapshot: &holdSnapshot, keyCode: 0x00, down: false, nowMs: 1180)
        XCTAssertFalse(aHold.contains(where: { if case .postKey(0x00, _, _, _) = $0 { return true }; return false }))
    }

    func testPipelineDriveMatchesHandleKeyEvent() {
        var snapshotA = PipelineSnapshot(keys: [key(0x00)])
        var snapshotB = PipelineSnapshot(keys: [key(0x00)])

        let outcomeA = drive(snapshot: &snapshotA, keyCode: 0x00, down: true, nowMs: 1000)
        let outcomeB = handle(snapshot: &snapshotB, keyCode: 0x00, down: true, nowMs: 1000)
        XCTAssertEqual(outcomeA.actions, outcomeB)
        XCTAssertEqual(snapshotA, snapshotB)
    }

    // MARK: - Stuck modifier recovery (PLAN-stuck-modifier-cmd-e)

    private func handleWithDesync(
        snapshot: inout PipelineSnapshot,
        layer: LayerConfig = .default,
        swaps: SwapConfig = .empty,
        keyCode: CGKeyCode,
        down: Bool,
        isRepeat: Bool = false,
        userMods: CGEventFlags = [],
        nowMs: UInt64,
        keyIsPhysicallyDown: @escaping (CGKeyCode) -> Bool = { _ in true }
    ) -> KeyEventOutcome {
        let outcome = Pipeline.handleKeyEvent(
            snapshot: &snapshot,
            layer: layer,
            swaps: swaps,
            keyCode: keyCode,
            down: down,
            isRepeat: isRepeat,
            userMods: userMods,
            nowMs: nowMs
        )
        guard TimeWheel.anyModifier(snapshot.keys) else { return outcome }
        let desync = Pipeline.checkModifierDesync(
            snapshot: &snapshot,
            maxModifierHoldMs: 10_000,
            nowMach: Clock.msToMach(nowMs),
            keyIsPhysicallyDown: keyIsPhysicallyDown
        )
        guard !desync.actions.isEmpty else { return outcome }
        return KeyEventOutcome(
            actions: outcome.actions + desync.actions,
            modifierPromotions: outcome.modifierPromotions,
            queueFlushes: outcome.queueFlushes
        )
    }

    func testNextDeadlineMachIncludesModifierWatchdog() {
        var hrKey = key(0x00, hold: 100)
        hrKey.state = .modifier
        hrKey.modifierSinceMach = Clock.msToMach(1000)
        let nowMach = Clock.msToMach(1200)

        let deadline = TimeWheel.nextDeadlineMach(
            [hrKey],
            maxModifierHoldMs: 10_000,
            nowMach: nowMach
        )
        XCTAssertNotNil(deadline)
        XCTAssertGreaterThan(deadline!, nowMach)
    }

    func testModifierDesyncRecoversViaTimerWithoutPendingKeys() {
        var snapshot = PipelineSnapshot(keys: [key(0x00)])
        snapshot.keys[0].state = .modifier
        snapshot.keys[0].modifierSinceMach = Clock.msToMach(1000)

        let outcome = Pipeline.tick(
            snapshot: &snapshot,
            layer: LayerConfig.default,
            maxModifierHoldMs: 10_000,
            nowMs: 1100,
            keyIsPhysicallyDown: { _ in false }
        )
        XCTAssertEqual(snapshot.keys[0].state, .idle)
        XCTAssertTrue(outcome.actions.contains(where: {
            if case .stuckRecovery = $0 { return true }
            return false
        }))
    }

    func testModifierDesyncRecoversOnNextKeyEvent() {
        var snapshot = PipelineSnapshot(keys: [key(0x00, hold: 100)])
        _ = handle(snapshot: &snapshot, keyCode: 0x00, down: true, nowMs: 1000)
        _ = Pipeline.tick(
            snapshot: &snapshot,
            layer: LayerConfig.default,
            maxModifierHoldMs: 10_000,
            nowMs: 1200,
            keyIsPhysicallyDown: { _ in true }
        )
        _ = handle(snapshot: &snapshot, keyCode: 0x0E, down: true, nowMs: 1250)
        _ = handle(snapshot: &snapshot, keyCode: 0x0E, down: false, nowMs: 1260)
        XCTAssertEqual(snapshot.keys[0].state, .modifier)

        let outcome = handleWithDesync(
            snapshot: &snapshot,
            keyCode: 49,
            down: true,
            nowMs: 1300,
            keyIsPhysicallyDown: { code in code == 0x00 ? false : true }
        )
        XCTAssertEqual(snapshot.keys[0].state, .idle)
        XCTAssertTrue(outcome.actions.contains(where: {
            if case .stuckRecovery(0x00, let reason) = $0 { return reason.contains("desync") }
            return false
        }))
    }

    func testCmdEThenSpaceDoesNotEmitCmdSpace() {
        var snapshot = PipelineSnapshot(keys: [key(0x00, hold: 100)])
        _ = handle(snapshot: &snapshot, keyCode: 0x00, down: true, nowMs: 1000)
        _ = Pipeline.tick(
            snapshot: &snapshot,
            layer: LayerConfig.default,
            maxModifierHoldMs: 10_000,
            nowMs: 1200,
            keyIsPhysicallyDown: { _ in true }
        )
        _ = handle(snapshot: &snapshot, keyCode: 0x0E, down: true, nowMs: 1250)
        _ = handle(snapshot: &snapshot, keyCode: 0x0E, down: false, nowMs: 1260)
        _ = handle(snapshot: &snapshot, keyCode: 0x00, down: false, nowMs: 1270)

        _ = handle(snapshot: &snapshot, keyCode: 49, down: true, nowMs: 1300)
        let spaceUp = handle(snapshot: &snapshot, keyCode: 49, down: false, nowMs: 1310)

        let spaceActions = spaceUp.filter {
            if case .postKey = $0 { return true }
            return false
        }
        XCTAssertFalse(spaceActions.contains(where: {
            if case .postKey(_, _, let flags, _) = $0 { return flags.contains(.maskCommand) }
            return false
        }))
    }

    func testCmdEThenLostAUpSpaceDoesNotStick() {
        var snapshot = PipelineSnapshot(keys: [key(0x00, hold: 100)])
        _ = handle(snapshot: &snapshot, keyCode: 0x00, down: true, nowMs: 1000)
        _ = Pipeline.tick(
            snapshot: &snapshot,
            layer: LayerConfig.default,
            maxModifierHoldMs: 10_000,
            nowMs: 1200,
            keyIsPhysicallyDown: { _ in true }
        )
        _ = handle(snapshot: &snapshot, keyCode: 0x0E, down: true, nowMs: 1250)
        _ = handle(snapshot: &snapshot, keyCode: 0x0E, down: false, nowMs: 1260)
        XCTAssertEqual(snapshot.keys[0].state, .modifier)

        _ = handleWithDesync(
            snapshot: &snapshot,
            keyCode: 49,
            down: true,
            nowMs: 1300,
            keyIsPhysicallyDown: { code in code == 0x00 ? false : true }
        )
        let spaceUp = handle(snapshot: &snapshot, keyCode: 49, down: false, nowMs: 1310)

        XCTAssertEqual(snapshot.keys[0].state, .idle)
        XCTAssertFalse(Pipeline.activeModifiers(snapshot.keys).contains(.maskCommand))
        XCTAssertFalse(spaceUp.contains(where: {
            if case .postKey(49, _, let flags, _) = $0 { return flags.contains(.maskCommand) }
            return false
        }))
    }

    func testTier5HomeRowUpClearsModifierState() {
        var snapshot = PipelineSnapshot(keys: [key(0x00)])
        snapshot.keys[0].state = .modifier
        snapshot.keys[0].modifierSinceMach = Clock.msToMach(1000)

        _ = handle(
            snapshot: &snapshot,
            keyCode: 0x00,
            down: false,
            userMods: .maskCommand,
            nowMs: 1100
        )
        XCTAssertEqual(snapshot.keys[0].state, .idle)
        XCTAssertFalse(Pipeline.activeModifiers(snapshot.keys).contains(.maskCommand))
    }
}
