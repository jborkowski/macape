import Foundation
import ApplicationServices

public struct Mapping: Sendable, Equatable {
    public let keyCode: CGKeyCode
    public let modifier: CGEventFlags
    public let holdTimeoutMs: Int?
    public let tapTimeoutMs: Int?

    public init(
        keyCode: CGKeyCode,
        modifier: CGEventFlags,
        holdTimeoutMs: Int? = nil,
        tapTimeoutMs: Int? = nil
    ) {
        self.keyCode = keyCode
        self.modifier = modifier
        self.holdTimeoutMs = holdTimeoutMs
        self.tapTimeoutMs = tapTimeoutMs
    }
}

public struct LayerConfig: Sendable, Equatable {
    public var holdKeyCode: CGKeyCode
    public var mappings: [CGKeyCode: CGKeyCode]

    public static let `default` = LayerConfig(
        holdKeyCode: 49, // space
        mappings: [
            38: 123, // j -> left
            40: 125, // k -> down
            37: 126, // l -> up
            41: 124, // ; -> right
        ]
    )

    public init(holdKeyCode: CGKeyCode, mappings: [CGKeyCode: CGKeyCode]) {
        self.holdKeyCode = holdKeyCode
        self.mappings = mappings
    }

    public var enabled: Bool { !mappings.isEmpty }
}

public struct Config: Sendable, Equatable {
    public var holdTimeoutMs: Int
    public var tapTimeoutMs: Int
    public var maxModifierHoldMs: Int
    public var tcpPort: Int?
    public var mappings: [Mapping]
    public var layer: LayerConfig

    public static let defaults = Config(
        holdTimeoutMs: 200,
        tapTimeoutMs: 200,
        maxModifierHoldMs: 10_000,
        tcpPort: nil,
        mappings: [
            Mapping(keyCode: 0x00, modifier: .maskCommand),    // A
            Mapping(keyCode: 0x01, modifier: .maskAlternate),  // S
            Mapping(keyCode: 0x02, modifier: .maskControl),    // D
            Mapping(keyCode: 0x03, modifier: .maskShift),      // F
            Mapping(keyCode: 0x26, modifier: .maskShift),      // J
            Mapping(keyCode: 0x28, modifier: .maskControl),    // K
            Mapping(keyCode: 0x25, modifier: .maskAlternate),  // L
            Mapping(keyCode: 0x29, modifier: .maskCommand),    // ;
        ],
        layer: .default
    )

    public init(
        holdTimeoutMs: Int,
        tapTimeoutMs: Int,
        maxModifierHoldMs: Int,
        tcpPort: Int?,
        mappings: [Mapping],
        layer: LayerConfig
    ) {
        self.holdTimeoutMs = holdTimeoutMs
        self.tapTimeoutMs = tapTimeoutMs
        self.maxModifierHoldMs = maxModifierHoldMs
        self.tcpPort = tcpPort
        self.mappings = mappings
        self.layer = layer
    }

    public func holdTimeout(for mapping: Mapping) -> Int {
        mapping.holdTimeoutMs ?? holdTimeoutMs
    }

    public func tapTimeout(for mapping: Mapping) -> Int {
        mapping.tapTimeoutMs ?? tapTimeoutMs
    }

    private static let keycaps: [String: CGKeyCode] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
        "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
        "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "o": 0x1F,
        "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28,
        "n": 0x2D, "m": 0x2E, "space": 49,
        ";": 0x29, "'": 0x27, ",": 0x2B, ".": 0x2F, "/": 0x2C,
        "[": 0x21, "]": 0x1E, "\\": 0x2A, "-": 0x1B, "=": 0x18, "`": 0x32,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]

    private static let modifiers: [String: CGEventFlags] = [
        "lcmd": .maskCommand, "rcmd": .maskCommand,
        "cmd": .maskCommand, "command": .maskCommand,
        "lmet": .maskCommand, "rmet": .maskCommand,
        "lalt": .maskAlternate, "ralt": .maskAlternate,
        "alt": .maskAlternate, "option": .maskAlternate, "opt": .maskAlternate,
        "lctl": .maskControl, "rctl": .maskControl,
        "ctl": .maskControl, "ctrl": .maskControl, "control": .maskControl,
        "lsft": .maskShift, "rsft": .maskShift,
        "sft": .maskShift, "shift": .maskShift,
    ]

    public static func load(from path: String) -> (Config, Bool, [String]) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return (.defaults, false, [])
        }

        var hold = defaults.holdTimeoutMs
        var tap = defaults.tapTimeoutMs
        var maxHold = defaults.maxModifierHoldMs
        var tcpPort: Int? = nil
        var mappings: [Mapping] = []
        var layerHold: CGKeyCode = LayerConfig.default.holdKeyCode
        var layerMappings: [CGKeyCode: CGKeyCode] = LayerConfig.default.mappings
        var inLayerSection = false
        var lineNo = 0
        var errors: [String] = []

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNo += 1
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                let section = trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespaces).lowercased()
                inLayerSection = section == "layer space" || section == "layer"
                continue
            }

            guard let eq = trimmed.firstIndex(of: "=") else {
                let msg = "\(path):\(lineNo): missing '='"
                errors.append(msg)
                MacapeLog.err("macape: \(msg)")
                continue
            }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let val = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces).lowercased()

            if inLayerSection {
                if key == "hold" {
                    if let kc = keycaps[val] {
                        layerHold = kc
                    } else {
                        let msg = "\(path):\(lineNo): unknown layer hold key '\(val)'"
                        errors.append(msg)
                        MacapeLog.err("macape: \(msg)")
                    }
                    continue
                }
                guard let src = keycaps[key] else {
                    let msg = "\(path):\(lineNo): unknown layer key '\(key)'"
                    errors.append(msg)
                    MacapeLog.err("macape: \(msg)")
                    continue
                }
                guard let dst = keycaps[val] else {
                    let msg = "\(path):\(lineNo): unknown layer target '\(val)'"
                    errors.append(msg)
                    MacapeLog.err("macape: \(msg)")
                    continue
                }
                layerMappings[src] = dst
                continue
            }

            switch key {
            case "hold_timeout_ms":
                if let n = Int(val), n > 0 { hold = n }
            case "tap_timeout_ms":
                if let n = Int(val), n > 0 { tap = n }
            case "max_modifier_hold_ms":
                if let n = Int(val), n > 0 { maxHold = n }
            case "tcp_port":
                if let n = Int(val), n > 0 { tcpPort = n }
            default:
                guard let kc = keycaps[key] else {
                    let msg = "\(path):\(lineNo): unknown key '\(key)'"
                    errors.append(msg)
                    MacapeLog.err("macape: \(msg)")
                    continue
                }
                let parts = val.split(whereSeparator: \.isWhitespace).map(String.init)
                guard let modName = parts.first, let mod = modifiers[modName] else {
                    let msg = "\(path):\(lineNo): unknown modifier '\(val)'"
                    errors.append(msg)
                    MacapeLog.err("macape: \(msg)")
                    continue
                }
                var perHold: Int? = nil
                var perTap: Int? = nil
                if parts.count > 1, let n = Int(parts[1]), n > 0 { perHold = n }
                if parts.count > 2, let n = Int(parts[2]), n > 0 { perTap = n }
                mappings.append(Mapping(
                    keyCode: kc,
                    modifier: mod,
                    holdTimeoutMs: perHold,
                    tapTimeoutMs: perTap
                ))
            }
        }

        if mappings.isEmpty { mappings = defaults.mappings }
        let layer = LayerConfig(holdKeyCode: layerHold, mappings: layerMappings)
        return (
            Config(
                holdTimeoutMs: hold,
                tapTimeoutMs: tap,
                maxModifierHoldMs: maxHold,
                tcpPort: tcpPort,
                mappings: mappings,
                layer: layer
            ),
            true,
            errors
        )
    }

    public static func keyName(for keyCode: CGKeyCode) -> String {
        for (name, code) in keycaps where code == keyCode {
            return name
        }
        return "0x\(String(keyCode, radix: 16))"
    }
}
