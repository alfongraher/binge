import Foundation

@main
struct HistoryChecks {
    @MainActor static func main() throws {
        let file = URL(fileURLWithPath: "/private/tmp/drift-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let history = WatchHistory(file: file)
        let stream = try JSONDecoder().decode(AddonStream.self, from: Data(#"{"url":"https://example.com/video.mp4"}"#.utf8))
        let selection = PlaybackSelection(title: "Test story", stream: stream, contentID: "tt123", genres: ["Drama", "Thriller"])
        history.record(selection, position: 0, duration: 100)
        precondition(history.records.isEmpty, "Failed startup should not become viewing history")
        history.record(selection, position: 25, duration: 100)
        precondition(history.records.count == 1 && history.records[0].fraction == 0.25 && !history.records[0].complete)
        let loaded = WatchHistory(file: file)
        precondition(loaded.records[0].position == 25 && loaded.records[0].contentID == "tt123", "Resume state survives restart")
        loaded.record(selection, position: 96, duration: 100)
        precondition(loaded.records.count == 1 && loaded.records[0].complete, "Completed titles are not duplicated")
        precondition(loaded.preferredGenres == ["Drama", "Thriller"], "Recommendations use viewing genres with deterministic ordering")
        let episode1 = PlaybackSelection(title: "Show · S1 E1", stream: stream, contentID: "tt456:1:1", contentType: "series")
        let episode2 = PlaybackSelection(title: "Show · S1 E2", stream: stream, contentID: "tt456:1:2", contentType: "series")
        loaded.record(episode1, position: 20, duration: 100)
        loaded.record(episode2, position: 30, duration: 100)
        precondition(loaded.latestTitles.filter { $0.contentType == "series" }.map(\.contentID) == ["tt456:1:2"])
        precondition(loaded.records.count == 3, "Home grouping preserves individual episode history")
        loaded.record(episode1, position: 99, duration: 100)
        precondition(loaded.latestTitles.first?.contentID == "tt456:1:1", "Latest watched episode wins even if completed")
        precondition(loaded.continueWatching.contains { $0.contentID == episode1.contentID }, "Completed series stay accessible")
        loaded.dismiss(loaded.continueWatching.first { $0.contentID == episode1.contentID }!)
        let dismissed = WatchHistory(file: file)
        precondition(!dismissed.continueWatching.contains { $0.contentType == "series" }, "Dismissal persists without revealing older episodes")
        precondition(dismissed.records.count == 3, "Dismissal keeps watch history")
        dismissed.record(episode2, position: 40, duration: 100)
        precondition(dismissed.continueWatching.contains { $0.contentID == episode2.contentID }, "Watching again returns the series")
        let external = CatalogTitle.Episode(id: "tt456:2:1", title: "Elsewhere", season: 2, episode: 1)
        dismissed.markWatched(external, watched: true, poster: nil, type: "series")
        let marked = WatchHistory(file: file)
        precondition(marked.records.first { $0.contentID == external.id }?.complete == true, "External watched status persists")
        precondition(marked.latestTitles.first?.contentID == episode2.contentID, "External watched status must not replace the last played episode")
        marked.markWatched(external, watched: false, poster: nil, type: "series")
        precondition(marked.records.first { $0.contentID == external.id }?.complete == false)
        print("Viewing history persistence, progress, completion, and recommendation preference checks passed.")
    }
}
