import Foundation

public enum IPCCommand: String, Codable, Sendable {
    case enable
    case disable
    case toggle
    case status
    case reload
    case metrics
    case clearStuck
}

public struct StatusSnapshot: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var mappingCount: Int
    public var holdTimeoutMs: Int
    public var layerEnabled: Bool
    public var stuckRecoveries: Int
    public var connectedClients: Int

    public init(
        enabled: Bool,
        mappingCount: Int,
        holdTimeoutMs: Int,
        layerEnabled: Bool,
        stuckRecoveries: Int,
        connectedClients: Int
    ) {
        self.enabled = enabled
        self.mappingCount = mappingCount
        self.holdTimeoutMs = holdTimeoutMs
        self.layerEnabled = layerEnabled
        self.stuckRecoveries = stuckRecoveries
        self.connectedClients = connectedClients
    }
}

public struct MetricsSnapshot: Codable, Sendable, Equatable {
    public var eventsSeen: UInt64
    public var tapsEmitted: UInt64
    public var modifierPromotions: UInt64
    public var queueFlushes: UInt64
    public var tapDisableRecoveries: UInt64
    public var stuckRecoveries: UInt64
    public var callbackMaxUs: UInt64
    public var callbackP99Us: UInt64
    public var slowCallbacks: UInt64

    public init(
        eventsSeen: UInt64,
        tapsEmitted: UInt64,
        modifierPromotions: UInt64,
        queueFlushes: UInt64,
        tapDisableRecoveries: UInt64,
        stuckRecoveries: UInt64,
        callbackMaxUs: UInt64,
        callbackP99Us: UInt64,
        slowCallbacks: UInt64
    ) {
        self.eventsSeen = eventsSeen
        self.tapsEmitted = tapsEmitted
        self.modifierPromotions = modifierPromotions
        self.queueFlushes = queueFlushes
        self.tapDisableRecoveries = tapDisableRecoveries
        self.stuckRecoveries = stuckRecoveries
        self.callbackMaxUs = callbackMaxUs
        self.callbackP99Us = callbackP99Us
        self.slowCallbacks = slowCallbacks
    }
}

public struct StuckEventPayload: Codable, Sendable, Equatable {
    public var key: String
    public var reason: String
}

public struct ConfigReloadedPayload: Codable, Sendable, Equatable {
    public var ok: Bool
    public var errors: [String]
}

public enum DaemonEvent: Codable, Sendable, Equatable {
    case status(StatusSnapshot)
    case metrics(MetricsSnapshot)
    case stuck(key: String, reason: String)
    case configReloaded(ok: Bool, errors: [String])
    case error(String)

    private enum CodingKeys: String, CodingKey {
        case type, payload
    }

    private enum EventType: String, Codable {
        case status, metrics, stuck, configReloaded, error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(EventType.self, forKey: .type)
        switch type {
        case .status:
            self = .status(try container.decode(StatusSnapshot.self, forKey: .payload))
        case .metrics:
            self = .metrics(try container.decode(MetricsSnapshot.self, forKey: .payload))
        case .stuck:
            let payload = try container.decode(StuckEventPayload.self, forKey: .payload)
            self = .stuck(key: payload.key, reason: payload.reason)
        case .configReloaded:
            let payload = try container.decode(ConfigReloadedPayload.self, forKey: .payload)
            self = .configReloaded(ok: payload.ok, errors: payload.errors)
        case .error:
            self = .error(try container.decode(String.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .status(let snapshot):
            try container.encode(EventType.status, forKey: .type)
            try container.encode(snapshot, forKey: .payload)
        case .metrics(let snapshot):
            try container.encode(EventType.metrics, forKey: .type)
            try container.encode(snapshot, forKey: .payload)
        case .stuck(let key, let reason):
            try container.encode(EventType.stuck, forKey: .type)
            try container.encode(StuckEventPayload(key: key, reason: reason), forKey: .payload)
        case .configReloaded(let ok, let errors):
            try container.encode(EventType.configReloaded, forKey: .type)
            try container.encode(ConfigReloadedPayload(ok: ok, errors: errors), forKey: .payload)
        case .error(let message):
            try container.encode(EventType.error, forKey: .type)
            try container.encode(message, forKey: .payload)
        }
    }
}

public enum IPCPaths {
    public static var configDirectory: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".config/macape")
    }

    public static var socketPath: String {
        (configDirectory as NSString).appendingPathComponent("macape.sock")
    }
}
