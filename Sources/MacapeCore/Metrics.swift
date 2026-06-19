import Foundation
import os

/// Light-weight, lock-protected metrics.
///
/// The event-tap callback runs on the run-loop thread for *every* key event, so
/// metrics recording must be cheap and must not hop to another thread. The
/// previous design was a Swift `actor`: every event spawned `Task { await ... }`
/// hops, which under fast typing produced allocation churn and actor contention
/// on the very thread that has to service the event tap — itself a source of
/// timing jitter (and a risk of macOS disabling a slow tap).
///
/// This class records synchronously via an unfair lock (nanoseconds, uncontended
/// on the single run-loop writer). Reads from IPC happen rarely and on a
/// different queue, so the lock guards both paths.
public final class Metrics: @unchecked Sendable {
    public static let shared = Metrics()

    private let lock = OSAllocatedUnfairLock()

    // Cumulative counters.
    private var eventsSeen: UInt64 = 0
    private var tapsEmitted: UInt64 = 0
    private var modifierPromotions: UInt64 = 0
    private var queueFlushes: UInt64 = 0
    private var tapDisableRecoveries: UInt64 = 0
    private var stuckRecoveries: UInt64 = 0
    private var slowCallbacks: UInt64 = 0
    private var callbackMaxUs: UInt64 = 0

    // Fixed-capacity latency ring buffer (overwrites oldest). Avoids the
    // O(n) array shifts the previous implementation did on every sample.
    private let ringCapacity = 256
    private var ring: [UInt64]
    private var ringCount: Int = 0
    private var ringHead: Int = 0 // next write index

    private init() {
        ring = [UInt64](repeating: 0, count: ringCapacity)
    }

    public func recordEvent() {
        lock.withLock { eventsSeen &+= 1 }
    }

    public func recordTap(count: Int = 1) {
        guard count > 0 else { return }
        lock.withLock { tapsEmitted &+= UInt64(count) }
    }

    public func recordModifierPromotion(count: Int = 1) {
        guard count > 0 else { return }
        lock.withLock { modifierPromotions &+= UInt64(count) }
    }

    public func recordQueueFlush(count: Int = 1) {
        guard count > 0 else { return }
        lock.withLock { queueFlushes &+= UInt64(count) }
    }

    public func recordTapDisableRecovery() {
        lock.withLock { tapDisableRecoveries &+= 1 }
    }

    public func recordStuckRecovery() {
        lock.withLock { stuckRecoveries &+= 1 }
    }

    public func recordCallbackLatency(microseconds: UInt64) {
        lock.withLock {
            if microseconds > callbackMaxUs { callbackMaxUs = microseconds }
            if microseconds > 5000 { slowCallbacks &+= 1 }
            ring[ringHead] = microseconds
            ringHead = (ringHead + 1) % ringCapacity
            if ringCount < ringCapacity { ringCount &+= 1 }
        }
    }

    public func snapshot() -> MetricsSnapshot {
        lock.withLock {
            // Reconstruct samples in insertion order (oldest first).
            var samples: [UInt64] = []
            samples.reserveCapacity(ringCount)
            if ringCount < ringCapacity {
                samples = Array(ring.prefix(ringCount))
            } else {
                samples = Array(ring[ringHead..<ringCapacity])
                samples.append(contentsOf: ring[0..<ringHead])
            }

            let p99: UInt64
            if samples.isEmpty {
                p99 = 0
            } else {
                samples.sort()
                let idx = min(samples.count - 1, Int(Double(samples.count) * 0.99))
                p99 = samples[idx]
            }
            return MetricsSnapshot(
                eventsSeen: eventsSeen,
                tapsEmitted: tapsEmitted,
                modifierPromotions: modifierPromotions,
                queueFlushes: queueFlushes,
                tapDisableRecoveries: tapDisableRecoveries,
                stuckRecoveries: stuckRecoveries,
                callbackMaxUs: callbackMaxUs,
                callbackP99Us: p99,
                slowCallbacks: slowCallbacks
            )
        }
    }
}
