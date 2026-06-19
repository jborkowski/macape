import Foundation
import os

public enum MacapeLog {
    public static let engine = Logger(subsystem: "com.macape", category: "engine")
    public static let ipc = Logger(subsystem: "com.macape", category: "ipc")
    public static let stuck = Logger(subsystem: "com.macape", category: "stuck")
    public static let perf = Logger(subsystem: "com.macape", category: "perf")

    public static func err(_ message: String) {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    }
}
