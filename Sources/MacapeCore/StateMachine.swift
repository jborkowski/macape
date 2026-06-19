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
    public let tapTimeoutMs: Int
    public var state: HRState = .idle
    public var pressTimeMs: UInt64 = 0
    public var modifierSinceMs: UInt64 = 0

    public init(
        keyCode: CGKeyCode,
        modifier: CGEventFlags,
        holdTimeoutMs: Int,
        tapTimeoutMs: Int,
        state: HRState = .idle,
        pressTimeMs: UInt64 = 0,
        modifierSinceMs: UInt64 = 0
    ) {
        self.keyCode = keyCode
        self.modifier = modifier
        self.holdTimeoutMs = holdTimeoutMs
        self.tapTimeoutMs = tapTimeoutMs
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

public struct StateMachineSnapshot: Equatable, Sendable {
    public var keys: [HRKey]
    public var queue: [DefEvent]
    public var layerDown: Bool
    public var layerConsumed: Bool
    public var layerOwnedKeys: Set<CGKeyCode>
    public var enabled: Bool

    public init(
        keys: [HRKey],
        queue: [DefEvent] = [],
        layerDown: Bool = false,
        layerConsumed: Bool = false,
        layerOwnedKeys: Set<CGKeyCode> = [],
        enabled: Bool = true
    ) {
        self.keys = keys
        self.queue = queue
        self.layerDown = layerDown
        self.layerConsumed = layerConsumed
        self.layerOwnedKeys = layerOwnedKeys
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

    public static func handleKeyEvent(
        snapshot: inout StateMachineSnapshot,
        layer: LayerConfig,
        keyCode: CGKeyCode,
        down: Bool,
        isRepeat: Bool,
        userMods: CGEventFlags,
        nowMs: UInt64
    ) -> [EngineAction] {
        guard snapshot.enabled else {
            let mods = activeModifiers(snapshot.keys)
            return mods.isEmpty ? [.passThrough(flags: [])] : [.passThrough(flags: mods)]
        }

        var actions: [EngineAction] = []
        let hrIdx = snapshot.keys.firstIndex(where: { $0.keyCode == keyCode })

        if keyCode == layer.holdKeyCode, userMods.isEmpty {
            if down {
                if isRepeat { return [.swallow] }
                snapshot.layerDown = true
                snapshot.layerConsumed = false
                return [.swallow]
            }
            if !snapshot.layerDown {
                return [.passThrough(flags: activeModifiers(snapshot.keys))]
            }
            snapshot.layerDown = false
            if snapshot.layerConsumed {
                snapshot.layerConsumed = false
                return [.swallow]
            }
            let mods = activeModifiers(snapshot.keys)
            actions.append(.postKey(layer.holdKeyCode, down: true, flags: mods))
            actions.append(.postKey(layer.holdKeyCode, down: false, flags: mods))
            return actions
        }

        if snapshot.layerDown, down, let arrowCode = layer.mappings[keyCode] {
            snapshot.layerConsumed = true
            snapshot.layerOwnedKeys.insert(keyCode)
            actions.append(.postKey(arrowCode, down: true, flags: userMods.union(activeModifiers(snapshot.keys))))
            return actions
        }
        if !down, snapshot.layerOwnedKeys.contains(keyCode), let arrowCode = layer.mappings[keyCode] {
            snapshot.layerOwnedKeys.remove(keyCode)
            actions.append(.postKey(arrowCode, down: false, flags: userMods.union(activeModifiers(snapshot.keys))))
            return actions
        }

        if !userMods.isEmpty, hrIdx != nil {
            return [.passThrough(flags: userMods.union(activeModifiers(snapshot.keys)))]
        }

        if let idx = hrIdx {
            if down {
                if isRepeat { return [.swallow] }
                if snapshot.keys[idx].state != .idle { return [.swallow] }
                snapshot.keys[idx].state = .pending
                snapshot.keys[idx].pressTimeMs = nowMs
                return [.swallow]
            }

            switch snapshot.keys[idx].state {
            case .pending:
                let held = nowMs - snapshot.keys[idx].pressTimeMs
                let holdTimeout = UInt64(snapshot.keys[idx].holdTimeoutMs)
                if held >= holdTimeout {
                    snapshot.keys[idx].state = .idle
                    return [.swallow]
                }

                snapshot.keys[idx].state = .idle
                let mods = activeModifiers(snapshot.keys)
                actions.append(.postKey(keyCode, down: true, flags: mods))
                actions.append(.postKey(keyCode, down: false, flags: mods))
                if !anyPending(snapshot.keys) {
                    for e in snapshot.queue {
                        actions.append(.postKey(e.keycode, down: e.down, flags: e.flags.union(mods)))
                    }
                    snapshot.queue.removeAll(keepingCapacity: true)
                }
                return actions

            case .modifier:
                snapshot.keys[idx].state = .idle
                return [.swallow]

            case .idle:
                if anyPending(snapshot.keys) {
                    snapshot.queue.append(DefEvent(keycode: keyCode, down: false, flags: []))
                    return [.swallow]
                }
                return [.passThrough(flags: userMods.union(activeModifiers(snapshot.keys)))]
            }
        }

        if anyPending(snapshot.keys) {
            snapshot.queue.append(DefEvent(keycode: keyCode, down: down, flags: userMods))
            return [.swallow]
        }

        let mods = activeModifiers(snapshot.keys)
        return mods.isEmpty ? [.passThrough(flags: userMods)] : [.passThrough(flags: userMods.union(mods))]
    }

    public static func tick(
        snapshot: inout StateMachineSnapshot,
        layer: LayerConfig,
        maxModifierHoldMs: Int,
        nowMs: UInt64,
        keyIsPhysicallyDown: (CGKeyCode) -> Bool
    ) -> [EngineAction] {
        var actions: [EngineAction] = []

        if snapshot.layerDown, !keyIsPhysicallyDown(layer.holdKeyCode) {
            actions.append(contentsOf: recoverLayerHold(snapshot: &snapshot, layer: layer, reason: "layer hold key up"))
        }

        for owned in snapshot.layerOwnedKeys {
            if !keyIsPhysicallyDown(owned) {
                if let arrow = layer.mappings[owned] {
                    actions.append(.postKey(arrow, down: false, flags: activeModifiers(snapshot.keys)))
                }
                snapshot.layerOwnedKeys.remove(owned)
                actions.append(.stuckRecovery(key: owned, reason: "layer key up"))
            }
        }

        var promotedPending = false
        for i in snapshot.keys.indices {
            let key = snapshot.keys[i]
            guard key.state != .idle else { continue }
            if key.state == .pending,
               nowMs - key.pressTimeMs >= UInt64(key.holdTimeoutMs) {
                snapshot.keys[i].state = .modifier
                snapshot.keys[i].modifierSinceMs = nowMs
                promotedPending = true
            } else if key.state == .modifier,
                      maxModifierHoldMs > 0,
                      nowMs - key.modifierSinceMs >= UInt64(maxModifierHoldMs) {
                snapshot.keys[i].state = .idle
                snapshot.keys[i].modifierSinceMs = 0
                actions.append(.stuckRecovery(key: key.keyCode, reason: "max modifier hold"))
            }
        }
        if promotedPending {
            actions.append(contentsOf: flushQueue(snapshot: &snapshot))
        }

        return actions
    }

    public static func promotePendingModifiers(snapshot: inout StateMachineSnapshot, nowMs: UInt64) -> [EngineAction] {
        var changed = false
        for i in snapshot.keys.indices where snapshot.keys[i].state == .pending {
            snapshot.keys[i].state = .modifier
            snapshot.keys[i].modifierSinceMs = nowMs
            changed = true
        }
        return changed ? flushQueue(snapshot: &snapshot) : []
    }

    public static func resetAll(snapshot: inout StateMachineSnapshot, layer: LayerConfig) -> [EngineAction] {
        var actions: [EngineAction] = []
        for owned in snapshot.layerOwnedKeys {
            if let arrow = layer.mappings[owned] {
                actions.append(.postKey(arrow, down: false, flags: activeModifiers(snapshot.keys)))
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
