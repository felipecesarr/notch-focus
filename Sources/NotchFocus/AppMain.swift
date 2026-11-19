import AppKit

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?
    private var store: FocusStore?
    private var clock: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            // A separate history file lets on-device UI checks exercise the release build with disposable tasks.
            let historyFile = ProcessInfo.processInfo.environment["NOTCH_FOCUS_HISTORY_FILE"]
            let store = try FocusStore(url: historyFile.map { URL(fileURLWithPath: $0) } ?? FocusStore.dataURL)
            self.store = store
            let sounds = IntervalSounds()
            store.onBoundary = { boundary in sounds.play(boundary) }
            // The previous version checkpoints a running clock as paused while it quits.
            if let rawID = ProcessInfo.processInfo.environment["NOTCH_FOCUS_RESUME_ON_UPDATE"],
               let id = UUID(uuidString: rawID), store.mode == .paused, store.activeTask?.id == id {
                store.toggleFocus(id)
            }
            store.reportSaveError = { error in
                DispatchQueue.main.async {
                    let alert = NSAlert(error: error)
                    alert.messageText = "Notch Focus couldn’t save your latest changes."
                    alert.informativeText = "Keep the app open while it retries. " + error.localizedDescription
                    alert.runModal()
                }
            }
            let controller = NotchController(store: store)
            self.controller = controller
            configureMenus()
            controller.start()
            let clock = Timer(timeInterval: 0.5, repeats: true) { [weak store] _ in
                MainActor.assumeIsolated { store?.tick() }
            }
            clock.tolerance = 0.08
            RunLoop.main.add(clock, forMode: .common)
            self.clock = clock
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert(error: error)
            alert.messageText = "Notch Focus couldn’t open its local history."
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.reopenPlanner()
        return false
    }

    private func configureMenus() {
        let main = NSMenu()
        let application = NSMenu()
        application.addItem(withTitle: "Quit Notch Focus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "Notch Focus", action: nil, keyEquivalent: "").submenu = application
        let edit = NSMenu(title: "Edit")
        for (title, selector, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                       ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
        NSApp.mainMenu = main
    }

    func applicationWillTerminate(_ notification: Notification) {
        clock?.invalidate()
        store?.interrupt()
        controller?.stop()
    }
}

@main
enum NotchFocusApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
