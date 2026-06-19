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
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(config.holdTimeout(for: config.mappings[0]), 150)
        XCTAssertEqual(config.tapTimeout(for: config.mappings[0]), 200)
        XCTAssertEqual(config.holdTimeout(for: config.mappings[1]), 180)
        XCTAssertEqual(config.tapTimeout(for: config.mappings[1]), 160)
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
}
