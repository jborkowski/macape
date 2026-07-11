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
        case .postKey(let code, let down, let flags, _):
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
    private var snapshot: PipelineSnapshot
    private let source: CGEventSource
    private var tap: CFMachPort?
    private let deadlineScheduler = DeadlineScheduler()
    private let runLoop: CFRunLoop

    private init(config: Config) throws {
        self.config = config
        self.snapshot = PipelineSnapshot(keys: config.mappings.map {
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
            let actions = Pipeline.resetAll(snapshot: &self.snapshot, layer: self.config.layer, swaps: self.config.swaps)
            self.applyActions(actions)
            self.config = config
            self.snapshot.keys = config.mappings.map {
                HRKey(
                    keyCode: $0.keyCode,
                    modifier: $0.modifier,
                    holdTimeoutMs: config.holdTimeout(for: $0)
                )
            }
            self.rescheduleDeadlineTimer()
        }
    }

    public func setEnabled(_ enabled: Bool) {
        performOnRunLoop { [self] in
            if self.snapshot.enabled == enabled { return }
            let actions = Pipeline.resetAll(snapshot: &self.snapshot, layer: self.config.layer, swaps: self.config.swaps)
            self.applyActions(actions)
            self.snapshot.enabled = enabled
            self.rescheduleDeadlineTimer()
        }
    }

    public func clearStuck() {
        performOnRunLoop { [self] in
            let actions = Pipeline.resetAll(snapshot: &self.snapshot, layer: self.config.layer, swaps: self.config.swaps)
            self.applyActions(actions)
            self.rescheduleDeadlineTimer()
        }
    }

    /// Called when macOS resumes from sleep. Resets virtual modifier/buffer
    /// state (key-ups are often lost across sleep) and re-enables the event tap.
    public func handleSystemWake() {
        performOnRunLoop { [self] in
            MacapeLog.engine.info("system wake: resetting pipeline state")
            if let tap = self.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            let actions = Pipeline.resetAll(
                snapshot: &self.snapshot,
                layer: self.config.layer,
                swaps: self.config.swaps,
                reason: "system wake"
            )
            self.applyActions(actions)
            self.rescheduleDeadlineTimer()
        }
    }

    /// Called before macOS sleeps. Cancels the mach-aligned deadline timer so a
    /// stale wall-clock callback cannot fire on wake before the next key event.
    public func handleSystemWillSleep() {
        performOnRunLoop { [self] in
            MacapeLog.engine.info("system will sleep: cancelling deadline timer")
            self.deadlineScheduler.cancel()
        }
    }

    public func performOnRunLoop(_ block: @escaping @Sendable () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    private func install() throws {
        let bit: (CGEventType) -> CGEventMask = { CGEventMask(1) << CGEventMask($0.rawValue) }
        let mask = bit(.keyDown) | bit(.keyUp) | bit(.flagsChanged)

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        var tap: CFMachPort?
        let attempts = 6
        for attempt in 1...attempts {
            tap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: tapCallback,
                userInfo: refcon
            )
            if tap != nil { break }
            MacapeLog.engine.error("CGEventTapCreate failed (attempt \(attempt)/\(attempts)); retrying in 0.5s")
            if attempt < attempts { usleep(500_000) }
        }
        guard let tap else {
            throw StartError.tapCreate
        }
        self.tap = tap

        let rls = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(runLoop, rls, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let start = Clock.nowUs()
        defer {
            let elapsed = Clock.nowUs() - start
            Metrics.shared.recordCallbackLatency(microseconds: elapsed)
            Metrics.shared.recordEvent()
            if elapsed > 5000 {
                MacapeLog.perf.warning("slow callback \(elapsed)us")
            }
        }

        if event.getIntegerValueField(.eventSourceUserData) == EventSink.syntheticEventMarker {
            return Unmanaged.passUnretained(event)
        }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            MacapeLog.engine.error("tap disabled (type=\(type.rawValue)); re-enabling and resetting state")
            Metrics.shared.recordTapDisableRecovery()
            if let tap = self.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            let actions = Pipeline.resetAll(snapshot: &snapshot, layer: config.layer, swaps: config.swaps)
            applyActions(actions)
            rescheduleDeadlineTimer()
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown || type == .keyUp || type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        let code: CGKeyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let existing = event.flags

        let down: Bool
        let isRepeat: Bool
        if type == .flagsChanged {
            guard snapshot.enabled,
                  config.swaps.mappings[code] != nil,
                  let flag = FeatureRouter.modifierKeyFlags[code] else {
                return Unmanaged.passUnretained(event)
            }
            down = existing.contains(flag)
            isRepeat = false
        } else {
            down = (type == .keyDown)
            isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        }

        let frame = EventFrame(from: event, keyCode: code, down: down, isRepeat: isRepeat)

        let beforeMods = TimeWheel.activeModifiers(snapshot.keys)
        let beforeStates = snapshot.keys.map { "0x\(String($0.keyCode, radix: 16))=\($0.state)" }.joined(separator: " ")
        var outcome = Pipeline.process(
            snapshot: &snapshot,
            layer: config.layer,
            swaps: config.swaps,
            frame: frame
        )
        if TimeWheel.anyModifier(snapshot.keys) {
            let desync = Pipeline.checkModifierDesync(
                snapshot: &snapshot,
                maxModifierHoldMs: config.maxModifierHoldMs,
                nowMach: frame.machTime,
                keyIsPhysicallyDown: { CGEventSource.keyState(.combinedSessionState, key: $0) }
            )
            if !desync.actions.isEmpty {
                outcome.actions.append(contentsOf: desync.actions)
            }
        }
        let afterMods = TimeWheel.activeModifiers(snapshot.keys)
        let afterStates = snapshot.keys.map { "0x\(String($0.keyCode, radix: 16))=\($0.state)" }.joined(separator: " ")
        MacapeLog.debug("key code=0x\(String(code, radix: 16)) \(down ? "down" : "up") repeat=\(isRepeat) userMods=\(describeFlags(frame.userMods)) activeBefore=\(describeFlags(beforeMods)) activeAfter=\(describeFlags(afterMods)) statesBefore=[\(beforeStates)] statesAfter=[\(afterStates)] actions=[\(describeActions(outcome.actions))]")

        rescheduleDeadlineTimer()
        return applyHandleActions(outcome, event: event, existing: existing)
    }

    private func fireDeadlineTimer() {
        let nowMach = mach_absolute_time()
        let outcome = Pipeline.advanceTime(
            snapshot: &snapshot,
            maxModifierHoldMs: config.maxModifierHoldMs,
            nowMach: nowMach,
            keyIsPhysicallyDown: { CGEventSource.keyState(.combinedSessionState, key: $0) }
        )
        applyTimerActions(outcome)
        rescheduleDeadlineTimer()
    }

    private func rescheduleDeadlineTimer() {
        TimeWheel.rescheduleNextDeadline(
            keys: snapshot.keys,
            maxModifierHoldMs: config.maxModifierHoldMs,
            scheduler: deadlineScheduler
        ) { [unowned self] in
            self.fireDeadlineTimer()
        }
    }

    private func applyHandleActions(
        _ outcome: KeyEventOutcome,
        event: CGEvent,
        existing: CGEventFlags
    ) -> Unmanaged<CGEvent>? {
        var tapPosts = 0
        var recoveries = 0
        let result = EventSink.applyActions(
            outcome,
            event: event,
            existing: existing,
            source: source
        ) { key, reason in
            emitStuck(key: key, reason: reason)
            recoveries &+= 1
        }

        for action in outcome.actions {
            if case .postKey = action { tapPosts &+= 1 }
        }

        recordActionMetrics(
            taps: tapPosts,
            modifierPromotions: outcome.modifierPromotions,
            queueFlushes: outcome.queueFlushes,
            recoveries: recoveries
        )

        if result.swallowed {
            return nil
        }
        if result.passThrough {
            if !result.passFlags.isEmpty { event.flags = result.passFlags }
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
        EventSink.applyTimerActions(outcome, source: source) { key, reason in
            emitStuck(key: key, reason: reason)
            recoveries &+= 1
        }
        for action in outcome.actions {
            if case .postKey = action { taps &+= 1 }
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

    private func applyTimerActions(_ outcome: KeyEventOutcome) {
        applyActions(outcome)
    }

    private func emitStuck(key: CGKeyCode, reason: String) {
        let name = Config.keyName(for: key)
        MacapeLog.stuck.error("stuck recovery key=\(name) reason=\(reason)")
        onEvent?(.stuck(key: name, reason: reason))
    }
}
