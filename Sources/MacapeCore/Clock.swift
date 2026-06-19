import Foundation
import ApplicationServices

/// Monotonic clock helpers built on the mach-absolute timebase.
///
/// macOS reports hardware key event times via `CGEvent.timestamp`, which is a
/// mach-absolute timestamp. To measure hold/tap durations *accurately* we must:
///   1. stamp `HRKey.pressTimeMs` from the key-down event's `.timestamp`, and
///   2. compute `held` from the key-up event's `.timestamp`,
/// using the *same* mach→ms conversion for both, and the same conversion for
/// the run-loop timer's `nowMs()`. This keeps the whole state machine on one
/// clock domain regardless of how late the OS delivered each callback.
///
/// These helpers are public so that tests can exercise the real
/// `CGEvent → ms → state-machine` path end-to-end with the *production*
/// conversion code (no untested parallel implementation).
public enum Clock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Current monotonic time in milliseconds (mach-absolute domain).
    public static func nowMs() -> UInt64 {
        machToMs(mach_absolute_time())
    }

    /// High-resolution monotonic microseconds, used only to measure how long a
    /// callback took to *process* (a duration), not for hold/tap timing.
    public static func nowUs() -> UInt64 {
        let mach = mach_absolute_time()
        let ns = mach.multipliedReportingOverflow(by: UInt64(timebase.numer))
        guard !ns.overflow else { return 0 }
        return ns.partialValue / UInt64(timebase.denom) / 1_000
    }

    /// Convert a mach-absolute timestamp (e.g. `CGEvent.timestamp`) to whole
    /// milliseconds. Returns `UInt64.max` on overflow (defensive; unreachable
    /// in practice for real event timestamps).
    public static func machToMs(_ mach: UInt64) -> UInt64 {
        let ns = mach.multipliedReportingOverflow(by: UInt64(timebase.numer))
        guard !ns.overflow else { return UInt64.max }
        return ns.partialValue / UInt64(timebase.denom) / 1_000_000
    }

    /// Inverse of `machToMs`: convert milliseconds to a mach-absolute timestamp.
    /// Primarily for tests that synthesize `CGEvent.timestamp` values at known
    /// millisecond offsets.
    public static func msToMach(_ ms: UInt64) -> UInt64 {
        let ns = ms.multipliedReportingOverflow(by: 1_000_000)
        guard !ns.overflow else { return UInt64.max }
        return ns.partialValue * UInt64(timebase.denom) / UInt64(timebase.numer)
    }

    /// Hardware time of a `CGEvent`, in milliseconds (mach-absolute domain).
    /// This is the single function the hot path uses to derive `nowMs` from a
    /// real key event.
    public static func eventMs(_ event: CGEvent) -> UInt64 {
        machToMs(event.timestamp)
    }
}
