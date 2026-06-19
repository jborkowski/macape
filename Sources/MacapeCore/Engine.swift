import Foundation
import ApplicationServices
import os

private func nowMs() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return UInt64(ts.tv_sec) * 1000 + UInt64(ts.tv_nsec) / 1_000_000
}

private func nowUs() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return UInt64(ts.tv_sec) * 1_000_000 + UInt64(ts.tv_nsec) / 1000
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
    private var snapshot: StateMachineSnapshot
    private let source: CGEventSource
    private var tap: CFMachPort?
    private let runLoop: CFRunLoop
    private var signpostState: OSSignpostIntervalState?

    private init(config: Config) throws {
        self.config = config
        self.snapshot = StateMachineSnapshot(keys: config.mappings.map {
            HRKey(
                keyCode: $0.keyCode,
                modifier: $0.modifier,
                holdTimeoutMs: config.holdTimeout(for: $0),
                tapTimeoutMs: config.tapTimeout(for: $0)
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
        Task {
            let metrics = await Metrics.shared.snapshot()
            _ = metrics
        }
        return StatusSnapshot(
            enabled: snapshot.enabled,
            mappingCount: config.mappings.count,
            holdTimeoutMs: config.holdTimeoutMs,
            tapTimeoutMs: config.tapTimeoutMs,
            layerEnabled: config.layer.enabled,
            stuckRecoveries: 0,
            connectedClients: connectedClients
        )
    }

    public func applyConfig(_ config: Config) {
        performOnRunLoop { [self] in
            let actions = HomeRowStateMachine.resetAll(snapshot: &self.snapshot, layer: self.config.layer)
            self.applyActions(actions)
            self.config = config
            self.snapshot.keys = config.mappings.map {
                HRKey(
                    keyCode: $0.keyCode,
                    modifier: $0.modifier,
                    holdTimeoutMs: config.holdTimeout(for: $0),
                    tapTimeoutMs: config.tapTimeout(for: $0)
                )
            }
        }
    }

    public func setEnabled(_ enabled: Bool) {
        performOnRunLoop { [self] in
            if self.snapshot.enabled == enabled { return }
            let actions = HomeRowStateMachine.resetAll(snapshot: &self.snapshot, layer: self.config.layer)
            self.applyActions(actions)
            self.snapshot.enabled = enabled
        }
    }

    public func clearStuck() {
        performOnRunLoop { [self] in
            let actions = HomeRowStateMachine.resetAll(snapshot: &self.snapshot, layer: self.config.layer)
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

        let interval: CFTimeInterval = 0.010
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
        let start = nowUs()
        defer {
            let elapsed = nowUs() - start
            Task {
                await Metrics.shared.recordCallbackLatency(microseconds: elapsed)
                if elapsed > 5000 {
                    MacapeLog.perf.warning("slow callback \(elapsed)us")
                }
            }
            Task { await Metrics.shared.recordEvent() }
        }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            MacapeLog.engine.error("tap disabled (type=\(type.rawValue)); re-enabling and resetting state")
            Task { await Metrics.shared.recordTapDisableRecovery() }
            if let tap = self.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            let actions = HomeRowStateMachine.resetAll(snapshot: &snapshot, layer: config.layer)
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
        let now = nowMs()

        let actions = HomeRowStateMachine.handleKeyEvent(
            snapshot: &snapshot,
            layer: config.layer,
            keyCode: code,
            down: down,
            isRepeat: isRepeat,
            userMods: userMods,
            nowMs: now
        )

        return applyHandleActions(actions, event: event, existing: existing)
    }

    private func tick() {
        let now = nowMs()
        let actions = HomeRowStateMachine.tick(
            snapshot: &snapshot,
            layer: config.layer,
            maxModifierHoldMs: config.maxModifierHoldMs,
            nowMs: now,
            keyIsPhysicallyDown: { CGEventSource.keyState(.combinedSessionState, key: $0) }
        )
        applyActions(actions)
    }

    private func applyHandleActions(
        _ actions: [EngineAction],
        event: CGEvent,
        existing: CGEventFlags
    ) -> Unmanaged<CGEvent>? {
        var passThrough = false
        var passFlags = existing
        var tapPosts = 0
        for action in actions {
            switch action {
            case .postKey(let code, let down, let flags):
                postKey(code, down: down, extra: flags)
                tapPosts &+= 1
            case .passThrough(let flags):
                passThrough = true
                passFlags = flags
            case .swallow:
                recordTapBatch(tapPosts)
                return nil
            case .stuckRecovery(let key, let reason):
                emitStuck(key: key, reason: reason)
            }
        }
        recordTapBatch(tapPosts)
        if passThrough {
            if !passFlags.isEmpty { event.flags = passFlags }
            return Unmanaged.passUnretained(event)
        }
        return nil
    }

    private func applyActions(_ actions: [EngineAction]) {
        var promoted = false
        for action in actions {
            switch action {
            case .postKey(let code, let down, let flags):
                postKey(code, down: down, extra: flags)
            case .passThrough, .swallow:
                break
            case .stuckRecovery(let key, let reason):
                emitStuck(key: key, reason: reason)
                Task { await Metrics.shared.recordStuckRecovery() }
            }
        }
        if actions.contains(where: {
            if case .postKey = $0 { return true }
            return false
        }) {
            promoted = true
        }
        if promoted {
            Task {
                await Metrics.shared.recordModifierPromotion()
                await Metrics.shared.recordQueueFlush()
            }
        }
    }

    private func recordTapBatch(_ count: Int) {
        guard count > 0 else { return }
        Task {
            for _ in 0..<count {
                await Metrics.shared.recordTap()
            }
        }
    }

    private func emitStuck(key: CGKeyCode, reason: String) {
        let name = Config.keyName(for: key)
        MacapeLog.stuck.error("stuck recovery key=\(name) reason=\(reason)")
        onEvent?(.stuck(key: name, reason: reason))
    }

    private func postKey(_ code: CGKeyCode, down: Bool, extra: CGEventFlags) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        e.flags = e.flags.union(extra)
        e.post(tap: .cgSessionEventTap)
    }
}
