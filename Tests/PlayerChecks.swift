import Foundation
import AVFoundation
@main struct PlayerChecks {
    @MainActor static func main() async throws {
        let item = AVPlayerItem(url: URL(string: CommandLine.arguments[1])!)
        let player = AVPlayer(playerItem: item)
        let target = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 0.5 : 0.5
        item.preferredForwardBufferDuration = 12
        player.play()
        for _ in 0..<Int((target + 25) * 5) {
            if item.status == .failed { throw NSError(domain: "PlayerChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "AVPlayer rejected stream."]) }
            if item.status == .readyToPlay && player.currentTime().seconds > target {
                player.pause(); print("Native AVPlayer advanced beyond \(target) seconds."); return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw NSError(domain: "PlayerChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Native clock \(player.currentTime().seconds), rate \(player.rate), state \(player.timeControlStatus.rawValue), reason \(player.reasonForWaitingToPlay?.rawValue ?? "none"), errors \(item.errorLog()?.events.map { $0.errorComment ?? "unknown" } ?? [])"])
    }
}
