import Foundation
import ApplicationServices

public struct AdvanceResult: Equatable, Sendable {
    public var actions: [EngineAction]
    public var promotedCount: Int
    public var flushedBuffer: Bool

    public init(actions: [EngineAction], promotedCount: Int, flushedBuffer: Bool) {
        self.actions = actions
        self.promotedCount = promotedCount
        self.flushedBuffer = flushedBuffer
    }
}

public enum TimeWheel {
    public static func activeModifiers(_ keys: [HRKey]) -> CGEventFlags {
        keys.reduce(into: CGEventFlags()) { acc, k in
            if k.state == .modifier { acc.formUnion(k.modifier) }
        }
    }

    public static func anyPending(_ keys: [HRKey]) -> Bool {
        keys.contains(where: { $0.state == .pending })
    }

    public static func pendingKeyCodes(_ keys: [HRKey]) -> Set<CGKeyCode> {
        Set(keys.filter { $0.state == .pending }.map(\.keyCode))
    }

    public static func nextDeadlineMach(_ keys: [HRKey]) -> UInt64? {
        keys
            .filter { $0.state == .pending && $0.deadlineMach > 0 }
            .map(\.deadlineMach)
            .min()
    }

    /// Promote all pending keys whose deadline has passed at `nowMach`.
    /// On any promotion, flush the entire deferred buffer with active modifiers.
    public static func advance(
        keys: inout [HRKey],
        buffer: inout DeferredBuffer,
        nowMach: UInt64
    ) -> AdvanceResult {
        var promotedCount = 0
        for i in keys.indices {
            let key = keys[i]
            guard key.state == .pending,
                  key.pressMach > 0,
                  nowMach >= key.deadlineMach else { continue }
            keys[i].state = .modifier
            keys[i].modifierSinceMach = nowMach
            promotedCount += 1
        }
        guard promotedCount > 0 else {
            return AdvanceResult(actions: [], promotedCount: 0, flushedBuffer: false)
        }
        let mods = activeModifiers(keys)
        let flush = buffer.flushAll(modifiers: mods)
        return AdvanceResult(
            actions: flush.actions,
            promotedCount: promotedCount,
            flushedBuffer: flush.flushed
        )
    }

    public static func rescheduleNextDeadline(
        keys: [HRKey],
        scheduler: DeadlineScheduler,
        handler: @escaping @Sendable () -> Void
    ) {
        scheduler.schedule(deadlineMach: nextDeadlineMach(keys), handler: handler)
    }
}
