import AppKit
import SwiftUI
import XCTest
@testable import NotchFocus

final class NotchHoverTests: XCTestCase {
    @MainActor
    func testPollingAtLowerCameraEdgeExpandsWithoutFocusAndCollapsesOnExitOrEscape() async throws {
        let app = NSApplication.shared
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else {
            throw XCTSkip("This interaction requires a Mac display with a camera housing.")
        }
        let options = app.currentSystemPresentationOptions
        if options.contains(.fullScreen) && (options.contains(.hideMenuBar) || options.contains(.autoHideMenuBar)) {
            throw XCTSkip("The current full-screen Space intentionally suppresses the notch.")
        }

        let center = (left.maxX + right.minX) / 2
        let belowCamera = CGPoint(x: center, y: screen.frame.maxY - screen.safeAreaInsets.top - 5)
        let away = CGPoint(x: center, y: screen.frame.midY)
        var pointer = away
        var lastSample: CGPoint?
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var time = Date()
        let store = try FocusStore(url: directory.appending(path: "history.json"), now: { time }, seed: false)
        let existingWindows = Set(app.windows.map(ObjectIdentifier.init))
        let controller = NotchController(store: store, pointerLocation: {
            lastSample = pointer
            return pointer
        })
        controller.start()
        defer { controller.stop() }
        let panel = try XCTUnwrap(app.windows.first { $0.title == "Focus Notch" && !existingWindows.contains(ObjectIdentifier($0)) })
        let planner = try XCTUnwrap(app.windows.first { $0.title == "Task Planner" && !existingWindows.contains(ObjectIdentifier($0)) })
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertFalse(planner.hasShadow)
        let idleWidth = panel.frame.width
        XCTAssertEqual(idleWidth, right.minX - left.maxX + 16, accuracy: 1)
        let cameraWidth = right.minX - left.maxX
        let expandedWidth = ExpandedNotchMetrics.fittedWidth(cameraWidth: cameraWidth, screenWidth: screen.frame.width)

        pointer = CGPoint(x: left.maxX - 16, y: belowCamera.y)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(lastSample, pointer)
        XCTAssertEqual(panel.frame.width, idleWidth, accuracy: 1, "Moving beside the camera should leave the notch closed.")

        pointer = belowCamera
        try await waitForWidth(expandedWidth, on: panel)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertEqual(panel.frame.midX, center, accuracy: 1)
        XCTAssertEqual(panel.frame.maxY, screen.frame.maxY, accuracy: 1)
        XCTAssertEqual(panel.frame.height, screen.safeAreaInsets.top + ExpandedNotchMetrics.heightBelowCamera, accuracy: 1)
        let plannerFrame = NotchPlacement(screen).plannerFrame(under: panel.frame)
        XCTAssertEqual(plannerFrame.maxY, panel.frame.minY - 5, accuracy: 1)
        XCTAssertEqual(plannerFrame.midX, panel.frame.midX, accuracy: 1)
        XCTAssertEqual(plannerFrame.width, min(720, screen.visibleFrame.width - 12), accuracy: 1)

        pointer = away
        try await waitForWidth(idleWidth, on: panel)
        pointer = belowCamera
        try await waitForWidth(expandedWidth, on: panel)
        panel.cancelOperation(nil)
        try await waitForWidth(idleWidth, on: panel)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(panel.frame.width, idleWidth, accuracy: 1, "Escape suppresses hover until the pointer leaves.")
        pointer = away
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while lastSample != away && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(lastSample, away, "The pointer monitor should observe leaving the activation area.")
        pointer = belowCamera
        try await waitForWidth(expandedWidth, on: panel)
        XCTAssertFalse(panel.isKeyWindow)

        pointer = away
        try await waitForWidth(idleWidth, on: panel)
        let id = try XCTUnwrap(store.saveRoutine(id: nil, title: "Study TypeScript", notes: "", duration: 1500,
                                                breakDuration: 300, cycles: ["Recall", "Learn", "Explain"],
                                                category: .study, weeklyTarget: 3))
        store.enqueue(id, cycleIndex: 1)
        store.startNext()
        let focus = CompactNotchMetrics(mode: .focusing)
        try await waitForWidth(cameraWidth + focus.leftWing + focus.rightWing, on: panel)
        XCTAssertEqual(panel.frame.minX, left.maxX - focus.leftWing, accuracy: 1)
        XCTAssertEqual(panel.frame.maxX, right.minX + focus.rightWing, accuracy: 1)
        XCTAssertEqual(panel.frame.height, screen.safeAreaInsets.top + focus.heightBelowCamera, accuracy: 1)

        // Both compact wings must stay inside the centered face as it opens.
        let runningFrame = panel.frame
        for x in [runningFrame.minX + 28, runningFrame.maxX - 28] {
            pointer = CGPoint(x: x, y: runningFrame.minY + 3)
            try await waitForWidth(expandedWidth, on: panel)
            XCTAssertTrue(panel.frame.contains(pointer))
            XCTAssertLessThanOrEqual(panel.frame.minX, runningFrame.minX + 1)
            XCTAssertGreaterThanOrEqual(panel.frame.maxX, runningFrame.maxX - 1)
            XCTAssertFalse(panel.isKeyWindow)
            pointer = away
            try await waitForWidth(runningFrame.width, on: panel)
        }

        time.addTimeInterval(1500)
        store.tick()
        XCTAssertEqual(store.mode, .onBreak)
        let rest = CompactNotchMetrics(mode: .onBreak)
        try await waitForWidth(cameraWidth + rest.leftWing + rest.rightWing, on: panel)
        XCTAssertLessThan(rest.rightWing, focus.rightWing)
        XCTAssertEqual(panel.frame.minX, left.maxX - rest.leftWing, accuracy: 1)
        XCTAssertEqual(panel.frame.maxY, screen.frame.maxY, accuracy: 1)
    }

    func testExpandedWidthCoversWideCameraAndFitsNarrowDisplay() {
        let focus = CompactNotchMetrics(mode: .focusing)
        XCTAssertEqual(ExpandedNotchMetrics.fittedWidth(cameraWidth: 208, screenWidth: 1710), 568)
        XCTAssertEqual(ExpandedNotchMetrics.fittedWidth(cameraWidth: 280, screenWidth: 2300), 280 + 2 * focus.rightWing)
        XCTAssertEqual(ExpandedNotchMetrics.fittedWidth(cameraWidth: 90, screenWidth: 550), 538)
    }

    @MainActor
    func testActiveHoverShowsOnlyTheRunningTaskAndItsDetails() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FocusStore(url: directory.appending(path: "history.json"), seed: false)
        let id = try XCTUnwrap(store.saveRoutine(id: nil, title: "Study TypeScript", notes: "Keep notes", duration: 1500,
                                                breakDuration: 300, cycles: ["Recall concepts", "Learn methods", "Explain and drill"], category: .study, weeklyTarget: 2))
        store.saveTask(id: nil, title: "Unrelated task", notes: "", duration: 600, scheduledDay: Date())
        store.enqueue(id, cycleIndex: 1)
        store.startNext()

        let topInset: CGFloat = 37.5
        let face = NotchFace(store: store, expanded: true, cameraWidth: 208, topInset: topInset, openPlanner: { _ in })
        let host = NSHostingView(rootView: face.environment(\.accessibilityEnabled, true))
        let frame = CGRect(x: 0, y: 0, width: ExpandedNotchMetrics.width, height: topInset + ExpandedNotchMetrics.heightBelowCamera)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        host.sizingOptions = []
        window.contentView = host
        host.frame = frame
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        window.display()
        let detail = accessibleText(in: host).joined(separator: " ")
        XCTAssertTrue(detail.contains("Complete Study TypeScript"), detail)
        for name in ["Recall concepts", "Learn methods", "Explain and drill"] {
            XCTAssertTrue(detail.contains(name), "Expected subtask ‘\(name)’ in the hover panel. Found: \(detail)")
        }
        XCTAssertTrue(detail.contains("Learn methods, current"), detail)
        XCTAssertTrue(detail.contains("Keep notes"), detail)
        XCTAssertTrue(detail.contains("Pause"), detail)
        XCTAssertFalse(detail.contains("Unrelated task"), detail)
        XCTAssertFalse(detail.contains("Daily focus history"), detail)
    }

    @MainActor
    private func accessibleText(in element: NSObject) -> [String] {
        func attribute(_ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard element.responds(to: selector) else { return nil }
            return element.perform(selector)?.takeUnretainedValue()
        }
        let text = ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { attribute($0) as? String }
        let children = attribute("accessibilityChildren") as? [NSObject] ?? []
        return text + children.flatMap { accessibleText(in: $0) }
    }

    @MainActor
    private func waitForWidth(_ width: CGFloat, on panel: NSWindow, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while abs(panel.frame.width - width) > 1 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(panel.frame.width, width, accuracy: 1, file: file, line: line)
    }
}
