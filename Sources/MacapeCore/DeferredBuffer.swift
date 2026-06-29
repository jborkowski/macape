import Foundation
import ApplicationServices

public struct BufferedEvent: Equatable, Sendable {
    public var keyCode: CGKeyCode
    public var down: Bool
    public var flags: CGEventFlags
    public var machTime: UInt64
    public var blockedBy: Set<CGKeyCode>

    public init(
        keyCode: CGKeyCode,
        down: Bool,
        flags: CGEventFlags,
        machTime: UInt64,
        blockedBy: Set<CGKeyCode>
    ) {
        self.keyCode = keyCode
        self.down = down
        self.flags = flags
        self.machTime = machTime
        self.blockedBy = blockedBy
    }

    public init(from frame: EventFrame, blockedBy: Set<CGKeyCode>) {
        self.init(
            keyCode: frame.keyCode,
            down: frame.down,
            flags: frame.userMods,
            machTime: frame.machTime,
            blockedBy: blockedBy
        )
    }
}

/// Events deferred while home-row keys are pending.
public struct DeferredBuffer: Equatable, Sendable {
    public var entries: [BufferedEvent] = []

    public init(entries: [BufferedEvent] = []) {
        self.entries = entries
    }

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    public mutating func enqueue(_ event: BufferedEvent) {
        entries.append(event)
    }

    public mutating func enqueue(frame: EventFrame, blockedBy: Set<CGKeyCode>) {
        enqueue(BufferedEvent(from: frame, blockedBy: blockedBy))
    }

    /// Remove a resolved blocker from all entries; flush entries with no blockers left.
    public mutating func resolveBlocker(
        _ keyCode: CGKeyCode,
        modifiers: CGEventFlags
    ) -> (actions: [EngineAction], flushed: Bool) {
        for i in entries.indices {
            entries[i].blockedBy.remove(keyCode)
        }
        return flushUnblocked(modifiers: modifiers)
    }

    /// Flush every entry (used when a pending key promotes to modifier).
    public mutating func flushAll(modifiers: CGEventFlags) -> (actions: [EngineAction], flushed: Bool) {
        guard !entries.isEmpty else { return ([], false) }
        let actions = entries.map { entry in
            EngineAction.postKey(
                entry.keyCode,
                down: entry.down,
                flags: entry.flags.union(modifiers),
                machTime: entry.machTime
            )
        }
        entries.removeAll(keepingCapacity: true)
        return (actions, true)
    }

    private mutating func flushUnblocked(modifiers: CGEventFlags) -> (actions: [EngineAction], flushed: Bool) {
        var actions: [EngineAction] = []
        var remaining: [BufferedEvent] = []
        remaining.reserveCapacity(entries.count)
        for entry in entries {
            if entry.blockedBy.isEmpty {
                actions.append(.postKey(
                    entry.keyCode,
                    down: entry.down,
                    flags: entry.flags.union(modifiers),
                    machTime: entry.machTime
                ))
            } else {
                remaining.append(entry)
            }
        }
        let flushed = actions.count > 0
        entries = remaining
        return (actions, flushed)
    }

    public mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
    }
}
