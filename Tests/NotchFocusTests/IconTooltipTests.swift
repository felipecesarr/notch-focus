import AppKit
import SwiftUI
import XCTest
@testable import NotchFocus

@MainActor
private final class TooltipPanel: NSPanel {
    var pointer = NSPoint.zero
    override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
    override var canBecomeKey: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
private final class TooltipFixture: ObservableObject {
    @Published var hint: String?
}

private struct TooltipScene: View {
    @ObservedObject var fixture: TooltipFixture
    var body: some View {
        Color.black.overlay(alignment: .topTrailing) {
            if let hint = fixture.hint {
                Button(action: {}) { Color.clear.frame(width: 28, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .iconTooltip(hint)
                    .padding(.trailing, 8)
            }
        }
        .iconTooltipHost(topInset: 38, sideInset: 12)
        .preferredColorScheme(.dark)
    }
}

final class IconTooltipTests: XCTestCase {
    @MainActor
    func testStationaryPointerPicksUpNewButtonAndBubbleStaysBelowHousing() async throws {
        _ = NSApplication.shared
        let frame = NSRect(x: -24000, y: -24000, width: 180, height: 140)
        let panel = TooltipPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.ignoresMouseEvents = true
        let model = TooltipFixture()
        let host = NSHostingView(rootView: TooltipScene(fixture: model))
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrame(frame, display: true)
        panel.orderBack(nil)
        defer { panel.orderOut(nil) }
        panel.pointer = NSPoint(x: frame.width - 20, y: frame.height - 10)
        model.hint = "Queue this routine"
        try await Task.sleep(for: .milliseconds(550))
        func hintBounds() throws -> NSRect {
            host.layoutSubtreeIfNeeded()
            let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            var lit = NSRect.null
            let scale = CGFloat(image.pixelsWide) / host.bounds.width
            for y in 0..<image.pixelsHigh {
                for x in 0..<image.pixelsWide where (image.colorAt(x: x, y: y)?.redComponent ?? 0) > 0.1 {
                    lit = lit.union(NSRect(x: CGFloat(x) / scale, y: CGFloat(y) / scale, width: 1 / scale, height: 1 / scale))
                }
            }
            return lit
        }
        let first = try hintBounds()
        XCTAssertFalse(first.isNull, "A stationary pointer must reveal a newly mounted icon's tooltip.")
        XCTAssertGreaterThanOrEqual(first.minY, 38)
        XCTAssertGreaterThanOrEqual(first.minX, 12)
        XCTAssertLessThanOrEqual(first.maxX, frame.width - 12)
        model.hint = "Remove this entire routine from the queue"
        try await Task.sleep(for: .milliseconds(120))
        let second = try hintBounds()
        XCTAssertGreaterThan(second.height, first.height)
        XCTAssertGreaterThanOrEqual(second.minY, 38)
        XCTAssertLessThanOrEqual(second.maxX, frame.width - 12)

        // Update AppKit's tracking as if the button moved away during the height animation.
        panel.pointer = NSPoint(x: 5, y: 5)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let tracking = try XCTUnwrap(descendants(host).first { view in
            view.bounds.size == NSSize(width: 28, height: 24)
                && view.trackingAreas.contains { $0.owner === view && $0.options.contains(.activeAlways) }
        })
        let area = try XCTUnwrap(tracking.trackingAreas.first { $0.owner === tracking })
        XCTAssertEqual(area.rect, tracking.bounds)
        XCTAssertFalse(area.options.contains(.inVisibleRect))
        XCTAssertNil(tracking.hitTest(NSPoint(x: tracking.frame.midX, y: tracking.frame.midY)))
        tracking.updateTrackingAreas()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(try hintBounds().isNull)
        XCTAssertFalse(panel.isKeyWindow)
    }
}
