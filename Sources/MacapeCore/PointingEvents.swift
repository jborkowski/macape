import Foundation
import ApplicationServices

enum PointingEventModifier {
    static func applyHomeRowModifiers(
        snapshot: inout StateMachineSnapshot,
        event: CGEvent,
        nowMs: UInt64
    ) -> [EngineAction] {
        guard snapshot.enabled else { return [] }

        let actions = HomeRowStateMachine.promotePendingModifiers(snapshot: &snapshot, nowMs: nowMs)
        let mods = HomeRowStateMachine.activeModifiers(snapshot.keys)
        if !mods.isEmpty {
            event.flags = event.flags.union(mods)
        }
        return actions
    }
}
