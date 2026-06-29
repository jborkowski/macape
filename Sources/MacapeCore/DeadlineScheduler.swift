import Foundation

/// One-shot timer aligned to the mach-absolute clock (same domain as
/// `CGEvent.timestamp` and `mach_absolute_time()`).
///
/// libdispatch's `DISPATCH_TIME_NOW` is derived from mach-absolute time on
/// macOS, so a `DispatchSourceTimer` scheduled as `.now() + machDelta` pauses
/// during system sleep — matching hold/tap deadline semantics.
public final class DeadlineScheduler: @unchecked Sendable {
    private let queue: DispatchQueue
    private var source: DispatchSourceTimer?

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    public func cancel() {
        source?.cancel()
        source = nil
    }

    /// Schedule a one-shot callback at `deadlineMach`, or invoke immediately if
    /// the deadline has already passed. Pass `nil` to cancel any pending timer.
    public func schedule(deadlineMach: UInt64?, handler: @escaping @Sendable () -> Void) {
        cancel()
        guard let deadlineMach else { return }

        let nowMach = mach_absolute_time()
        if deadlineMach <= nowMach {
            queue.async(execute: handler)
            return
        }

        let deltaMach = deadlineMach &- nowMach
        let delayNs = Clock.machDeltaToNanoseconds(deltaMach)
        guard delayNs > 0 else {
            queue.async(execute: handler)
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Cap to Int.max nanoseconds (~2s on typical hardware) — hold timeouts
        // are at most tens of seconds; split is unnecessary at macape scales.
        let clampedNs = min(delayNs, UInt64(Int.max))
        timer.schedule(
            deadline: .now() + .nanoseconds(Int(clampedNs)),
            leeway: .milliseconds(1)
        )
        timer.setEventHandler(handler: handler)
        timer.resume()
        source = timer
    }
}
