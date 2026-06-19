import Foundation
import ApplicationServices

public enum HRState: Equatable, Sendable {
    case idle, pending, modifier
}

public struct DefEvent: Equatable, Sendable {
    public var keycode: CGKeyCode
    public var down: Bool
    public var flags: CGEventFlags

    public init(keycode: CGKeyCode, down: Bool, flags: CGEventFlags) {
        self.keycode = keycode
        self.down = down
        self.flags = flags
    }
}

public struct HRKey: Equatable, Sendable {
    public let keyCode: CGKeyCode
    public let modifier: CGEventFlags
    public let holdTimeoutMs: Int
    public var state: HRState = .idle
    public var pressTimeMs: UInt64 = 0
    public var modifierSinceMs: UInt64 = 0

    public init(
        keyCode: CGKeyCode,
        modifier: CGEventFlags,
        holdTimeoutMs: Int,
        state: HRState = .idle,
        pressTimeMs: UInt64 = 0,
        modifierSinceMs: UInt64 = 0
    ) {
        self.keyCode = keyCode
        self.modifier = modifier
        self.holdTimeoutMs = holdTimeoutMs
        self.state = state
        self.pressTimeMs = pressTimeMs
        self.modifierSinceMs = modifierSinceMs
    }
}

public enum EngineAction: Equatable, Sendable {
    case postKey(CGKeyCode, down: Bool, flags: CGEventFlags)
    case passThrough(flags: CGEventFlags)
    case swallow
    case stuckRecovery(key: CGKeyCode, reason: String)
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

public struct KeyEventOutcome: Equatable, Sendable {
    public var actions: [EngineAction]
    public var modifierPromotions: Int
    public var queueFlushes: Int

    public init(actions: [EngineAction], modifierPromotions: Int = 0, queueFlushes: Int = 0) {
        self.actions = actions
        self.modifierPromotions = modifierPromotions
        self.queueFlushes = queueFlushes
    }
}

public struct StateMachineSnapshot: Equatable, Sendable {
    public var keys: [HRKey]
    public var queue: [DefEvent]
    public var layerDown: Bool
    public var layerConsumed: Bool
    public var layerOwnedKeys: Set<CGKeyCode>
    public var swapOwnedKeys: Set<CGKeyCode>
    public var enabled: Bool

    public init(
        keys: [HRKey],
        queue: [DefEvent] = [],
        layerDown: Bool = false,
        layerConsumed: Bool = false,
        layerOwnedKeys: Set<CGKeyCode> = [],
        swapOwnedKeys: Set<CGKeyCode> = [],
        enabled: Bool = true
    ) {
        self.keys = keys
        self.queue = queue
        self.layerDown = layerDown
        self.layerConsumed = layerConsumed
        self.layerOwnedKeys = layerOwnedKeys
        self.swapOwnedKeys = swapOwnedKeys
        self.enabled = enabled
    }
}

public enum HomeRowStateMachine {
    public static func anyPending(_ keys: [HRKey]) -> Bool {
        keys.contains(where: { $0.state == .pending })
    }

    public static func activeModifiers(_ keys: [HRKey]) -> CGEventFlags {
        keys.reduce(into: CGEventFlags()) { acc, k in
            if k.state == .modifier { acc.formUnion(k.modifier) }
        }
    }

    /// Promote any pending home-row key whose hold timeout has already elapsed,
    /// using the authoritative timestamp `nowMs`.
    ///
    /// `nowMs` must be in the same clock domain as `HRKey.pressTimeMs` — i.e.
    /// derived from the hardware event timestamp (`CGEvent.timestamp` converted
    /// to ms), or from `mach_absolute_time()` on the run-loop timer. Both are
    /// mach-absolute-based, so durations are accurate regardless of how long the
    /// OS took to deliver the callback.
    ///
    /// Calling this at the start of every key event makes events the
    /// authoritative resolution path: stale `.pending` states are corrected to
    /// real time *before* the new event is interpreted, so modifier state is
    /// always accurate. The run-loop timer (`tick`) remains only as a safety net
    /// for held keys that receive no further events (and for stuck recovery).
    ///
    /// Returns flush actions for any queue events that piled up while the
    /// promoted modifier should have been active (matching `tick` semantics).
    public static func reapPendingModifiers(
        snapshot: inout StateMachineSnapshot,
        nowMs: UInt64
    ) -> ReapOutcome {
        var promotedCount = 0
        for i in snapshot.keys.indices {
            let key = snapshot.keys[i]
            guard key.state == .pending,
                  key.pressTimeMs > 0,
                  nowMs >= key.pressTimeMs,
                  nowMs - key.pressTimeMs >= UInt64(key.holdTimeoutMs) else { continue }
            snapshot.keys[i].state = .modifier
            snapshot.keys[i].modifierSinceMs = nowMs
            promotedCount += 1
        }
        guard promotedCount > 0 else {
            return ReapOutcome(actions: [], promotedCount: 0, flushedQueue: false)
        }
        let hadQueue = !snapshot.queue.isEmpty
        let actions = flushQueue(snapshot: &snapshot)
        return ReapOutcome(actions: actions, promotedCount: promotedCount, flushedQueue: hadQueue)
    }

    /// One-way remap target when this physical key has a swap binding.
    public static func swapTarget(_ swaps: SwapConfig, _ keyCode: CGKeyCode) -> CGKeyCode? {
        swaps.mappings[keyCode]
    }

    /// Mapped arrow keycode when the layer hold is active and this key has a layer binding.
    public static func layerArrow(_ layer: LayerConfig, _ keyCode: CGKeyCode, layerDown: Bool) -> CGKeyCode? {
        guard layerDown else { return nil }
        return layer.mappings[keyCode]
    }

    private static func clearHomeRowState(snapshot: inout StateMachineSnapshot, at idx: Int) {
        snapshot.keys[idx].state = .idle
        snapshot.keys[idx].pressTimeMs = 0
        snapshot.keys[idx].modifierSinceMs = 0
    }

    public static func handleKeyEvent(
        snapshot: inout StateMachineSnapshot,
        layer: LayerConfig,
        swaps: SwapConfig,
        keyCode: CGKeyCode,
        down: Bool,
        isRepeat: Bool,
        userMods: CGEventFlags,
        nowMs: UInt64
    ) -> KeyEventOutcome {
        // Precedence (highest first):
        // 1. Engine disabled -> pass through.
        // 2. Instant key swap (one-way remap).
        // 3. Layer hold key (space) press/release bookkeeping.
        // 4. Active layer claim: layerDown + mapped key -> clean arrow (wins over home-row).
        // 5. Real physical modifiers over a home-row key -> pass through.
        // 6. Home-row tap/hold resolution.
        // 7. Queue / pass through.

        var metricsPromotions = 0
        var metricsFlushes = 0

        func outcome(
            _ actions: [EngineAction],
            extraPromotions: Int = 0,
            extraFlushes: Int = 0
        ) -> KeyEventOutcome {
            KeyEventOutcome(
                actions: actions,
                modifierPromotions: metricsPromotions + extraPromotions,
                queueFlushes: metricsFlushes + extraFlushes
            )
        }

        guard snapshot.enabled else {
            let mods = activeModifiers(snapshot.keys)
            return outcome(mods.isEmpty ? [.passThrough(flags: [])] : [.passThrough(flags: mods)])
        }

        var actions: [EngineAction] = []
        // Authoritative resolution: promote any pending key whose hold timeout
        // has already elapsed (per the event-timestamped clock) before handling
        // this event. This keeps modifier state accurate to real time and
        // removes the key-up/timer race that previously dropped modifiers and
        // stranded the queue.
        let reap = reapPendingModifiers(snapshot: &snapshot, nowMs: nowMs)
        actions.append(contentsOf: reap.actions)
        metricsPromotions = reap.promotedCount
        metricsFlushes = reap.flushedQueue ? 1 : 0

        let hrIdx = snapshot.keys.firstIndex(where: { $0.keyCode == keyCode })

        // Tier 2: instant key swap
        if let dst = swapTarget(swaps, keyCode) {
            if down {
                if isRepeat { return outcome([.swallow]) }
                snapshot.swapOwnedKeys.insert(keyCode)
                return outcome([.postKey(dst, down: true, flags: userMods)])
            }
            if snapshot.swapOwnedKeys.contains(keyCode) {
                snapshot.swapOwnedKeys.remove(keyCode)
                return outcome([.postKey(dst, down: false, flags: userMods)])
            }
            return outcome([.swallow])
        }

        // Tier 3: layer hold key
        if keyCode == layer.holdKeyCode, userMods.isEmpty {
            if down {
                if isRepeat { return outcome([.swallow]) }
                snapshot.layerDown = true
                snapshot.layerConsumed = false
                return outcome([.swallow])
            }
            if !snapshot.layerDown {
                return outcome([.passThrough(flags: activeModifiers(snapshot.keys))])
            }
            snapshot.layerDown = false
            if snapshot.layerConsumed {
                snapshot.layerConsumed = false
                return outcome([.swallow])
            }
            let mods = activeModifiers(snapshot.keys)
            actions.append(.postKey(layer.holdKeyCode, down: true, flags: mods))
            actions.append(.postKey(layer.holdKeyCode, down: false, flags: mods))
            return outcome(actions)
        }

        // Tier 4: active layer claim (supersedes home-row)
        if let arrowCode = layerArrow(layer, keyCode, layerDown: snapshot.layerDown) {
            if down {
                snapshot.layerConsumed = true
                snapshot.layerOwnedKeys.insert(keyCode)
                if let idx = hrIdx, snapshot.keys[idx].state != .idle {
                    clearHomeRowState(snapshot: &snapshot, at: idx)
                }
                actions.append(.postKey(arrowCode, down: true, flags: userMods))
                return outcome(actions)
            }
            if snapshot.layerOwnedKeys.contains(keyCode) {
                snapshot.layerOwnedKeys.remove(keyCode)
                actions.append(.postKey(arrowCode, down: false, flags: userMods))
                return outcome(actions)
            }
            if let idx = hrIdx, snapshot.keys[idx].state != .idle {
                clearHomeRowState(snapshot: &snapshot, at: idx)
            }
            return outcome([.swallow])
        }

        // Tier 5: real physical modifiers over a home-row key
        if !userMods.isEmpty, hrIdx != nil {
            return outcome([.passThrough(flags: userMods.union(activeModifiers(snapshot.keys)))])
        }

        // Tier 6: home-row tap/hold resolution
        if let idx = hrIdx {
            if down {
                if isRepeat { return outcome([.swallow]) }
                if snapshot.keys[idx].state != .idle { return outcome([.swallow]) }
                snapshot.keys[idx].state = .pending
                snapshot.keys[idx].pressTimeMs = nowMs
                return outcome([.swallow])
            }

            switch snapshot.keys[idx].state {
            case .pending:
                let held = nowMs - snapshot.keys[idx].pressTimeMs
                let holdTimeout = UInt64(snapshot.keys[idx].holdTimeoutMs)
                if held >= holdTimeout {
                    // Defensive: reaping at the top of this call should have
                    // promoted this key already. If we get here, resolve it as a
                    // hold — apply the modifier to the queue and emit no letter —
                    // rather than silently swallowing and stranding queued events.
                    snapshot.keys[idx].state = .modifier
                    snapshot.keys[idx].modifierSinceMs = snapshot.keys[idx].pressTimeMs
                    var holdActions: [EngineAction] = []
                    var flushedQueue = false
                    if !anyPending(snapshot.keys) {
                        let mods = activeModifiers(snapshot.keys)
                        flushedQueue = !snapshot.queue.isEmpty
                        for e in snapshot.queue {
                            holdActions.append(.postKey(e.keycode, down: e.down, flags: e.flags.union(mods)))
                        }
                        snapshot.queue.removeAll(keepingCapacity: true)
                    }
                    snapshot.keys[idx].state = .idle
                    snapshot.keys[idx].pressTimeMs = 0
                    snapshot.keys[idx].modifierSinceMs = 0
                    return outcome(holdActions, extraPromotions: 1, extraFlushes: flushedQueue ? 1 : 0)
                }

                snapshot.keys[idx].state = .idle
                let mods = activeModifiers(snapshot.keys)
                actions.append(.postKey(keyCode, down: true, flags: mods))
                actions.append(.postKey(keyCode, down: false, flags: mods))
                var flushedQueue = false
                if !anyPending(snapshot.keys) {
                    flushedQueue = !snapshot.queue.isEmpty
                    for e in snapshot.queue {
                        actions.append(.postKey(e.keycode, down: e.down, flags: e.flags.union(mods)))
                    }
                    snapshot.queue.removeAll(keepingCapacity: true)
                }
                return outcome(actions, extraFlushes: flushedQueue ? 1 : 0)

            case .modifier:
                snapshot.keys[idx].state = .idle
                snapshot.keys[idx].pressTimeMs = 0
                snapshot.keys[idx].modifierSinceMs = 0
                // reapPendingModifiers may have promoted this key and flushed the
                // queue into `actions` before we reached this branch.
                return outcome(actions.isEmpty ? [.swallow] : actions)

            case .idle:
                if anyPending(snapshot.keys) {
                    snapshot.queue.append(DefEvent(keycode: keyCode, down: false, flags: []))
                    return outcome([.swallow])
                }
                return outcome([.passThrough(flags: userMods.union(activeModifiers(snapshot.keys)))])
            }
        }

        // Tier 7: queue / pass through
        if anyPending(snapshot.keys) {
            snapshot.queue.append(DefEvent(keycode: keyCode, down: down, flags: userMods))
            return outcome([.swallow])
        }

        let mods = activeModifiers(snapshot.keys)
        return outcome(mods.isEmpty ? [.passThrough(flags: userMods)] : [.passThrough(flags: userMods.union(mods))])
    }

    public static func tick(
        snapshot: inout StateMachineSnapshot,
        layer: LayerConfig,
        maxModifierHoldMs: Int,
        nowMs: UInt64,
        keyIsPhysicallyDown: (CGKeyCode) -> Bool
    ) -> KeyEventOutcome {
        var actions: [EngineAction] = []

        // Safety net: promote pending keys whose hold timeout has elapsed even
        // when no further key events arrive (e.g. a key held in isolation).
        let reap = reapPendingModifiers(snapshot: &snapshot, nowMs: nowMs)
        actions.append(contentsOf: reap.actions)
        let modifierPromotions = reap.promotedCount
        let queueFlushes = reap.flushedQueue ? 1 : 0

        // Stuck recovery: a modifier held far too long is treated as lost.
        for i in snapshot.keys.indices {
            let key = snapshot.keys[i]
            guard key.state == .modifier,
                  maxModifierHoldMs > 0,
                  key.modifierSinceMs > 0,
                  nowMs >= key.modifierSinceMs,
                  nowMs - key.modifierSinceMs >= UInt64(maxModifierHoldMs) else { continue }
            snapshot.keys[i].state = .idle
            snapshot.keys[i].modifierSinceMs = 0
            actions.append(.stuckRecovery(key: key.keyCode, reason: "max modifier hold"))
        }

        return KeyEventOutcome(
            actions: actions,
            modifierPromotions: modifierPromotions,
            queueFlushes: queueFlushes
        )
    }

    public static func resetAll(snapshot: inout StateMachineSnapshot, layer: LayerConfig, swaps: SwapConfig) -> [EngineAction] {
        var actions: [EngineAction] = []
        for owned in snapshot.swapOwnedKeys {
            if let dst = swaps.mappings[owned] {
                actions.append(.postKey(dst, down: false, flags: []))
            }
        }
        snapshot.swapOwnedKeys.removeAll()
        for owned in snapshot.layerOwnedKeys {
            if let arrow = layer.mappings[owned] {
                actions.append(.postKey(arrow, down: false, flags: []))
            }
        }
        snapshot.layerOwnedKeys.removeAll()
        snapshot.layerDown = false
        snapshot.layerConsumed = false
        snapshot.queue.removeAll(keepingCapacity: true)
        for i in snapshot.keys.indices where snapshot.keys[i].state != .idle {
            actions.append(.stuckRecovery(key: snapshot.keys[i].keyCode, reason: "reset"))
            snapshot.keys[i].state = .idle
            snapshot.keys[i].pressTimeMs = 0
            snapshot.keys[i].modifierSinceMs = 0
        }
        return actions
    }

    private static func recoverLayerHold(
        snapshot: inout StateMachineSnapshot,
        layer: LayerConfig,
        reason: String
    ) -> [EngineAction] {
        var actions: [EngineAction] = []
        snapshot.layerDown = false
        if snapshot.layerConsumed {
            snapshot.layerConsumed = false
            actions.append(.stuckRecovery(key: layer.holdKeyCode, reason: reason))
            return actions
        }
        let mods = activeModifiers(snapshot.keys)
        actions.append(.postKey(layer.holdKeyCode, down: true, flags: mods))
        actions.append(.postKey(layer.holdKeyCode, down: false, flags: mods))
        actions.append(.stuckRecovery(key: layer.holdKeyCode, reason: reason))
        return actions
    }

    private static func flushQueue(snapshot: inout StateMachineSnapshot) -> [EngineAction] {
        let mods = activeModifiers(snapshot.keys)
        var actions: [EngineAction] = []
        for e in snapshot.queue {
            actions.append(.postKey(e.keycode, down: e.down, flags: e.flags.union(mods)))
        }
        snapshot.queue.removeAll(keepingCapacity: true)
        return actions
    }
}
