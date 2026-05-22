import Foundation
import ApplicationServices

private enum HRState { case idle, pending, modifier }

private struct DefEvent {
    var keycode: CGKeyCode
    var down: Bool
    var flags: CGEventFlags
}

private struct HRKey {
    let keyCode: CGKeyCode
    let modifier: CGEventFlags
    var state: HRState = .idle
    var pressTimeMs: UInt64 = 0
}

private func nowMs() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return UInt64(ts.tv_sec) * 1000 + UInt64(ts.tv_nsec) / 1_000_000
}

private let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
    let engine = Unmanaged<Engine>.fromOpaque(refcon).takeUnretainedValue()
    return engine.handle(type: type, event: event)
}

final class Engine {
    enum StartError: Error, LocalizedError {
        case sourceCreate
        case tapCreate
        var errorDescription: String? {
            switch self {
            case .sourceCreate: return "CGEventSource creation failed"
            case .tapCreate:    return "CGEventTapCreate failed"
            }
        }
    }

    private var keys: [HRKey]
    private var queue: [DefEvent] = []
    private let holdTimeoutMs: Int
    private let source: CGEventSource
    private var tap: CFMachPort?

    private init(config: Config) throws {
        self.keys = config.mappings.map {
            HRKey(keyCode: $0.keyCode, modifier: $0.modifier)
        }
        self.holdTimeoutMs = config.holdTimeoutMs
        guard let src = CGEventSource(stateID: .hidSystemState) else {
            throw StartError.sourceCreate
        }
        self.source = src
    }

    static func start(config: Config) throws -> Engine {
        let engine = try Engine(config: config)
        try engine.install()
        return engine
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
        CFRunLoopAddSource(CFRunLoopGetCurrent(), rls, .commonModes)
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
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            err("macape: tap disabled (type=\(type.rawValue)); re-enabling")
            if let tap = self.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }

        let code: CGKeyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let down = (type == .keyDown)
        let existing = event.flags
        let userMods = existing.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])

        let hrIdx = keys.firstIndex(where: { $0.keyCode == code })

        // Don't second-guess a real modifier the user is already holding.
        if !userMods.isEmpty, hrIdx != nil {
            event.flags = existing.union(activeModifiers())
            return Unmanaged.passUnretained(event)
        }

        if let idx = hrIdx {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

            if down {
                if isRepeat { return nil }
                if keys[idx].state != .idle { return nil }

                if anyPending() {
                    queue.append(DefEvent(keycode: code, down: true, flags: []))
                    return nil
                }
                keys[idx].state = .pending
                keys[idx].pressTimeMs = nowMs()
                return nil
            }

            switch keys[idx].state {
            case .pending:
                var batch: [DefEvent] = [
                    DefEvent(keycode: code, down: true,  flags: []),
                    DefEvent(keycode: code, down: false, flags: []),
                ]
                batch.append(contentsOf: queue)
                queue.removeAll(keepingCapacity: true)
                keys[idx].state = .idle

                let mods = activeModifiers()
                for e in batch { postKey(e.keycode, down: e.down, extra: e.flags.union(mods)) }
                return nil

            case .modifier:
                keys[idx].state = .idle
                return nil

            case .idle:
                if anyPending() {
                    queue.append(DefEvent(keycode: code, down: false, flags: []))
                    return nil
                }
                event.flags = existing.union(activeModifiers())
                return Unmanaged.passUnretained(event)
            }
        }

        if anyPending() {
            queue.append(DefEvent(keycode: code, down: down, flags: existing))
            return nil
        }

        let mods = activeModifiers()
        if !mods.isEmpty { event.flags = existing.union(mods) }
        return Unmanaged.passUnretained(event)
    }

    private func tick() {
        let now = nowMs()
        var promoted = false
        for i in keys.indices {
            if keys[i].state == .pending &&
               now - keys[i].pressTimeMs >= UInt64(holdTimeoutMs) {
                keys[i].state = .modifier
                promoted = true
            }
        }
        if promoted { flush(extra: activeModifiers()) }
    }

    private func anyPending() -> Bool {
        keys.contains(where: { $0.state == .pending })
    }

    private func activeModifiers() -> CGEventFlags {
        keys.reduce(into: CGEventFlags()) { acc, k in
            if k.state == .modifier { acc.formUnion(k.modifier) }
        }
    }

    private func postKey(_ code: CGKeyCode, down: Bool, extra: CGEventFlags) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        e.flags = e.flags.union(extra)
        e.post(tap: .cgSessionEventTap)
    }

    private func flush(extra: CGEventFlags) {
        for e in queue {
            postKey(e.keycode, down: e.down, extra: e.flags.union(extra))
        }
        queue.removeAll(keepingCapacity: true)
    }
}
