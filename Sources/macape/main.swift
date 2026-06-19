import Foundation
import MacapeCore

private final class SignalResumeBox: @unchecked Sendable {
    private var didResume = false

    func resumeOnce(_ continuation: CheckedContinuation<Void, Never>) {
        guard !didResume else { return }
        didResume = true
        continuation.resume()
    }
}

@main
enum MacapeMain {
    static func main() async {
        let argv = CommandLine.arguments
        var configOverride: String? = nil
        var showStats = false
        var i = 1
        while i < argv.count {
            let arg = argv[i]
            switch arg {
            case "-c":
                guard i + 1 < argv.count else {
                    MacapeLog.err("macape: -c requires a path")
                    exit(2)
                }
                configOverride = argv[i + 1]
                i += 2
            case "--stats":
                showStats = true
                i += 1
            case "-h", "--help":
                print("Usage: \(argv[0]) [-c <config_path>] [--stats]")
                print("Default config: ~/.config/macape/macape.conf")
                exit(0)
            default:
                MacapeLog.err("macape: unknown argument '\(arg)'")
                exit(2)
            }
        }

        if showStats {
            await printStats()
            return
        }

        let resolvedPath = configOverride
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config/macape/macape.conf")

        do {
            try await runDaemon(configPath: resolvedPath)
        } catch {
            MacapeLog.err("macape: \(error.localizedDescription)")
            MacapeLog.err("Grant Accessibility in System Settings > Privacy & Security > Accessibility, then re-run.")
            exit(1)
        }
    }

    private static func runDaemon(configPath: String) async throws {
        let (config, loaded, loadErrors) = Config.load(from: configPath)
        MacapeLog.err("macape: config \(configPath) (\(loaded ? "loaded" : "not found — using built-in defaults"))")
        if !loadErrors.isEmpty {
            MacapeLog.err("macape: config warnings: \(loadErrors.count)")
        }

        let engine = try Engine.start(config: config)

        final class Holder: @unchecked Sendable {
            var server: ControlServer?
            var configPath: String
            var config: Config

            init(configPath: String, config: Config) {
                self.configPath = configPath
                self.config = config
            }
        }
        let holder = Holder(configPath: configPath, config: config)

        let server = ControlServer { command in
            guard let server = holder.server else { return }
            switch command {
            case .enable:
                engine.setEnabled(true)
            case .disable:
                engine.setEnabled(false)
            case .toggle:
                engine.setEnabled(!engine.enabled)
            case .clearStuck:
                engine.clearStuck()
            case .reload:
                let (newConfig, _, errors) = Config.load(from: holder.configPath)
                holder.config = newConfig
                engine.applyConfig(newConfig)
                await server.broadcast(.configReloaded(ok: errors.isEmpty, errors: errors))
            case .status, .metrics:
                break
            }
            await publish(engine: engine, server: server, includeMetrics: command == .metrics || command == .status)
        }
        holder.server = server

        engine.onEvent = { event in
            Task { await server.broadcast(event) }
        }

        try await server.start()
        await publish(engine: engine, server: server, includeMetrics: true)

        MacapeLog.err("macape: \(holder.config.mappings.count) mapping(s) active, hold_timeout = \(holder.config.holdTimeoutMs) ms.")
        MacapeLog.err("macape: IPC socket at \(IPCPaths.socketPath)")
        MacapeLog.err("  Ctrl+C to quit.")

        let runLoop = CFRunLoopGetMain()
        let resumeBox = SignalResumeBox()
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let signalSources = [SIGINT, SIGTERM].map { sig in
            DispatchSource.makeSignalSource(signal: sig, queue: .main)
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            for source in signalSources {
                source.setEventHandler {
                    resumeBox.resumeOnce(continuation)
                    CFRunLoopStop(runLoop)
                }
                source.resume()
            }
            CFRunLoopRun()
        }

        for source in signalSources {
            source.cancel()
        }
        await server.stop()
    }

    private static func publish(engine: Engine, server: ControlServer, includeMetrics: Bool) async {
        let metrics = await Metrics.shared.snapshot()
        var status = engine.statusSnapshot(connectedClients: await server.clientCount)
        status.stuckRecoveries = Int(metrics.stuckRecoveries)
        await server.broadcast(.status(status))
        if includeMetrics {
            await server.broadcast(.metrics(metrics))
        }
    }

    private static func printStats() async {
        let client = ControlClient()
        await client.start()

        var printed = false
        let collect = Task {
            for await event in await client.events() {
                switch event {
                case .status(let s):
                    MacapeLog.err("status: enabled=\(s.enabled) mappings=\(s.mappingCount) stuck=\(s.stuckRecoveries)")
                case .metrics(let m):
                    MacapeLog.err("metrics: events=\(m.eventsSeen) promotions=\(m.modifierPromotions) stuck=\(m.stuckRecoveries) p99=\(m.callbackP99Us)us")
                    printed = true
                case .error(let message):
                    MacapeLog.err("error: \(message)")
                default:
                    break
                }
            }
        }

        try? await Task.sleep(nanoseconds: 200_000_000)
        do {
            try await client.send(.status)
            try await client.send(.metrics)
        } catch {
            MacapeLog.err("macape: \(error.localizedDescription)")
            collect.cancel()
            await client.stop()
            exit(1)
        }

        for _ in 0..<10 where !printed {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        collect.cancel()
        await client.stop()
    }
}
