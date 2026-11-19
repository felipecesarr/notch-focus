import AppKit
import SwiftUI
import XCTest
@testable import NotchFocus

final class NotchActionTests: XCTestCase {
    @MainActor
    func testFirstClicksOnTheHoverPanelOperateTheTaskAndPlanner() async throws {
        let app = NSApplication.shared
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) else {
            throw XCTSkip("The hover panel requires a display with a camera housing.")
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = Date()
        let store = try FocusStore(url: directory.appending(path: "test.json"), now: { now }, seed: false)
        let id = try XCTUnwrap(store.saveRoutine(id: nil, title: "Study", notes: "Take notes", duration: 1500,
            breakDuration: 300, cycles: ["Recall", "Practice"], category: .study, weeklyTarget: 3))

        let placement = NotchPlacement(screen)
        var pointer = CGPoint(x: placement.centerX, y: placement.topY - placement.topInset - 1)
        let previous = Set(app.windows.map(ObjectIdentifier.init))
        let controller = NotchController(store: store, pointerLocation: { pointer })
        controller.start()
        defer { controller.stop() }
        let windows = app.windows.filter { !previous.contains(ObjectIdentifier($0)) }
        let face = try XCTUnwrap(windows.first { $0.title == "Focus Notch" })
        let planner = try XCTUnwrap(windows.first { $0.title == "Task Planner" })
        guard face.isVisible else { throw XCTSkip("The current Space suppresses the notch.") }

        // Render a copy with accessibility turned on so button positions are available even with VoiceOver off.
        let host = try XCTUnwrap(face.contentView as? NSHostingView<NotchFace>)
        let reference = NSHostingView(rootView: host.rootView.environment(\.accessibilityEnabled, true))
        let referenceWindow = NSWindow(contentRect: face.frame, styleMask: .borderless, backing: .buffered, defer: false)
        reference.sizingOptions = []
        referenceWindow.contentView = reference

        func settle() async throws {
            try await Task.sleep(for: .milliseconds(35))
            face.contentView?.layoutSubtreeIfNeeded()
            face.displayIfNeeded()
        }
        func waitForOpen() async throws {
            let frame = placement.faceFrame(expanded: true, mode: store.mode)
            for _ in 0..<70 {
                if abs(face.frame.height - frame.height) < 1 { return }
                try await settle()
            }
            XCTFail("The hover panel did not reach its open height.")
        }
        // Accessibility supplies the position only. AppKit hit-tests actual mouse events in our test window.
        func click(_ title: String, whileDown: () -> Void = {}) async throws {
            try await settle()
            referenceWindow.setContentSize(face.frame.size)
            reference.rootView = host.rootView.environment(\.accessibilityEnabled, true)
            reference.layoutSubtreeIfNeeded()
            referenceWindow.display()
            let button = try XCTUnwrap(findButton(title, in: reference), "Missing button: " + title)
            let frame = try XCTUnwrap(button.value(forKey: "accessibilityFrame") as? NSValue).rectValue
            let localFrame = referenceWindow.convertFromScreen(frame)
            pointer = face.convertPoint(toScreen: CGPoint(x: localFrame.midX, y: localFrame.midY))
            if store.mode == .focusing && ["Add a task", "Open task planner"].contains(title) {
                XCTAssertGreaterThan(pointer.y, placement.topY - placement.topInset, title + " belongs in the header")
                XCTAssertGreaterThan(pointer.x, placement.centerX + placement.cameraWidth / 2)
            }
            let receivingWindow = NSWindow.windowNumber(at: pointer, belowWindowWithWindowNumber: 0)
            guard receivingWindow == face.windowNumber else {
                return XCTFail(title + " should receive a mouse down at its screen position")
            }
            XCTAssertTrue(face.frame.contains(pointer), title + " lies outside the clickable panel")
            XCTAssertFalse(face.isKeyWindow)
            XCTAssertFalse(face.ignoresMouseEvents)
            let local = face.convertPoint(fromScreen: pointer)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: local, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: receivingWindow,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                if type == .leftMouseDown {
                    let parent = try XCTUnwrap(host.superview)
                    let hit = try XCTUnwrap(host.hitTest(parent.convert(local, from: nil)), title)
                    XCTAssertTrue(hit.acceptsFirstMouse(for: event), title + " cannot receive the first click")
                }
                app.sendEvent(event)
                if type == .leftMouseDown { whileDown() }
            }
            try await settle()
        }

        try await waitForOpen()
        try await click("Queue Pomodoro, Study")
        XCTAssertEqual(store.queue.count, 1)
        try await click("Remove queued Pomodoro, Study")
        XCTAssertTrue(store.queue.isEmpty)
        try await click("Start Study")
        XCTAssertEqual(store.mode, .focusing)
        try await waitForOpen()
        try await click("Pause") {
            now.addTimeInterval(1)
            store.tick()
        }
        XCTAssertEqual(store.mode, .paused)
        try await click("Resume")
        XCTAssertEqual(store.mode, .focusing)
        try await click("Queue Pomodoro, Study")
        XCTAssertEqual(store.queue.count, 1)
        try await click("Remove queued Pomodoro, Study")
        XCTAssertTrue(store.queue.isEmpty)
        try await click("Add a task")
        XCTAssertTrue(planner.isVisible)
        let editor = try XCTUnwrap(planner.contentView)
        let fields = descendants(of: editor).compactMap { $0 as? NSTextField }
        let titleField = try XCTUnwrap(fields.first { $0.placeholderString == "Name your routine" },
                                      "New task should open the routine editor")
        XCTAssertEqual(titleField.stringValue, "")
        pointer = CGPoint(x: face.frame.minX + 1, y: face.frame.midY)
        let corner = NSWindow.windowNumber(at: pointer, belowWindowWithWindowNumber: 0)
        XCTAssertNotEqual(corner, face.windowNumber, "The clear edge should pass clicks to the window behind it")
        let enterCorner = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: face.convertPoint(fromScreen: pointer),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: face.windowNumber,
            context: nil, eventNumber: 2, clickCount: 0, pressure: 0))
        app.sendEvent(enterCorner)
        XCTAssertFalse(face.ignoresMouseEvents, "Crossing a clear corner must not disable the entire panel")
        planner.cancelOperation(nil)
        try await click("Open task planner")
        XCTAssertTrue(planner.isVisible)
        planner.cancelOperation(nil)

        pointer = CGPoint(x: placement.centerX, y: placement.topY - placement.topInset - 1)
        now.addTimeInterval(1500)
        store.tick()
        XCTAssertEqual(store.mode, .onBreak)
        try await waitForOpen()
        try await click("End break")
        XCTAssertEqual(store.mode, .focusing)
        XCTAssertEqual(store.activeCycleIndex, 1)
        try await waitForOpen()
        try await click("Complete Study")
        XCTAssertEqual(store.mode, .idle)
        XCTAssertTrue(try XCTUnwrap(store.tasks.first(where: { $0.id == id })).done)

        pointer = CGPoint(x: placement.centerX, y: placement.topY - placement.topInset - 1)
        store.saveTask(id: nil, title: "Review", notes: "", duration: 600, scheduledDay: now)
        try await waitForOpen()
        try await click("Queue Pomodoro, Review")
        try await click("Start next queued cycle")
        XCTAssertEqual(store.activeTask?.title, "Review")
        XCTAssertEqual(store.mode, .focusing)

        pointer = CGPoint(x: placement.centerX, y: screen.frame.midY)
        face.cancelOperation(nil)
        for _ in 0..<70 where face.level != .floating { try await settle() }
        XCTAssertEqual(face.level, .floating, "The compact notch should retain its original window level")
        XCTAssertTrue(app.sendAction(NSSelectorFromString("showNotchFromMenu"), to: controller, from: nil))
        XCTAssertTrue(face.isVisible)
        XCTAssertGreaterThan(face.level.rawValue, NSWindow.Level.statusBar.rawValue)
        controller.reopenPlanner()
        XCTAssertTrue(planner.isVisible)
        XCTAssertEqual(planner.level, .floating)
        planner.cancelOperation(nil)
        face.cancelOperation(nil)
    }

    @MainActor
    private func findButton(_ title: String, in root: NSView) -> NSObject? {
        guard let window = root.window else { return nil }
        func matches(_ element: NSObject) -> Bool {
            func attribute(_ name: String) -> String? {
                let selector = NSSelectorFromString(name)
                guard element.responds(to: selector) else { return nil }
                return element.perform(selector)?.takeUnretainedValue() as? String
            }
            return attribute("accessibilityRole") == "AXButton" &&
                (attribute("accessibilityLabel") == title || attribute("accessibilityTitle") == title)
        }
        if let match = (root.accessibilityChildren() as? [NSObject])?.first(where: matches) { return match }
        // SwiftUI exposes lazy scroll rows through hit testing before enumerating their children.
        for view in descendants(of: root) {
            let middle = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            let screen = window.convertPoint(toScreen: view.convert(middle, to: nil))
            if let node = root.accessibilityHitTest(screen) as? NSObject, matches(node) { return node }
        }
        return nil
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
