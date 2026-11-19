import AppKit
import Combine
import SwiftUI

private final class FocusPanel: NSPanel {
    var acceptsKeys = false
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { acceptsKeys }
    override var canBecomeMain: Bool { false }

    // A normal AppKit window is constrained below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

private final class NotchHostingView: NSHostingView<NotchFace> {
    var pointerChanged: (() -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        super.updateTrackingAreas()
        let area = NSTrackingArea(rect: .zero,
                                  options: [.inVisibleRect, .mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { pointerChanged?() }
    override func mouseExited(with event: NSEvent) { pointerChanged?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

enum ExpandedNotchMetrics {
    static let width: CGFloat = 568
    static let heightBelowCamera: CGFloat = 214

    static func fittedWidth(cameraWidth: CGFloat, screenWidth: CGFloat) -> CGFloat {
        // Centering on a wide camera must still cover the longer compact wing.
        let focus = CompactNotchMetrics(mode: .focusing)
        let coveredWidth = cameraWidth + 2 * max(focus.leftWing, focus.rightWing)
        return min(max(width, coveredWidth), screenWidth - 12)
    }
}

struct NotchPlacement {
    let screen: NSScreen
    let isHardwareNotch: Bool
    let cameraWidth: CGFloat
    let topInset: CGFloat
    let centerX: CGFloat
    let topY: CGFloat

    init(_ screen: NSScreen) {
        self.screen = screen
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea, right.minX > left.maxX {
            isHardwareNotch = true
            cameraWidth = right.minX - left.maxX
            topInset = screen.safeAreaInsets.top
            centerX = (left.maxX + right.minX) / 2
            topY = screen.frame.maxY
        } else {
            isHardwareNotch = false
            cameraWidth = 90
            topInset = 24
            centerX = screen.frame.midX
            topY = min(screen.visibleFrame.maxY, screen.frame.maxY - NSStatusBar.system.thickness)
        }
    }

    func faceFrame(expanded: Bool, mode: FocusMode) -> NSRect {
        if expanded {
            let width = ExpandedNotchMetrics.fittedWidth(cameraWidth: cameraWidth, screenWidth: screen.frame.width)
            let height = topInset + ExpandedNotchMetrics.heightBelowCamera
            return NSRect(x: centerX - width / 2, y: topY - height, width: width, height: height)
        }
        let metrics = CompactNotchMetrics(mode: mode)
        let width = metrics.leftWing + cameraWidth + metrics.rightWing
        let height = topInset + metrics.heightBelowCamera
        let x = centerX - cameraWidth / 2 - metrics.leftWing
        return NSRect(x: x, y: topY - height, width: width, height: height)
    }

    func plannerFrame(under face: NSRect) -> NSRect {
        let height = min(490, face.minY - screen.visibleFrame.minY - 14)
        let width = min(720, screen.visibleFrame.width - 12)
        return NSRect(x: face.midX - width / 2, y: face.minY - 5 - height, width: width, height: height)
    }

    func contains(_ point: CGPoint, expanded: Bool, mode: FocusMode) -> Bool {
        let frame = faceFrame(expanded: expanded, mode: mode)
        guard point.x >= frame.minX, point.x < frame.maxX, point.y >= frame.minY, point.y <= frame.maxY else { return false }
        let local = CGPoint(x: point.x - frame.minX, y: max(0.01, frame.maxY - point.y))
        return NotchOutline(expanded: expanded).path(in: CGRect(origin: .zero, size: frame.size)).contains(local)
    }

    func opensOnHover(at point: CGPoint, mode: FocusMode) -> Bool {
        if isHardwareNotch && abs(point.x - centerX) <= cameraWidth / 2 &&
            point.y <= topY && point.y >= topY - topInset - 12 {
            return true
        }
        return contains(point, expanded: false, mode: mode)
    }
}

@MainActor
final class NotchController: NSObject {
    private let store: FocusStore
    private let pointerLocation: () -> CGPoint
    private let face = FocusPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let planner = FocusPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private var host: NotchHostingView?
    private var statusItem: NSStatusItem?
    private var subscriptions = Set<AnyCancellable>()
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var hoverSampler: Timer?
    private var pendingHover: DispatchWorkItem?
    private var pendingTarget: Bool?
    private var keyboardOpen = false
    private var expanded = false
    private var suppressHoverUntilExit = false
    private var requestedDisplay: NSNumber?
    private var placement: NotchPlacement?

    init(store: FocusStore, pointerLocation: @escaping () -> CGPoint = { NSEvent.mouseLocation }) {
        self.store = store
        self.pointerLocation = pointerLocation
        super.init()
    }

    func start() {
        configure(face, title: "Focus Notch")
        configure(planner, title: "Task Planner")
        planner.acceptsKeys = true
        face.onCancel = { [weak self] in self?.dismissAll() }
        planner.onCancel = { [weak self] in self?.closePlanner() }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "timer", accessibilityDescription: "Notch Focus")
        item.button?.setAccessibilityLabel("Notch Focus")
        item.button?.toolTip = "Notch Focus"
        let menu = NSMenu()
        for (title, action, key) in [("Show Notch", #selector(showNotchFromMenu), ""),
                                     ("Open Task Planner", #selector(showPlannerFromMenu), "o"),
                                     ("New Task", #selector(newTaskFromMenu), "n")] {
            let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            entry.target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Notch Focus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(self, selector: #selector(interruptFocus), name: name, object: nil)
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(interruptFocus),
                                                            name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        workspace.addObserver(self, selector: #selector(refreshDisplay), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshDisplay),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        store.$mode.removeDuplicates().dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            self?.layout(animated: true)
        }.store(in: &subscriptions)

        // Mouse activity only. The keyboard stays owned by the foreground application during hover.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if self?.planner.isVisible == true || self?.keyboardOpen == true { self?.dismissAll() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .mouseMoved { trackPointer() }
            if event.type == .leftMouseDown, event.window === face, !expanded,
               placement?.contains(face.convertPoint(toScreen: event.locationInWindow), expanded: false, mode: store.mode) == true {
                suppressHoverUntilExit = false
                setExpanded(true)
                return nil
            }
            if event.type == .keyDown, event.keyCode == 53, event.window === face {
                dismissAll()
                return nil
            }
            return event
        }
        refreshDisplay()
        // The menu bar and other apps can own mouse movement below the camera.
        // Read the system cursor directly so hovering also works outside our window.
        let sampler = Timer(timeInterval: 0.10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.face.isVisible, !self.keyboardOpen, !self.planner.isVisible else { return }
                self.trackPointer()
            }
        }
        sampler.tolerance = 0.015
        RunLoop.main.add(sampler, forMode: .common)
        hoverSampler = sampler
    }

    func stop() {
        hoverSampler?.invalidate()
        hoverSampler = nil
        cancelHover()
        subscriptions.removeAll()
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        planner.orderOut(nil)
        face.orderOut(nil)
    }

    private func configure(_ panel: FocusPanel, title: String) {
        panel.title = title
        panel.setAccessibilityLabel(title)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.isMovable = false
        panel.isFloatingPanel = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    private func displayID(_ screen: NSScreen) -> NSNumber? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }

    @objc private func refreshDisplay() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            placement = nil
            face.orderOut(nil)
            planner.orderOut(nil)
            return
        }
        let selected = requestedDisplay.flatMap { id in screens.first { displayID($0) == id } }
        if selected == nil { requestedDisplay = nil }
        let screen = selected ?? screens.first { NotchPlacement($0).isHardwareNotch } ?? NSScreen.main ?? screens[0]
        placement = NotchPlacement(screen)
        layout(animated: false)
    }

    private func layout(animated: Bool) {
        guard let placement else { return }
        let options = NSApp.currentSystemPresentationOptions
        let systemHidesMenu = options.contains(.hideMenuBar) || options.contains(.autoHideMenuBar)
        let hiddenInFullScreen = options.contains(.fullScreen) && systemHidesMenu && requestedDisplay == nil && !expanded
        if (!placement.isHardwareNotch && !expanded) || hiddenInFullScreen {
            face.orderOut(nil)
            return
        }
        let fresh = NotchFace(store: store, expanded: expanded, cameraWidth: placement.cameraWidth,
                              topInset: placement.topInset, openPlanner: { [weak self] in self?.openPlanner(compose: $0) })
        if let host { host.rootView = fresh }
        else {
            let view = NotchHostingView(rootView: fresh)
            view.sizingOptions = []
            view.pointerChanged = { [weak self] in self?.trackPointer() }
            face.contentView = view
            host = view
        }
        let rect = placement.faceFrame(expanded: expanded, mode: store.mode)
        if rect != face.frame {
            let motion = animated && face.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if motion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.19
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    face.animator().setFrame(rect, display: true)
                }
            } else {
                face.setFrame(rect, display: true)
            }
        }
        if !face.isVisible { face.orderFrontRegardless() }
        if planner.isVisible {
            planner.setFrame(placement.plannerFrame(under: rect), display: true)
        }
    }

    private func cancelHover() {
        pendingHover?.cancel()
        pendingHover = nil
        pendingTarget = nil
    }

    private func trackPointer() {
        guard face.isVisible, let placement else { return }
        let point = pointerLocation()
        let bounds = placement.faceFrame(expanded: expanded, mode: store.mode)
        let onFace = placement.contains(point, expanded: expanded, mode: store.mode)
        let overClearCorner = bounds.contains(point) && !onFace
        if face.ignoresMouseEvents != overClearCorner { face.ignoresMouseEvents = overClearCorner }
        guard !keyboardOpen, !planner.isVisible else { return }
        let inside = expanded ? onFace : placement.opensOnHover(at: point, mode: store.mode)
        if suppressHoverUntilExit {
            if !inside { suppressHoverUntilExit = false }
            return
        }
        guard inside != expanded else {
            cancelHover()
            return
        }
        guard pendingTarget != inside else { return }
        cancelHover()
        pendingTarget = inside
        let work = DispatchWorkItem { [weak self] in
            guard let self, let placement = self.placement, self.face.isVisible,
                  !self.keyboardOpen, !self.planner.isVisible else { return }
            let current = self.pointerLocation()
            let stillInside = self.expanded
                ? placement.contains(current, expanded: true, mode: self.store.mode)
                : placement.opensOnHover(at: current, mode: self.store.mode)
            if inside == stillInside { self.setExpanded(inside) }
            else { self.cancelHover() }
        }
        pendingHover = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.10 : 0.32), execute: work)
    }

    private func setExpanded(_ value: Bool) {
        cancelHover()
        expanded = value
        if !expanded {
            if keyboardOpen && face.isKeyWindow { face.orderOut(nil) }
            keyboardOpen = false
            face.acceptsKeys = false
            if requestedDisplay != nil {
                requestedDisplay = nil
                refreshDisplay()
            } else {
                layout(animated: true)
            }
        } else {
            layout(animated: true)
        }
    }

    private func selectScreenForMenu() {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        requestedDisplay = screen.flatMap(displayID)
        refreshDisplay()
    }

    @objc private func showNotchFromMenu() {
        selectScreenForMenu()
        keyboardOpen = true
        face.acceptsKeys = true
        setExpanded(true)
        face.makeKeyAndOrderFront(nil)
    }

    func reopenPlanner() {
        openPlanner(compose: false)
    }

    @objc private func showPlannerFromMenu() {
        selectScreenForMenu()
        openPlanner(compose: false)
    }

    @objc private func newTaskFromMenu() {
        selectScreenForMenu()
        openPlanner(compose: true)
    }

    private func openPlanner(compose: Bool) {
        guard let placement else { return }
        setExpanded(true)
        if planner.isVisible {
            planner.makeKeyAndOrderFront(nil)
            if compose { NotificationCenter.default.post(name: .notchFocusCompose, object: nil) }
            return
        }
        let view = NSHostingView(rootView: PlannerView(store: store, compose: compose, close: { [weak self] in self?.closePlanner() }))
        view.sizingOptions = []
        planner.contentView = view
        planner.setFrame(placement.plannerFrame(under: placement.faceFrame(expanded: true, mode: store.mode)), display: true)
        planner.makeKeyAndOrderFront(nil)
    }

    private func closePlanner() {
        planner.orderOut(nil)
        if keyboardOpen { face.makeKeyAndOrderFront(nil) }
        else { trackPointer() }
    }

    private func dismissAll() {
        planner.orderOut(nil)
        suppressHoverUntilExit = placement?.opensOnHover(at: pointerLocation(), mode: store.mode) ?? false
        setExpanded(false)
    }

    @objc private func interruptFocus() {
        store.interrupt()
        dismissAll()
    }
}
