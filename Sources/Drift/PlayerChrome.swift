import SwiftUI
import AppKit

@MainActor
final class PlayerChrome: ObservableObject {
    @Published var playing = false
    @Published var visible = true
    var pinned = false
    private var hideTask: Task<Void, Never>?
    private var monitor: Any?
    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .keyDown]) { [weak self] event in
            let consume: Bool = MainActor.assumeIsolated {
                guard let self, self.playing else { return false }
                self.activity()
                if event.type == .keyDown && event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                    if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.isFieldEditor { return false }
                    let session = PlaybackSession.shared
                    switch event.keyCode {
                    case 49: session.togglePause()
                    case 123: session.seek(session.position - 10)
                    case 124: session.seek(session.position + 10)
                    case 125, 126:
                        if let player = session.player {
                            player.volume = min(1, max(0, player.volume + (event.keyCode == 126 ? 0.05 : -0.05)))
                            player.isMuted = false
                            NotificationCenter.default.post(name: .driftVolumeChanged, object: nil)
                        }
                    default: return false
                    }
                    return true
                }
                return false
            }
            return consume ? nil : event
        }
    }
    func activity() {
        hideTask?.cancel(); visible = true
        guard playing, !pinned else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self, self.playing, !self.pinned else { return }
            withAnimation(.easeInOut(duration: 0.25)) { self.visible = false }
        }
    }
    func begin() { playing = true; NSApp.keyWindow?.acceptsMouseMovedEvents = true; NSApp.keyWindow?.makeFirstResponder(nil); activity() }
    func end() { hideTask?.cancel(); playing = false; visible = true; pinned = false }
}

extension Notification.Name { static let driftVolumeChanged = Notification.Name("DriftVolumeChanged") }
