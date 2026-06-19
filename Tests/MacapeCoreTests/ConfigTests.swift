import XCTest
@testable import MacapeCore

final class ConfigTests: XCTestCase {
    func testPerKeyHoldTimeout() throws {
        let path = NSTemporaryDirectory() + "macape-test.conf"
        let text = """
        hold_timeout_ms = 200
        A = lcmd 150
        S = lalt 180 160
        """
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        let (config, loaded, errors) = Config.load(from: path)
        XCTAssertTrue(loaded)
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].contains("tap timeout is deprecated"))
        XCTAssertEqual(config.holdTimeout(for: config.mappings[0]), 150)
        XCTAssertEqual(config.holdTimeout(for: config.mappings[1]), 180)
    }

    func testLayerSection() throws {
        let path = NSTemporaryDirectory() + "macape-layer.conf"
        let text = """
        [layer space]
        hold = space
        j = left
        k = down
        l = up
        ; = right
        """
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        let (config, _, _) = Config.load(from: path)
        XCTAssertEqual(config.layer.holdKeyCode, 49)
        XCTAssertEqual(config.layer.mappings[38], 123)
        XCTAssertEqual(config.layer.mappings[40], 125)
    }

    func testSwapSection() throws {
        let path = NSTemporaryDirectory() + "macape-swap.conf"
        let text = """
        [swap]
        caps_lock = escape
        right_command = left_control
        """
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        let (config, loaded, errors) = Config.load(from: path)
        XCTAssertTrue(loaded)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(config.swaps.mappings[57], 53)
        XCTAssertEqual(config.swaps.mappings[54], 59)
    }
}
