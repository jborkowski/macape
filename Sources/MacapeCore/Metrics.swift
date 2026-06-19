import Foundation
import os

public actor Metrics {
    public static let shared = Metrics()

    private var eventsSeen: UInt64 = 0
    private var tapsEmitted: UInt64 = 0
    private var modifierPromotions: UInt64 = 0
    private var queueFlushes: UInt64 = 0
    private var tapDisableRecoveries: UInt64 = 0
    private var stuckRecoveries: UInt64 = 0
    private var slowCallbacks: UInt64 = 0

    private var latencyRing: [UInt64] = []
    private let ringCapacity = 256
    private var callbackMaxUs: UInt64 = 0

    private let signposter = OSSignposter(subsystem: "com.macape", category: "perf")

    public func recordEvent() {
        eventsSeen &+= 1
    }

    public func recordTap() {
        tapsEmitted &+= 1
    }

    public func recordModifierPromotion() {
        modifierPromotions &+= 1
    }

    public func recordQueueFlush() {
        queueFlushes &+= 1
    }

    public func recordTapDisableRecovery() {
        tapDisableRecoveries &+= 1
    }

    public func recordStuckRecovery() {
        stuckRecoveries &+= 1
    }

    public func recordCallbackLatency(microseconds: UInt64) {
        if microseconds > callbackMaxUs { callbackMaxUs = microseconds }
        if microseconds > 5000 { slowCallbacks &+= 1 }
        latencyRing.append(microseconds)
        if latencyRing.count > ringCapacity {
            latencyRing.removeFirst(latencyRing.count - ringCapacity)
        }
    }

    public func snapshot() -> MetricsSnapshot {
        let sorted = latencyRing.sorted()
        let p99: UInt64
        if sorted.isEmpty {
            p99 = 0
        } else {
            let idx = min(sorted.count - 1, Int(Double(sorted.count) * 0.99))
            p99 = sorted[idx]
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

    public func beginCallbackInterval() -> OSSignpostIntervalState {
        signposter.beginInterval("callback")
    }

    public func endCallbackInterval(_ state: OSSignpostIntervalState, microseconds: UInt64) {
        signposter.endInterval("callback", state)
        recordCallbackLatency(microseconds: microseconds)
    }
}
