import Foundation
import ApplicationServices
import os

private func describeFlags(_ flags: CGEventFlags) -> String {
    var names: [String] = []
    if flags.contains(.maskCommand) { names.append("cmd") }
    if flags.contains(.maskAlternate) { names.append("opt") }
    if flags.contains(.maskControl) { names.append("ctrl") }
    if flags.contains(.maskShift) { names.append("shift") }
    return names.isEmpty ? "none" : names.joined(separator: "+")
}

private func describeActions(_ actions: [EngineAction]) -> String {
    actions.map { action in
        switch action {
        case .postKey(let code, let down, let flags):
            return "postKey(0x\(String(code, radix: 16)),\(down ? "down" : "up"),flags=\(describeFlags(flags)))"
        case .passThrough(let flags):
            return "passThrough(flags=\(describeFlags(flags)))"
        case .swallow:
            return "swallow"
        case .stuckRecovery(let key, let reason):
            return "stuck(0x\(String(key, radix: 16)),\(reason))"
        }
    }.joined(separator: ",")
}

private let macapeSyntheticEventMarker: Int64 = 0x6d6163617065

private let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
    let engine = Unmanaged<Engine>.fromOpaque(refcon).takeUnretainedValue()
    return engine.handle(type: type, event: event)
}

public final class Engine: @unchecked Sendable {
    public enum StartError: Error, LocalizedError {
        case sourceCreate
        case tapCreate

        public var errorDescription: String? {
            switch self {
            case .sourceCreate: return "CGEventSource creation failed"
            case .tapCreate: return "CGEventTapCreate failed"
            }
        }
    }

    public var onEvent: (@Sendable (DaemonEvent) -> Void)?

    private var config: Config
    private var snapshot: StateMachineSnapshot
    private let source: CGEventSource
    private var tap: CFMachPort?
    private let runLoop: CFRunLoop

    private init(config: Config) throws {
        self.config = config
        self.snapshot = StateMachineSnapshot(keys: config.mappings.map {
            HRKey(
                keyCode: $0.keyCode,
                modifier: $0.modifier,
                holdTimeoutMs: config.holdTimeout(for: $0)
            )
        })
        self.runLoop = CFRunLoopGetCurrent()
        guard let src = CGEventSource(stateID: .hidSystemState) else {
            throw StartError.sourceCreate
        }
        self.source = src
    }

    public static func start(config: Config) throws -> Engine {
        let engine = try Engine(config: config)
        try engine.install()
        return engine
    }

    public var enabled: Bool {
        get { snapshot.enabled }
        set { snapshot.enabled = newValue }
    }

    public func statusSnapshot(connectedClients: Int) -> StatusSnapshot {
        let metrics = Metrics.shared.snapshot()
        return StatusSnapshot(
            enabled: snapshot.enabled,
            mappingCount: config.mappings.count,
            holdTimeoutMs: config.holdTimeoutMs,
            layerEnabled: config.layer.enabled,
            stuckRecoveries: Int(metrics.stuckRecoveries),
            connectedClients: connectedClients
        )
    }

    public func applyConfig(_ config: Config) {
        performOnRunLoop { [self] in
            let actions = HomeRowStateMachine.resetAll(snapshot: &self.snapshot, layer: self.config.layer, swaps: self.config.swaps)
            self.applyActions(actions)
            self.config = config
            self.snapshot.keys = config.mappings.map {
                HRKey(
                    keyCode: $0.keyCode,
                    modifier: $0.modifier,
                    holdTimeoutMs: config.holdTimeout(for: $0)
                )
            }
        }
    }

    public func setEnabled(_ enabled: Bool) {
        performOnRunLoop { [self] in
            if self.snapshot.enabled == enabled { return }
            let actions = HomeRowStateMachine.resetAll(snapshot: &self.snapshot, layer: self.config.layer, swaps: self.config.swaps)
            self.applyActions(actions)
            self.snapshot.enabled = enabled
        }
    }

    public func clearStuck() {
        performOnRunLoop { [self] in
            let actions = HomeRowStateMachine.resetAll(snapshot: &self.snapshot, layer: self.config.layer, swaps: self.config.swaps)
            self.applyActions(actions)
        }
    }

    public func performOnRunLoop(_ block: @escaping @Sendable () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    private func install() throws {
        let bit: (CGEventType) -> CGEventMask = { CGEventMask(1) << CGEventMask($0.rawValue) }
        let mask = bit(.keyDown) | bit(.keyUp)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: tapCallback,
            userInfo: refcon
        ) else {
            throw StartError.tapCreate
        }
        self.tap = tap

        let rls = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(runLoop, rls, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        let interval: CFTimeInterval = 0.002
        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + interval,
            interval,
            0, 0
        ) { [unowned self] _ in
            self.tick()
        }
        CFRunLoopAddTimer(runLoop, timer, .commonModes)
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let start = Clock.nowUs()
        defer {
            // Measure processing duration only (epoch-agnostic). No Task hop.
            let elapsed = Clock.nowUs() - start
            Metrics.shared.recordCallbackLatency(microseconds: elapsed)
            Metrics.shared.recordEvent()
            if elapsed > 5000 {
                MacapeLog.perf.warning("slow callback \(elapsed)us")
            }
        }

        if event.getIntegerValueField(.eventSourceUserData) == macapeSyntheticEventMarker {
            return Unmanaged.passUnretained(event)
        }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            MacapeLog.engine.error("tap disabled (type=\(type.rawValue)); re-enabling and resetting state")
            Metrics.shared.recordTapDisableRecovery()
            if let tap = self.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            let actions = HomeRowStateMachine.resetAll(snapshot: &snapshot, layer: config.layer, swaps: config.swaps)
            applyActions(actions)
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }

        let code: CGKeyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let down = (type == .keyDown)
        let existing = event.flags
        let userMods = existing.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        // Use the hardware event timestamp — accurate hold/tap durations even
        // under variable callback delivery latency.
        let now = Clock.eventMs(event)

        let beforeMods = HomeRowStateMachine.activeModifiers(snapshot.keys)
        let beforeStates = snapshot.keys.map { "0x\(String($0.keyCode, radix: 16))=\($0.state)" }.joined(separator: " ")
        let outcome = HomeRowStateMachine.handleKeyEvent(
            snapshot: &snapshot,
            layer: config.layer,
            swaps: config.swaps,
            keyCode: code,
            down: down,
            isRepeat: isRepeat,
            userMods: userMods,
            nowMs: now
        )
        let afterMods = HomeRowStateMachine.activeModifiers(snapshot.keys)
        let afterStates = snapshot.keys.map { "0x\(String($0.keyCode, radix: 16))=\($0.state)" }.joined(separator: " ")
        MacapeLog.debug("key code=0x\(String(code, radix: 16)) \(down ? "down" : "up") repeat=\(isRepeat) userMods=\(describeFlags(userMods)) activeBefore=\(describeFlags(beforeMods)) activeAfter=\(describeFlags(afterMods)) statesBefore=[\(beforeStates)] statesAfter=[\(afterStates)] actions=[\(describeActions(outcome.actions))]")

        return applyHandleActions(outcome, event: event, existing: existing)
    }

    private func tick() {
        let now = Clock.nowMs()
        let outcome = HomeRowStateMachine.tick(
            snapshot: &snapshot,
            layer: config.layer,
            maxModifierHoldMs: config.maxModifierHoldMs,
            nowMs: now,
            keyIsPhysicallyDown: { CGEventSource.keyState(.combinedSessionState, key: $0) }
        )
        applyActions(outcome)
    }

    private func applyHandleActions(
        _ outcome: KeyEventOutcome,
        event: CGEvent,
        existing: CGEventFlags
    ) -> Unmanaged<CGEvent>? {
        let actions = outcome.actions
        var passThrough = false
        var passFlags = existing
        var tapPosts = 0
        var recoveries = 0
        for action in actions {
            switch action {
            case .postKey(let code, let down, let flags):
                postKey(code, down: down, extra: flags)
                tapPosts &+= 1
            case .passThrough(let flags):
                passThrough = true
                passFlags = flags
            case .swallow:
                recordActionMetrics(
                    taps: tapPosts,
                    modifierPromotions: outcome.modifierPromotions,
                    queueFlushes: outcome.queueFlushes,
                    recoveries: recoveries
                )
                return nil
            case .stuckRecovery(let key, let reason):
                emitStuck(key: key, reason: reason)
                recoveries &+= 1
            }
        }
        recordActionMetrics(
            taps: tapPosts,
            modifierPromotions: outcome.modifierPromotions,
            queueFlushes: outcome.queueFlushes,
            recoveries: recoveries
        )
        if passThrough {
            if !passFlags.isEmpty { event.flags = passFlags }
            return Unmanaged.passUnretained(event)
        }
        return nil
    }

    private func recordActionMetrics(
        taps: Int,
        modifierPromotions: Int,
        queueFlushes: Int,
        recoveries: Int
    ) {
        Metrics.shared.recordTap(count: taps)
        if recoveries > 0 { Metrics.shared.recordStuckRecovery() }
        if modifierPromotions > 0 { Metrics.shared.recordModifierPromotion(count: modifierPromotions) }
        if queueFlushes > 0 { Metrics.shared.recordQueueFlush(count: queueFlushes) }
    }

    private func applyActions(_ outcome: KeyEventOutcome) {
        var taps = 0
        var recoveries = 0
        for action in outcome.actions {
            switch action {
            case .postKey(let code, let down, let flags):
                postKey(code, down: down, extra: flags)
                taps &+= 1
            case .passThrough, .swallow:
                break
            case .stuckRecovery(let key, let reason):
                emitStuck(key: key, reason: reason)
                recoveries &+= 1
            }
        }
        recordActionMetrics(
            taps: taps,
            modifierPromotions: outcome.modifierPromotions,
            queueFlushes: outcome.queueFlushes,
            recoveries: recoveries
        )
    }

    private func applyActions(_ actions: [EngineAction]) {
        applyActions(KeyEventOutcome(actions: actions))
    }

    private func emitStuck(key: CGKeyCode, reason: String) {
        let name = Config.keyName(for: key)
        MacapeLog.stuck.error("stuck recovery key=\(name) reason=\(reason)")
        onEvent?(.stuck(key: name, reason: reason))
    }

    private func postKey(_ code: CGKeyCode, down: Bool, extra: CGEventFlags) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        e.setIntegerValueField(.eventSourceUserData, value: macapeSyntheticEventMarker)
        e.flags = e.flags.union(extra)
        e.post(tap: .cgSessionEventTap)
    }
}
