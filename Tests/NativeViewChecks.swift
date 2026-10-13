import SwiftUI
import AVKit

// Exercises the actual SwiftUI-to-AppKit player wrapper, including view creation.
@main
struct NativeViewChecks: App {
    private let player = AVPlayer(url: URL(fileURLWithPath: "/private/tmp/drift-native-view-sample.mp4"))
    var body: some Scene {
        WindowGroup("Drift player regression check") {
            NativePlayerView(player: player).frame(width: 640, height: 360)
                .task {
                    player.isMuted = true
                    player.play()
                    var result = "FAIL: playback did not advance"
                    for _ in 0..<50 {
                        if player.currentItem?.status == .failed { result = "FAIL: player rejected sample"; break }
                        if player.currentItem?.status == .readyToPlay && player.currentTime().seconds > 1 {
                            result = "PASS: native view created and playback advanced without crashing"
                            break
                        }
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                    player.pause()
                    try? result.write(toFile: "/private/tmp/drift-native-view-result.txt", atomically: true, encoding: .utf8)
                    NSApplication.shared.terminate(nil)
                }
        }
    }
}
