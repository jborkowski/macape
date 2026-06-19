import Foundation
import os

public enum MacapeLog {
    public static let engine = Logger(subsystem: "com.macape", category: "engine")
    public static let ipc = Logger(subsystem: "com.macape", category: "ipc")
    public static let stuck = Logger(subsystem: "com.macape", category: "stuck")
    public static let perf = Logger(subsystem: "com.macape", category: "perf")

    public static var debugEnabled: Bool {
        let value = ProcessInfo.processInfo.environment["MACAPE_DEBUG"]?.lowercased()
        return value == "1" || value == "true" || value == "yes"
    }

    public static func err(_ message: String) {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    }

    public static func debug(_ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        err("debug: " + message())
    }
}
