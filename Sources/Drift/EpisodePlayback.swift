import Foundation

struct EpisodePlayback {
    static func seriesID(_ id: String?) -> String? {
        guard let id else { return nil }
        let parts = id.split(separator: ":")
        return parts.count >= 3 ? parts.dropLast(2).joined(separator: ":") : id
    }
    static func next(after id: String?, episodes: [CatalogTitle.Episode], now: Date = Date()) -> CatalogTitle.Episode? {
        let ordered = episodes.filter { ($0.season ?? 0) > 0 && ($0.episode ?? 0) > 0 }.sorted {
            ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0)
        }
        guard let index = ordered.firstIndex(where: { $0.id == id }), index + 1 < ordered.count else { return nil }
        let next = ordered[index + 1]
        if let released = next.released {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fractional = formatter.date(from: released)
            formatter.formatOptions = [.withInternetDateTime]
            let calendar = DateFormatter(); calendar.locale = Locale(identifier: "en_US_POSIX"); calendar.timeZone = TimeZone(secondsFromGMT: 0); calendar.dateFormat = "yyyy-MM-dd"
            if let date = fractional ?? formatter.date(from: released) ?? calendar.date(from: released), date > now { return nil }
        }
        return next
    }
    static func preferred(_ streams: [AddonStream], matching current: AddonStream, throughput: Double) -> [AddonStream] {
        SourcePolicy.ranked(streams, throughput: throughput, duration: 2700).filter {
            !($0.infoHash != nil && $0.infoHash == current.infoHash && $0.fileIdx == current.fileIdx)
        }.enumerated().sorted {
            func affinity(_ stream: AddonStream) -> Int {
                if stream.infoHash != nil && stream.infoHash == current.infoHash && stream.fileIdx != nil { return 1000 }
                if let group = current.behaviorHints?.bingeGroup, !group.isEmpty, stream.behaviorHints?.bingeGroup == group { return 900 }
                return (stream.resolution == current.resolution ? 60 : 0) + (stream.name == current.name ? 40 : 0)
            }
            let first = affinity($0.element), second = affinity($1.element)
            return first == second ? $0.offset < $1.offset : first > second
        }.map(\.element)
    }
}
