import AppKit
import MacapeCore

@main
struct MacapeBarApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusController()
        statusController?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusController?.stop()
    }
}
