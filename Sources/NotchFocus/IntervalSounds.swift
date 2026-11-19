import AppKit

@MainActor
final class IntervalSounds {
    private let reminder: NSSound?
    private let rest: NSSound?
    private let next: NSSound?

    init() {
        let installed = Bundle.main.url(forResource: "NotchFocus_NotchFocus", withExtension: "bundle").flatMap(Bundle.init(url:))
        let resources = installed ?? Bundle.module
        func sound(_ name: String) -> NSSound? {
            resources.url(forResource: name, withExtension: "wav").flatMap { NSSound(contentsOf: $0, byReference: false) }
        }
        reminder = sound("FocusReminder")
        rest = sound("Rest")
        next = sound("Return")
    }

    func play(_ boundary: FocusBoundary) {
        let sound: NSSound?
        switch boundary {
        case .focusReminder: sound = reminder
        case .breakStarted: sound = rest
        case .breakEnded: sound = next
        }
        guard let sound else { NSSound.beep(); return }
        if sound.isPlaying { sound.stop() }
        sound.currentTime = 0
        sound.play()
    }
}
