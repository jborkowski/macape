import XCTest
import ApplicationServices
@testable import MacapeCore

final class StateMachineTests: XCTestCase {
    private func key(_ code: CGKeyCode, modifier: CGEventFlags = .maskCommand, hold: Int = 200) -> HRKey {
        HRKey(keyCode: code, modifier: modifier, holdTimeoutMs: hold, tapTimeoutMs: 200)
    }

    func testTapEmitsOnRelease() {
        var snapshot = StateMachineSnapshot(keys: [key(0x00)])
        let layer = LayerConfig.default
        _ = HomeRowStateMachine.handleKeyEvent(
            snapshot: &snapshot,
            layer: layer,
            keyCode: 0x00,
            down: true,
            isRepeat: false,
            userMods: [],
            nowMs: 1000
        )
        let actions = HomeRowStateMachine.handleKeyEvent(
            snapshot: &snapshot,
            layer: layer,
            keyCode: 0x00,
            down: false,
            isRepeat: false,
            userMods: [],
            nowMs: 1100
        )
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(snapshot.keys[0].state, .idle)
    }

    func testHoldPromotesOnTick() {
        var snapshot = StateMachineSnapshot(keys: [key(0x00, hold: 100)])
        let layer = LayerConfig.default
        _ = HomeRowStateMachine.handleKeyEvent(
            snapshot: &snapshot,
            layer: layer,
            keyCode: 0x00,
            down: true,
            isRepeat: false,
            userMods: [],
            nowMs: 1000
        )
        let actions = HomeRowStateMachine.tick(
            snapshot: &snapshot,
            layer: layer,
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
        let layer = LayerConfig.default
        _ = HomeRowStateMachine.handleKeyEvent(
            snapshot: &snapshot,
            layer: layer,
            keyCode: 0x00,
            down: true,
            isRepeat: false,
            userMods: [],
            nowMs: 1000
        )
        _ = HomeRowStateMachine.handleKeyEvent(
            snapshot: &snapshot,
            layer: layer,
            keyCode: 0x01,
            down: true,
            isRepeat: false,
            userMods: [],
            nowMs: 1010
        )

        _ = HomeRowStateMachine.tick(
            snapshot: &snapshot,
            layer: layer,
            maxModifierHoldMs: 10_000,
            nowMs: 1200,
            keyIsPhysicallyDown: { _ in true }
        )

        XCTAssertEqual(snapshot.keys[0].state, .modifier)
        XCTAssertEqual(snapshot.keys[1].state, .modifier)
        XCTAssertEqual(HomeRowStateMachine.activeModifiers(snapshot.keys), [.maskCommand, .maskAlternate])
    }

    func testStuckRecoveryWhenKeyUpMissed() {
        var snapshot = StateMachineSnapshot(keys: [key(0x00)])
        snapshot.keys[0].state = .modifier
        snapshot.keys[0].modifierSinceMs = 1000
        let actions = HomeRowStateMachine.tick(
            snapshot: &snapshot,
            layer: LayerConfig.default,
            maxModifierHoldMs: 10_000,
            nowMs: 1500,
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
        let actions = HomeRowStateMachine.resetAll(snapshot: &snapshot, layer: LayerConfig.default)
        XCTAssertTrue(snapshot.layerOwnedKeys.isEmpty)
        XCTAssertFalse(snapshot.layerDown)
        XCTAssertEqual(snapshot.keys[0].state, .idle)
        XCTAssertTrue(actions.contains(where: {
            if case .postKey(123, down: false, _) = $0 { return true }
            return false
        }))
    }
}
