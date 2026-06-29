import Foundation
import ApplicationServices

/// Immutable ingress record for a single keyboard event.
public struct EventFrame: Equatable, Sendable {
    public let machTime: UInt64
    public let keyCode: CGKeyCode
    public let down: Bool
    public let flags: CGEventFlags
    public let isRepeat: Bool
    public let userMods: CGEventFlags

    public init(
        machTime: UInt64,
        keyCode: CGKeyCode,
        down: Bool,
        flags: CGEventFlags,
        isRepeat: Bool = false
    ) {
        self.machTime = machTime
        self.keyCode = keyCode
        self.down = down
        self.flags = flags
        self.isRepeat = isRepeat
        self.userMods = flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
    }

    public init(from event: CGEvent, keyCode: CGKeyCode, down: Bool, isRepeat: Bool = false) {
        self.init(
            machTime: event.timestamp,
            keyCode: keyCode,
            down: down,
            flags: event.flags,
            isRepeat: isRepeat
        )
    }

    public var machTimeMs: UInt64 { Clock.machToMs(machTime) }
}
