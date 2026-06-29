import Foundation
import ApplicationServices

public enum HRState: Equatable, Sendable {
    case idle, pending, modifier
}

public struct HRKey: Equatable, Sendable {
    public let keyCode: CGKeyCode
    public let modifier: CGEventFlags
    public let holdTimeoutMs: Int
    public var state: HRState = .idle
    public var pressMach: UInt64 = 0
    public var deadlineMach: UInt64 = 0
    public var modifierSinceMach: UInt64 = 0

    public init(
        keyCode: CGKeyCode,
        modifier: CGEventFlags,
        holdTimeoutMs: Int,
        state: HRState = .idle,
        pressMach: UInt64 = 0,
        deadlineMach: UInt64 = 0,
        modifierSinceMach: UInt64 = 0
    ) {
        self.keyCode = keyCode
        self.modifier = modifier
        self.holdTimeoutMs = holdTimeoutMs
        self.state = state
        self.pressMach = pressMach
        self.deadlineMach = deadlineMach
        self.modifierSinceMach = modifierSinceMach
    }
}

public enum EngineAction: Equatable, Sendable {
    case postKey(CGKeyCode, down: Bool, flags: CGEventFlags, machTime: UInt64?)
    case passThrough(flags: CGEventFlags)
    case swallow
    case stuckRecovery(key: CGKeyCode, reason: String)
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

public struct PipelineSnapshot: Equatable, Sendable {
    public var keys: [HRKey]
    public var buffer: DeferredBuffer
    public var layerDown: Bool
    public var layerConsumed: Bool
    public var layerOwnedKeys: Set<CGKeyCode>
    public var swapOwnedKeys: Set<CGKeyCode>
    public var enabled: Bool

    public init(
        keys: [HRKey],
        buffer: DeferredBuffer = DeferredBuffer(),
        layerDown: Bool = false,
        layerConsumed: Bool = false,
        layerOwnedKeys: Set<CGKeyCode> = [],
        swapOwnedKeys: Set<CGKeyCode> = [],
        enabled: Bool = true
    ) {
        self.keys = keys
        self.buffer = buffer
        self.layerDown = layerDown
        self.layerConsumed = layerConsumed
        self.layerOwnedKeys = layerOwnedKeys
        self.swapOwnedKeys = swapOwnedKeys
        self.enabled = enabled
    }
}

public typealias StateMachineSnapshot = PipelineSnapshot
