import Foundation
import ApplicationServices

public enum FeatureRouter {
    public static let modifierKeyFlags: [CGKeyCode: CGEventFlags] = [
        54: .maskCommand, 55: .maskCommand,
        59: .maskControl, 62: .maskControl,
        58: .maskAlternate, 61: .maskAlternate,
        56: .maskShift, 60: .maskShift,
    ]

    public static func swapTarget(_ swaps: SwapConfig, _ keyCode: CGKeyCode) -> CGKeyCode? {
        swaps.mappings[keyCode]
    }

    public static func swapEventFlags(
        source keyCode: CGKeyCode,
        target dst: CGKeyCode,
        userMods: CGEventFlags
    ) -> CGEventFlags {
        var flags = userMods
        if let sourceFlag = modifierKeyFlags[keyCode] {
            flags.subtract(sourceFlag)
        }
        if let targetFlag = modifierKeyFlags[dst] {
            flags.formUnion(targetFlag)
        }
        return flags
    }

    public static func layerArrow(_ layer: LayerConfig, _ keyCode: CGKeyCode, layerDown: Bool) -> CGKeyCode? {
        guard layerDown else { return nil }
        return layer.mappings[keyCode]
    }
}

public enum Pipeline {
    public static func drive(
        snapshot: inout PipelineSnapshot,
        layer: LayerConfig,
        swaps: SwapConfig,
        frame: EventFrame
    ) -> KeyEventOutcome {
        process(
            snapshot: &snapshot,
            layer: layer,
            swaps: swaps,
            frame: frame
        )
    }

    public static func process(
        snapshot: inout PipelineSnapshot,
        layer: LayerConfig,
        swaps: SwapConfig,
        frame: EventFrame
    ) -> KeyEventOutcome {
        var metricsPromotions = 0
        var metricsFlushes = 0
        var actions: [EngineAction] = []

        func outcome(
            _ newActions: [EngineAction],
            extraPromotions: Int = 0,
            extraFlushes: Int = 0
        ) -> KeyEventOutcome {
            KeyEventOutcome(
                actions: newActions,
                modifierPromotions: metricsPromotions + extraPromotions,
                queueFlushes: metricsFlushes + extraFlushes
            )
        }

        guard snapshot.enabled else {
            let mods = TimeWheel.activeModifiers(snapshot.keys)
            return outcome(mods.isEmpty ? [.passThrough(flags: [])] : [.passThrough(flags: mods)])
        }

        let advance = TimeWheel.advance(
            keys: &snapshot.keys,
            buffer: &snapshot.buffer,
            nowMach: frame.machTime
        )
        actions.append(contentsOf: advance.actions)
        metricsPromotions = advance.promotedCount
        metricsFlushes = advance.flushedBuffer ? 1 : 0

        let keyCode = frame.keyCode
        let down = frame.down
        let isRepeat = frame.isRepeat
        let userMods = frame.userMods
        let hrIdx = snapshot.keys.firstIndex(where: { $0.keyCode == keyCode })

        // Tier 2: instant key swap
        if let dst = FeatureRouter.swapTarget(swaps, keyCode) {
            let swapFlags = FeatureRouter.swapEventFlags(source: keyCode, target: dst, userMods: userMods)
            if down {
                if isRepeat { return outcome(actions + [.swallow]) }
                snapshot.swapOwnedKeys.insert(keyCode)
                return outcome(actions + [.postKey(dst, down: true, flags: swapFlags, machTime: frame.machTime)])
            }
            if snapshot.swapOwnedKeys.contains(keyCode) {
                snapshot.swapOwnedKeys.remove(keyCode)
                return outcome(actions + [.postKey(dst, down: false, flags: swapFlags, machTime: frame.machTime)])
            }
            return outcome(actions + [.swallow])
        }

        // Tier 3: layer hold key
        if keyCode == layer.holdKeyCode, userMods.isEmpty {
            if down {
                if isRepeat { return outcome(actions + [.swallow]) }
                snapshot.layerDown = true
                snapshot.layerConsumed = false
                return outcome(actions + [.swallow])
            }
            if !snapshot.layerDown {
                return outcome(actions + [.passThrough(flags: TimeWheel.activeModifiers(snapshot.keys))])
            }
            snapshot.layerDown = false
            if snapshot.layerConsumed {
                snapshot.layerConsumed = false
                return outcome(actions + [.swallow])
            }
            actions.append(.postKey(layer.holdKeyCode, down: true, flags: userMods, machTime: frame.machTime))
            actions.append(.postKey(layer.holdKeyCode, down: false, flags: userMods, machTime: frame.machTime))
            return outcome(actions)
        }

        // Tier 4: active layer claim
        if let arrowCode = FeatureRouter.layerArrow(layer, keyCode, layerDown: snapshot.layerDown) {
            if down {
                snapshot.layerConsumed = true
                snapshot.layerOwnedKeys.insert(keyCode)
                if let idx = hrIdx, snapshot.keys[idx].state != .idle {
                    clearHomeRowState(snapshot: &snapshot, at: idx)
                }
                actions.append(.postKey(arrowCode, down: true, flags: userMods, machTime: frame.machTime))
                return outcome(actions)
            }
            if snapshot.layerOwnedKeys.contains(keyCode) {
                snapshot.layerOwnedKeys.remove(keyCode)
                actions.append(.postKey(arrowCode, down: false, flags: userMods, machTime: frame.machTime))
                return outcome(actions)
            }
            if let idx = hrIdx, snapshot.keys[idx].state != .idle {
                clearHomeRowState(snapshot: &snapshot, at: idx)
            }
            return outcome(actions + [.swallow])
        }

        // Tier 5: real physical modifiers over a home-row key
        if !userMods.isEmpty, let idx = hrIdx {
            if !down, snapshot.keys[idx].state != .idle {
                clearHomeRowState(snapshot: &snapshot, at: idx)
            }
            return outcome(actions + [.passThrough(flags: userMods.union(TimeWheel.activeModifiers(snapshot.keys)))])
        }

        // Tier 6: home-row tap/hold resolution
        if let idx = hrIdx {
            if down {
                if isRepeat { return outcome(actions + [.swallow]) }
                if snapshot.keys[idx].state != .idle { return outcome(actions + [.swallow]) }
                snapshot.keys[idx].state = .pending
                snapshot.keys[idx].pressMach = frame.machTime
                snapshot.keys[idx].deadlineMach = frame.machTime &+ Clock.msToMach(UInt64(snapshot.keys[idx].holdTimeoutMs))
                return outcome(actions + [.swallow])
            }

            switch snapshot.keys[idx].state {
            case .pending:
                if frame.machTime >= snapshot.keys[idx].deadlineMach {
                    // Hold release at/after deadline: advance already promoted; clear on release.
                    snapshot.keys[idx].state = .idle
                    snapshot.keys[idx].pressMach = 0
                    snapshot.keys[idx].deadlineMach = 0
                    snapshot.keys[idx].modifierSinceMach = 0
                    return outcome(actions.isEmpty ? [.swallow] : actions)
                }

                snapshot.keys[idx].state = .idle
                snapshot.keys[idx].pressMach = 0
                snapshot.keys[idx].deadlineMach = 0
                let mods = TimeWheel.activeModifiers(snapshot.keys)
                actions.append(.postKey(keyCode, down: true, flags: mods, machTime: frame.machTime))
                actions.append(.postKey(keyCode, down: false, flags: mods, machTime: frame.machTime))
                var flushedBuffer = false
                if !TimeWheel.anyPending(snapshot.keys) {
                    let flush = snapshot.buffer.flushAll(modifiers: mods)
                    actions.append(contentsOf: flush.actions)
                    flushedBuffer = flush.flushed
                } else {
                    let flush = snapshot.buffer.resolveBlocker(keyCode, modifiers: mods)
                    actions.append(contentsOf: flush.actions)
                    flushedBuffer = flush.flushed
                }
                return outcome(actions, extraFlushes: flushedBuffer ? 1 : 0)

            case .modifier:
                snapshot.keys[idx].state = .idle
                snapshot.keys[idx].pressMach = 0
                snapshot.keys[idx].deadlineMach = 0
                snapshot.keys[idx].modifierSinceMach = 0
                return outcome(actions.isEmpty ? [.swallow] : actions)

            case .idle:
                if TimeWheel.anyPending(snapshot.keys) {
                    snapshot.buffer.enqueue(frame: EventFrame(
                        machTime: frame.machTime,
                        keyCode: keyCode,
                        down: false,
                        flags: frame.flags
                    ), blockedBy: TimeWheel.pendingKeyCodes(snapshot.keys))
                    return outcome(actions + [.swallow])
                }
                return outcome(actions + [.passThrough(flags: userMods.union(TimeWheel.activeModifiers(snapshot.keys)))])
            }
        }

        // Tier 7: buffer / pass through
        if TimeWheel.anyPending(snapshot.keys) {
            snapshot.buffer.enqueue(frame: frame, blockedBy: TimeWheel.pendingKeyCodes(snapshot.keys))
            return outcome(actions + [.swallow])
        }

        let mods = TimeWheel.activeModifiers(snapshot.keys)
        return outcome(actions + (mods.isEmpty
            ? [.passThrough(flags: userMods)]
            : [.passThrough(flags: userMods.union(mods))]))
    }

    public static func checkModifierDesync(
        snapshot: inout PipelineSnapshot,
        maxModifierHoldMs: Int,
        nowMach: UInt64,
        keyIsPhysicallyDown: (CGKeyCode) -> Bool
    ) -> KeyEventOutcome {
        var actions: [EngineAction] = []

        for i in snapshot.keys.indices {
            let key = snapshot.keys[i]
            guard key.state == .modifier else { continue }

            if maxModifierHoldMs > 0,
               key.modifierSinceMach > 0,
               nowMach >= key.modifierSinceMach,
               nowMach &- key.modifierSinceMach >= Clock.msToMach(UInt64(maxModifierHoldMs)) {
                snapshot.keys[i].state = .idle
                snapshot.keys[i].modifierSinceMach = 0
                actions.append(.stuckRecovery(key: key.keyCode, reason: "max modifier hold"))
                continue
            }

            if !keyIsPhysicallyDown(key.keyCode) {
                snapshot.keys[i].state = .idle
                snapshot.keys[i].modifierSinceMach = 0
                actions.append(.stuckRecovery(key: key.keyCode, reason: "physical key up desync"))
            }
        }

        return KeyEventOutcome(actions: actions)
    }

    public static func advanceTime(
        snapshot: inout PipelineSnapshot,
        maxModifierHoldMs: Int,
        nowMach: UInt64,
        keyIsPhysicallyDown: (CGKeyCode) -> Bool
    ) -> KeyEventOutcome {
        let advance = TimeWheel.advance(
            keys: &snapshot.keys,
            buffer: &snapshot.buffer,
            nowMach: nowMach
        )
        var outcome = checkModifierDesync(
            snapshot: &snapshot,
            maxModifierHoldMs: maxModifierHoldMs,
            nowMach: nowMach,
            keyIsPhysicallyDown: keyIsPhysicallyDown
        )
        outcome.actions = advance.actions + outcome.actions
        outcome.modifierPromotions = advance.promotedCount
        outcome.queueFlushes = advance.flushedBuffer ? 1 : 0
        return outcome
    }

    public static func resetAll(
        snapshot: inout PipelineSnapshot,
        layer: LayerConfig,
        swaps: SwapConfig,
        reason: String = "reset"
    ) -> [EngineAction] {
        var actions: [EngineAction] = []
        for owned in snapshot.swapOwnedKeys {
            if let dst = swaps.mappings[owned] {
                actions.append(.postKey(dst, down: false, flags: [], machTime: nil))
            }
        }
        snapshot.swapOwnedKeys.removeAll()
        for owned in snapshot.layerOwnedKeys {
            if let arrow = layer.mappings[owned] {
                actions.append(.postKey(arrow, down: false, flags: [], machTime: nil))
            }
        }
        snapshot.layerOwnedKeys.removeAll()
        snapshot.layerDown = false
        snapshot.layerConsumed = false
        snapshot.buffer.removeAll()
        for i in snapshot.keys.indices where snapshot.keys[i].state != .idle {
            actions.append(.stuckRecovery(key: snapshot.keys[i].keyCode, reason: reason))
            snapshot.keys[i].state = .idle
            snapshot.keys[i].pressMach = 0
            snapshot.keys[i].deadlineMach = 0
            snapshot.keys[i].modifierSinceMach = 0
        }
        return actions
    }

    private static func clearHomeRowState(snapshot: inout PipelineSnapshot, at idx: Int) {
        snapshot.keys[idx].state = .idle
        snapshot.keys[idx].pressMach = 0
        snapshot.keys[idx].deadlineMach = 0
        snapshot.keys[idx].modifierSinceMach = 0
    }
}

// Backward-compatible aliases for tests migrating from HomeRowStateMachine.
public typealias HomeRowStateMachine = Pipeline

public extension Pipeline {
    static func handleKeyEvent(
        snapshot: inout PipelineSnapshot,
        layer: LayerConfig,
        swaps: SwapConfig,
        keyCode: CGKeyCode,
        down: Bool,
        isRepeat: Bool,
        userMods: CGEventFlags,
        nowMs: UInt64
    ) -> KeyEventOutcome {
        let frame = EventFrame(
            machTime: Clock.msToMach(nowMs),
            keyCode: keyCode,
            down: down,
            flags: userMods,
            isRepeat: isRepeat
        )
        return process(snapshot: &snapshot, layer: layer, swaps: swaps, frame: frame)
    }

    static func tick(
        snapshot: inout PipelineSnapshot,
        layer: LayerConfig,
        maxModifierHoldMs: Int,
        nowMs: UInt64,
        keyIsPhysicallyDown: (CGKeyCode) -> Bool
    ) -> KeyEventOutcome {
        advanceTime(
            snapshot: &snapshot,
            maxModifierHoldMs: maxModifierHoldMs,
            nowMach: Clock.msToMach(nowMs),
            keyIsPhysicallyDown: keyIsPhysicallyDown
        )
    }

    static func activeModifiers(_ keys: [HRKey]) -> CGEventFlags {
        TimeWheel.activeModifiers(keys)
    }

    static func anyPending(_ keys: [HRKey]) -> Bool {
        TimeWheel.anyPending(keys)
    }

    static func swapEventFlags(
        source keyCode: CGKeyCode,
        target dst: CGKeyCode,
        userMods: CGEventFlags
    ) -> CGEventFlags {
        FeatureRouter.swapEventFlags(source: keyCode, target: dst, userMods: userMods)
    }

    static var modifierKeyFlags: [CGKeyCode: CGEventFlags] {
        FeatureRouter.modifierKeyFlags
    }

    static func reapPendingModifiers(
        snapshot: inout PipelineSnapshot,
        nowMs: UInt64
    ) -> ReapOutcome {
        let result = TimeWheel.advance(
            keys: &snapshot.keys,
            buffer: &snapshot.buffer,
            nowMach: Clock.msToMach(nowMs)
        )
        return ReapOutcome(
            actions: result.actions,
            promotedCount: result.promotedCount,
            flushedQueue: result.flushedBuffer
        )
    }
}

public struct ReapOutcome: Equatable, Sendable {
    public var actions: [EngineAction]
    public var promotedCount: Int
    public var flushedQueue: Bool

    public init(actions: [EngineAction], promotedCount: Int, flushedQueue: Bool) {
        self.actions = actions
        self.promotedCount = promotedCount
        self.flushedQueue = flushedQueue
    }
}
