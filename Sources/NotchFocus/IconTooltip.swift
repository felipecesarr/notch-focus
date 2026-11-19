import AppKit
import SwiftUI

private struct IconTooltipAnchor {
    let text: String
    let bounds: Anchor<CGRect>
}

private struct IconTooltipPreference: PreferenceKey {
    static var defaultValue: IconTooltipAnchor? { nil }

    static func reduce(value: inout IconTooltipAnchor?, nextValue: () -> IconTooltipAnchor?) {
        if let next = nextValue() { value = next }
    }
}

// The notch stays non-key during hover, so track the mouse even when another app is active.
private struct IconHoverArea: NSViewRepresentable {
    var changed: (Bool) -> Void

    final class TrackingView: NSView {
        var changed: ((Bool) -> Void)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited],
                                           owner: self, userInfo: nil))
        }

        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func mouseEntered(with event: NSEvent) { changed?(true) }
        override func mouseExited(with event: NSEvent) { changed?(false) }
    }

    func makeNSView(context: Context) -> TrackingView { TrackingView(frame: .zero) }
    func updateNSView(_ view: TrackingView, context: Context) { view.changed = changed }
}

private struct IconTooltip: ViewModifier {
    let text: String
    @State private var hovering = false
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .background { IconHoverArea { hovering = $0 }.accessibilityHidden(true) }
            .task(id: hovering) {
                visible = false
                guard hovering else { return }
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled { visible = true }
            }
            .onDisappear { hovering = false; visible = false }
            .anchorPreference(key: IconTooltipPreference.self, value: .bounds) {
                hovering && visible ? IconTooltipAnchor(text: text, bounds: $0) : nil
            }
    }
}

extension View {
    func iconTooltip(_ text: String) -> some View { modifier(IconTooltip(text: text)) }

    func iconTooltipHost(topInset: CGFloat = 0, sideInset: CGFloat = 12) -> some View {
        overlayPreferenceValue(IconTooltipPreference.self) { tip in
            if let tip {
                GeometryReader { geometry in
                    let button = geometry[tip.bounds]
                    let panel = geometry.size
                    Text(tip.text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .fixedSize()
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Color(white: 0.18), in: RoundedRectangle(cornerRadius: 6))
                        .visualEffect { effect, bubble in
                            let size = bubble.size
                            let x = min(max(sideInset, button.midX - size.width / 2), panel.width - size.width - sideInset)
                            let below = button.maxY + 4
                            let above = button.minY - size.height - 4
                            let y = below + size.height + 8 <= panel.height ? below : max(topInset + 3, above)
                            return effect.offset(x: x, y: y)
                        }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transaction { $0.animation = nil }
            }
        }
    }
}
