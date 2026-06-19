import Foundation
import Network

public actor ControlServer {
    public typealias CommandHandler = @Sendable (IPCCommand) async -> Void

    private let socketPath: String
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private let onCommand: CommandHandler
    private let onBroadcast: (@Sendable (DaemonEvent) -> Void)?

    public init(
        socketPath: String = IPCPaths.socketPath,
        onCommand: @escaping CommandHandler,
        onBroadcast: (@Sendable (DaemonEvent) -> Void)? = nil
    ) {
        self.socketPath = socketPath
        self.onCommand = onCommand
        self.onBroadcast = onBroadcast
    }

    public func start() throws {
        try FileManager.default.createDirectory(
            atPath: (socketPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(atPath: socketPath)

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)

        let listener = try NWListener(using: params)
        self.listener = listener

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                MacapeLog.ipc.info("control server ready at \(self.socketPath, privacy: .public)")
            case .failed(let error):
                MacapeLog.ipc.error("control server failed: \(error.localizedDescription, privacy: .public)")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }

        listener.start(queue: .global(qos: .userInitiated))
    }

    public func stop() {
        for (_, connection) in connections {
            connection.cancel()
        }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    public var clientCount: Int { connections.count }

    public func broadcast(_ event: DaemonEvent) {
        onBroadcast?(event)
        guard let data = try? encodeEvent(event) else { return }
        for (_, connection) in connections {
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { await self?.remove(id) }
            } else if case .cancelled = state {
                Task { await self?.remove(id) }
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        receive(on: connection, id: id)
    }

    private func remove(_ id: UUID) {
        connections.removeValue(forKey: id)
    }

    private func receive(on connection: NWConnection, id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                Task { await self?.handleIncoming(data, connection: connection) }
            }
            if error != nil || isComplete {
                connection.cancel()
                Task { await self?.remove(id) }
                return
            }
            Task { await self?.receive(on: connection, id: id) }
        }
    }

    private func handleIncoming(_ data: Data, connection: NWConnection) {
        guard let line = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !line.isEmpty else { return }

        guard let commandData = line.data(using: .utf8),
              let command = try? JSONDecoder().decode(IPCCommandEnvelope.self, from: commandData) else {
            send(.error("invalid command"), on: connection)
            return
        }

        Task {
            await onCommand(command.command)
        }
    }

    private func send(_ event: DaemonEvent, on connection: NWConnection) {
        guard let data = try? encodeEvent(event) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func encodeEvent(_ event: DaemonEvent) throws -> Data {
        var data = try JSONEncoder().encode(event)
        data.append(0x0A)
        return data
    }
}

private struct IPCCommandEnvelope: Codable {
    var command: IPCCommand
}

public enum ControlClientError: Error, LocalizedError {
    case connectFailed
    case sendFailed
    case disconnected

    public var errorDescription: String? {
        switch self {
        case .connectFailed: return "failed to connect to macape daemon"
        case .sendFailed: return "failed to send IPC command"
        case .disconnected: return "disconnected from macape daemon"
        }
    }
}

public actor ControlClient {
    private let socketPath: String
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var eventsContinuation: AsyncStream<DaemonEvent>.Continuation?
    private var eventsStream: AsyncStream<DaemonEvent>?
    private var reconnectTask: Task<Void, Never>?
    private var shouldRun = false

    public init(socketPath: String = IPCPaths.socketPath) {
        self.socketPath = socketPath
    }

    public func events() -> AsyncStream<DaemonEvent> {
        if let eventsStream { return eventsStream }
        let stream = AsyncStream<DaemonEvent> { continuation in
            self.eventsContinuation = continuation
        }
        eventsStream = stream
        return stream
    }

    public func start() {
        MacapeLog.debug("ipc client start socket=\(socketPath)")
        shouldRun = true
        reconnectTask?.cancel()
        reconnectTask = Task { await self.connectLoop() }
    }

    public func stop() {
        shouldRun = false
        reconnectTask?.cancel()
        reconnectTask = nil
        connection?.cancel()
        connection = nil
        eventsContinuation?.finish()
    }

    public func send(_ command: IPCCommand) async throws {
        guard let connection else {
            MacapeLog.debug("ipc send \(command) failed: disconnected")
            throw ControlClientError.disconnected
        }
        MacapeLog.debug("ipc send \(command)")
        let envelope = IPCCommandEnvelope(command: command)
        var data = try JSONEncoder().encode(envelope)
        data.append(0x0A)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    MacapeLog.debug("ipc send \(command) failed: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                } else {
                    MacapeLog.debug("ipc send \(command) ok")
                    continuation.resume()
                }
            })
        }
    }

    private func connectLoop() async {
        while shouldRun {
            do {
                MacapeLog.debug("ipc connect attempt socket=\(socketPath)")
                try await connectOnce()
                MacapeLog.debug("ipc connect ready socket=\(socketPath)")
                return
            } catch {
                MacapeLog.ipc.error("connect failed: \(error.localizedDescription, privacy: .public)")
                MacapeLog.debug("ipc connect failed socket=\(socketPath) error=\(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func connectOnce() async throws {
        let connection = NWConnection(to: NWEndpoint.unix(path: socketPath), using: .tcp)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            final class ResumeBox: @unchecked Sendable {
                var done = false
            }
            let box = ResumeBox()
            connection.stateUpdateHandler = { state in
                guard !box.done else { return }
                switch state {
                case .ready:
                    box.done = true
                    continuation.resume()
                case .failed(let error):
                    box.done = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }

        self.connection = connection
        receiveLoop(on: connection)
    }

    private func receiveLoop(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { await self?.handleReceive(data: data, isComplete: isComplete, error: error, connection: connection) }
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: NWError?, connection: NWConnection) {
        if let data, !data.isEmpty {
            receiveBuffer.append(data)
            while let newline = receiveBuffer.firstIndex(of: 0x0A) {
                let lineData = receiveBuffer[..<newline]
                receiveBuffer.removeSubrange(..<newline.advanced(by: 1))
                if let event = try? JSONDecoder().decode(DaemonEvent.self, from: lineData) {
                    eventsContinuation?.yield(event)
                }
            }
        }
        if error != nil || isComplete {
            MacapeLog.debug("ipc receive ended complete=\(isComplete) error=\(error?.localizedDescription ?? "none")")
            connection.cancel()
            self.connection = nil
            if shouldRun {
                reconnectTask = Task { await self.connectLoop() }
            }
            return
        }
        receiveLoop(on: connection)
    }
}
