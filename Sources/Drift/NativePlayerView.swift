import SwiftUI
import AVKit

// Avoid _AVKit_SwiftUI's VideoPlayer generic metadata path, which aborted on this Mac.
struct NativePlayerView: NSViewRepresentable {
    var player: AVPlayer
    var showsControls = true
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = showsControls ? .floating : .none
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        view.allowsVideoFrameAnalysis = false
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        let style: AVPlayerViewControlsStyle = showsControls ? .floating : .none
        if view.controlsStyle != style { view.controlsStyle = style }
        if view.player !== player { view.player = player }
    }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }
}

