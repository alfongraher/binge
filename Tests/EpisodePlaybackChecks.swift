import Foundation
@main struct EpisodePlaybackChecks {
    static func main() throws {
        func episode(_ id: String, _ season: Int, _ number: Int, released: String? = nil) -> CatalogTitle.Episode { .init(id: id, released: released, season: season, episode: number) }
        let first = episode("show:1:1", 1, 1), second = episode("show:1:2", 1, 2), third = episode("show:2:1", 2, 1)
        precondition(EpisodePlayback.next(after: first.id, episodes: [third, second, first])?.id == second.id)
        precondition(EpisodePlayback.next(after: second.id, episodes: [third, second, first])?.id == third.id)
        precondition(EpisodePlayback.next(after: third.id, episodes: [third, second, first]) == nil)
        for date in ["2099-01-01", "2099-01-01T00:00:00Z", "2099-01-01T00:00:00.000Z"] {
            precondition(EpisodePlayback.next(after: first.id, episodes: [first, episode(second.id, 1, 2, released: date)]) == nil)
        }
        precondition(EpisodePlayback.seriesID("kitsu:123:1:2") == "kitsu:123")
        func stream(_ hash: String, _ index: Int) throws -> AddonStream { try JSONDecoder().decode(AddonStream.self, from: JSONSerialization.data(withJSONObject: ["infoHash": hash, "fileIdx": index, "name": "1080p"])) }
        let current = try stream(String(repeating: "a", count: 40), 1), same = try stream(String(repeating: "a", count: 40), 2), other = try stream(String(repeating: "b", count: 40), 1)
        let choices = EpisodePlayback.preferred([other, current, same], matching: current, throughput: 1_000_000)
        precondition(choices.count == 2 && choices.first?.infoHash == same.infoHash)
        print("Episode ordering, season transitions, release dates, and same-pack source preference passed.")
    }
}
