import XCTest
import ApplicationServices
@testable import MacapeCore

final class StateMachineTests: XCTestCase {
    private func key(_ code: CGKeyCode, modifier: CGEventFlags = .maskCommand, hold: Int = 200) -> HRKey {
        HRKey(keyCode: code, modifier: modifier, holdTimeoutMs: hold, tapTimeoutMs: 200)
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
        )
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
        )
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
        )
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
}
