import Foundation
import AVFoundation
@main struct RecoveryChecks {
    @MainActor static func main() async throws {
        let stream = try JSONDecoder().decode(AddonStream.self, from: JSONSerialization.data(withJSONObject: ["url": CommandLine.arguments[1]]))
        let session = PlaybackSession()
        session.start(PlaybackSelection(title: "Recovery test", stream: stream))
        defer { session.stop() }
        for _ in 0..<100 {
            if session.readyToPlay && session.position > 1 { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        precondition(session.position > 1, "Fixture must play before testing recovery: ready=\(session.readyToPlay), failed=\(session.failed), message=\(session.message), position=\(session.position), native=\(session.player?.currentTime().seconds ?? -1), status=\(session.player?.currentItem?.status.rawValue ?? -1)")
        session.player?.pause() // Simulate a native item stopping despite the user's play intent.
        try await Task.sleep(for: .milliseconds(500))
        let stalled = session.position
        try await Task.sleep(for: .seconds(11))
        precondition(session.position > stalled + 1, "Heartbeat must recover a stopped native item")
        session.togglePause()
        try await Task.sleep(for: .milliseconds(500))
        let paused = session.position
        try await Task.sleep(for: .seconds(9))
        precondition(abs(session.position - paused) < 0.2, "Recovery must respect an explicit user pause")
        session.togglePause()
        try await Task.sleep(for: .seconds(2))
        precondition(session.position > paused + 1, "Explicit resume must still advance")
        session.position = session.duration * 0.96
        session.retainLast()
        precondition(session.player != nil && !session.finished, "Leaving near the end must retain the unfinished episode")
        if CommandLine.arguments.count > 2 {
            session.stop()
            let ending = try JSONDecoder().decode(AddonStream.self, from: JSONSerialization.data(withJSONObject: ["url": CommandLine.arguments[2]]))
            session.start(PlaybackSelection(title: "End test", stream: ending))
            for _ in 0..<75 {
                if session.finished { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            precondition(session.finished && session.player != nil, "Actual end must retain the final frame until exit")
            precondition(session.position == session.duration, "Finished history must receive the final position")
            session.retainLast()
            precondition(session.player == nil, "Exiting completed playback must release the session")
        }
        print("Native playback recovered from an unintended stop, respected user pause, and resumed successfully.")
    }
}
