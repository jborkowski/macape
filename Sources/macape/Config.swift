import Foundation
import ApplicationServices

struct Mapping {
    let keyCode: CGKeyCode
    let modifier: CGEventFlags
}

struct Config {
    var holdTimeoutMs: Int
    var mappings: [Mapping]

    static let defaults = Config(
        holdTimeoutMs: 200,
        mappings: [
            Mapping(keyCode: 0x00, modifier: .maskCommand),    // A
            Mapping(keyCode: 0x01, modifier: .maskAlternate),  // S
            Mapping(keyCode: 0x02, modifier: .maskControl),    // D
            Mapping(keyCode: 0x03, modifier: .maskShift),      // F
            Mapping(keyCode: 0x26, modifier: .maskShift),      // J
            Mapping(keyCode: 0x28, modifier: .maskControl),    // K
            Mapping(keyCode: 0x25, modifier: .maskAlternate),  // L
            Mapping(keyCode: 0x29, modifier: .maskCommand),    // ;
        ]
    )

    private static let keycaps: [String: CGKeyCode] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
        "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
        "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "o": 0x1F,
        "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28,
        "n": 0x2D, "m": 0x2E,
        ";": 0x29, "'": 0x27, ",": 0x2B, ".": 0x2F, "/": 0x2C,
        "[": 0x21, "]": 0x1E, "\\": 0x2A, "-": 0x1B, "=": 0x18, "`": 0x32,
    ]

    private static let modifiers: [String: CGEventFlags] = [
        "lcmd": .maskCommand,    "rcmd": .maskCommand,
        "cmd":  .maskCommand,    "command": .maskCommand,
        "lmet": .maskCommand,    "rmet": .maskCommand,
        "lalt": .maskAlternate,  "ralt": .maskAlternate,
        "alt":  .maskAlternate,  "option": .maskAlternate,  "opt": .maskAlternate,
        "lctl": .maskControl,    "rctl": .maskControl,
        "ctl":  .maskControl,    "ctrl": .maskControl,      "control": .maskControl,
        "lsft": .maskShift,      "rsft": .maskShift,
        "sft":  .maskShift,      "shift": .maskShift,
    ]

    static func load(from path: String) -> (Config, Bool) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return (.defaults, false)
        }

        var hold = defaults.holdTimeoutMs
        var mappings: [Mapping] = []
        var lineNo = 0

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNo += 1
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            guard let eq = trimmed.firstIndex(of: "=") else {
                err("macape: \(path):\(lineNo): missing '='")
                continue
            }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let val = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces).lowercased()

            switch key {
            case "hold_timeout_ms":
                if let n = Int(val), n > 0 { hold = n }
            case "tap_timeout_ms":
                // accepted for kanata-style parity; release-vs-timeout decides taps
                break
            default:
                guard let kc = keycaps[key] else {
                    err("macape: \(path):\(lineNo): unknown key '\(key)'")
                    continue
                }
                guard let mod = modifiers[val] else {
                    err("macape: \(path):\(lineNo): unknown modifier '\(val)'")
                    continue
                }
                mappings.append(Mapping(keyCode: kc, modifier: mod))
            }
        }

        if mappings.isEmpty { mappings = defaults.mappings }
        return (Config(holdTimeoutMs: hold, mappings: mappings), true)
    }
}
