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
        let compact = CompactNotchMetrics(mode: mode)
        // A display without a housing opens the original centered panel from its menu item.
        let menuPanel = !isHardwareNotch && expanded
        let width = min(menuPanel ? 568 : compact.leftWing + cameraWidth + compact.rightWing,
                        screen.frame.width - 12)
        let preferredX = menuPanel ? centerX - width / 2 : centerX - cameraWidth / 2 - compact.leftWing
        let x = min(max(preferredX, screen.frame.minX + 6), screen.frame.maxX - 6 - width)
        let below = expanded ? ExpandedNotchMetrics.heightBelowCamera : compact.heightBelowCamera
        let height = min(topInset + below, topY - screen.visibleFrame.minY - 6)
        return NSRect(x: x, y: topY - height, width: width, height: height).integral
    }

    func plannerFrame(under face: NSRect) -> NSRect {
        let height = min(490, face.minY - screen.visibleFrame.minY - 14)
        let width = min(720, screen.visibleFrame.width - 12)
        return NSRect(x: face.midX - width / 2, y: face.minY - 5 - height, width: width, height: height)
    }

    func contains(_ point: CGPoint, expanded: Bool, mode: FocusMode) -> Bool {
        contains(point, in: faceFrame(expanded: expanded, mode: mode), mode: mode)
    }

    func contains(_ point: CGPoint, in frame: NSRect, mode: FocusMode) -> Bool {
        guard point.x >= frame.minX, point.x < frame.maxX, point.y >= frame.minY, point.y <= frame.maxY else { return false }
        let local = CGPoint(x: point.x - frame.minX, y: max(0.01, frame.maxY - point.y))
        let outline = NotchOutline(compactHeight: topInset + CompactNotchMetrics(mode: mode).heightBelowCamera)
        return outline.path(in: CGRect(origin: .zero, size: frame.size)).contains(local)
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
    private var displayLink: CADisplayLink?
    private var transition: (fromHeight: CGFloat, target: NSRect, start: CFTimeInterval, duration: CFTimeInterval)?
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
                guard let self, self.face.isVisible else { return }
                self.trackPointer()
            }
        }
        sampler.tolerance = 0.015
        RunLoop.main.add(sampler, forMode: .common)
        hoverSampler = sampler
    }

    func stop() {
        stopMotion()
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
            stopMotion()
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
            stopMotion()
            face.orderOut(nil)
            return
        }

        let rect = placement.faceFrame(expanded: expanded, mode: store.mode)
        let motion = animated && face.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let retracting = motion && face.frame.height > rect.height && host?.rootView.expanded == true
        showContent(expanded: expanded || retracting, at: placement)
        resizeFace(to: rect, animated: motion)
        if !face.isVisible { face.orderFrontRegardless() }
        if planner.isVisible { planner.setFrame(placement.plannerFrame(under: rect), display: true) }
    }

    private func showContent(expanded: Bool, at placement: NotchPlacement) {
        // The header buttons share the menu-bar band. Raise the panel for the
        // reveal and restore its ordinary floating level when it is compact again.
        let level = expanded ? NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1) : .floating
        if face.level != level { face.level = level }
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
    }

    private func resizeFace(to rect: NSRect, animated: Bool) {
        if animated, transition?.target == rect { return }
        stopMotion()
        let height = face.frame.height
        guard animated, abs(height - rect.height) > 0.5 else {
            finishMotion(at: rect)
            return
        }

        // Starting again from the visible height also makes a reversal continuous.
        let distance = abs(height - rect.height)
        let fullTravel = max(1, ExpandedNotchMetrics.heightBelowCamera
                              - CompactNotchMetrics(mode: store.mode).heightBelowCamera)
        let duration = (expanded ? 0.25 : 0.20) * Double(min(1, max(0.35, distance / fullTravel)))
        transition = (height, rect, CACurrentMediaTime(), duration)
        setFaceHeight(height, in: rect)
        let link = face.displayLink(target: self, selector: #selector(advanceMotion))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func advanceMotion() {
        guard let transition else { return }
        let progress = min(1, (CACurrentMediaTime() - transition.start) / transition.duration)
        if progress >= 1 {
            finishMotion(at: transition.target)
        } else {
            let eased = progress * progress * (3 - 2 * progress)
            setFaceHeight(transition.fromHeight + (transition.target.height - transition.fromHeight) * eased,
                          in: transition.target)
        }
    }

    private func setFaceHeight(_ height: CGFloat, in target: NSRect) {
        let rect = NSRect(x: target.minX, y: target.maxY - height, width: target.width, height: height)
        if face.frame != rect { face.setFrame(rect, display: true) }
    }

    private func finishMotion(at target: NSRect) {
        stopMotion()
        if face.frame != target { face.setFrame(target, display: true) }
        if !expanded, host?.rootView.expanded == true, let placement {
            showContent(expanded: false, at: placement)
        }
    }

    private func stopMotion() {
        displayLink?.invalidate()
        displayLink = nil
        transition = nil
    }

    private func cancelHover() {
        pendingHover?.cancel()
        pendingHover = nil
        pendingTarget = nil
    }

    private func trackPointer() {
        guard face.isVisible, !keyboardOpen, !planner.isVisible, let placement else { return }
        let point = pointerLocation()
        // WindowServer hit-tests this nonopaque window's actual pixels. Disabling the
        // entire panel over a clear corner can swallow the next click on a nearby control.
        let onFace = placement.contains(point, in: face.frame, mode: store.mode)
        let inside = expanded ? placement.contains(point, expanded: true, mode: store.mode)
                              : placement.opensOnHover(at: point, mode: store.mode)
        if suppressHoverUntilExit {
            if !inside && !onFace { suppressHoverUntilExit = false }
            return
        }
        if !expanded, transition != nil, host?.rootView.expanded == true, onFace {
            setExpanded(true)
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
        if let placement {
            let point = pointerLocation()
            suppressHoverUntilExit = placement.opensOnHover(at: point, mode: store.mode)
                || placement.contains(point, in: face.frame, mode: store.mode)
        }
        setExpanded(false)
    }

    @objc private func interruptFocus() {
        store.interrupt()
        dismissAll()
    }
}
