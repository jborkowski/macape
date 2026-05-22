import Foundation

func err(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

let argv = CommandLine.arguments
var configOverride: String? = nil
var i = 1
while i < argv.count {
    let arg = argv[i]
    switch arg {
    case "-c":
        guard i + 1 < argv.count else {
            err("macape: -c requires a path")
            exit(2)
        }
        configOverride = argv[i + 1]
        i += 2
    case "-h", "--help":
        print("Usage: \(argv[0]) [-c <config_path>]")
        print("Default config: ~/.config/macape/macape.conf")
        exit(0)
    default:
        err("macape: unknown argument '\(arg)'")
        exit(2)
    }
}

let resolvedPath = configOverride
    ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config/macape/macape.conf")

let (config, loaded) = Config.load(from: resolvedPath)
err("macape: config \(resolvedPath) (\(loaded ? "loaded" : "not found — using built-in defaults"))")

let engine: Engine
do {
    engine = try Engine.start(config: config)
} catch {
    err("macape: \(error.localizedDescription)")
    err("Grant Accessibility in System Settings > Privacy & Security > Accessibility, then re-run.")
    exit(1)
}

err("macape: \(config.mappings.count) mapping(s) active, hold_timeout = \(config.holdTimeoutMs) ms.")
err("  Ctrl+C to quit.")

withExtendedLifetime(engine) {
    CFRunLoopRun()
}
