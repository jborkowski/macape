import Foundation
import ApplicationServices

public enum EventSink {
    public static let syntheticEventMarker: Int64 = 0x6d6163617065

    public static func postKey(
        source: CGEventSource,
        code: CGKeyCode,
        down: Bool,
        extra: CGEventFlags,
        machTime: UInt64?
    ) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        if let machTime {
            event.timestamp = machTime
        }
        event.flags = event.flags.union(extra)
        event.post(tap: .cgSessionEventTap)
    }

    public static func applyActions(
        _ outcome: KeyEventOutcome,
        event: CGEvent,
        existing: CGEventFlags,
        source: CGEventSource,
        onStuck: (CGKeyCode, String) -> Void
    ) -> (passThrough: Bool, passFlags: CGEventFlags, swallowed: Bool) {
        var passThrough = false
        var passFlags = existing
        var swallowed = false

        for action in outcome.actions {
            switch action {
            case .postKey(let code, let down, let flags, let machTime):
                postKey(source: source, code: code, down: down, extra: flags, machTime: machTime)
            case .passThrough(let flags):
                passThrough = true
                passFlags = flags
            case .swallow:
                swallowed = true
            case .stuckRecovery(let key, let reason):
                onStuck(key, reason)
            }
        }
        return (passThrough, passFlags, swallowed)
    }

    public static func applyTimerActions(
        _ outcome: KeyEventOutcome,
        source: CGEventSource,
        onStuck: (CGKeyCode, String) -> Void
    ) {
        for action in outcome.actions {
            switch action {
            case .postKey(let code, let down, let flags, let machTime):
                postKey(source: source, code: code, down: down, extra: flags, machTime: machTime)
            case .passThrough, .swallow:
                break
            case .stuckRecovery(let key, let reason):
                onStuck(key, reason)
            }
        }
    }
}
