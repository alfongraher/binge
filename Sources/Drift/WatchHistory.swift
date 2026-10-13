import Foundation
import SwiftUI

struct WatchRecord: Codable, Identifiable {
    var id: String
    var title: String
    var contentType: String
    var contentID: String?
    var poster: URL?
    var stream: AddonStream
    var genres: [String]
    var position: Double
    var duration: Double
    var dismissed: Bool?
    var background: URL?
    var thumbnail: URL?
    var watchedOverride: Bool?
    var lastWatched: Date
    var titleID: String? {
        guard let contentID else { return nil }
        let parts=contentID.split(separator:":")
        return ["series","anime"].contains(contentType) && parts.count>=3 ? parts.dropLast(2).joined(separator:":") : contentID
    }
    var complete: Bool { watchedOverride ?? CreditsTiming.reached(position:position,duration:duration,type:contentType) }
    var fraction: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }
}

@MainActor
final class WatchHistory: ObservableObject {
    @Published private(set) var records: [WatchRecord] = []
    @Published var error: String?
    private let file: URL
    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Drift/history.json")
        do {
            if FileManager.default.fileExists(atPath: self.file.path) { records = try JSONDecoder().decode([WatchRecord].self, from: Data(contentsOf: self.file)) }
        } catch { self.error = "Could not load viewing history." }
    }
    func record(_ selection: PlaybackSelection, position: Double, duration: Double) {
        guard position.isFinite, duration.isFinite, position > 1 else { return }
        let key = selection.contentID.map { selection.contentType + ":" + $0 } ?? selection.stream.playableSource ?? selection.id.uuidString
        let existing = records.first { $0.id == key }
        let record = WatchRecord(id: key, title: selection.title, contentType: selection.contentType, contentID: selection.contentID, poster: selection.poster,
                                 stream: selection.stream, genres: selection.genres.isEmpty ? existing?.genres ?? [] : selection.genres,
                                 position: position, duration: duration > 0 ? duration : existing?.duration ?? 0, background: existing?.background, thumbnail: existing?.thumbnail, watchedOverride: existing?.complete == true ? true : nil, lastWatched: Date())
        records.removeAll { $0.id == key }; records.insert(record, at: 0)
        save()
    }
    func queueNext(_ selection:PlaybackSelection) {
        let key=selection.contentType+":"+(selection.contentID ?? "")
        guard !records.contains(where:{$0.id==key && $0.complete}) else { return }
        let previous=records.first(where:{$0.id==key})
        var value=WatchRecord(id:key,title:selection.title,contentType:selection.contentType,contentID:selection.contentID,poster:selection.poster,stream:selection.stream,genres:selection.genres,position:previous?.position ?? 0,duration:previous?.duration ?? 0,dismissed:false,background:previous?.background,thumbnail:previous?.thumbnail,watchedOverride:false,lastWatched:Date())
        value.lastWatched=Date();records.removeAll {$0.id==key};records.insert(value,at:0);save()
    }
    func setGenres(_ genres: [String], for id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].genres = genres; save()
    }
    /// Keep full episode history, but show only the last watched entry per series on Home.
    var latestTitles: [WatchRecord] {
        var seen = Set<String>()
        return records.sorted { $0.lastWatched > $1.lastWatched }.filter { record in
            let key: String
            if ["series", "anime"].contains(record.contentType) {
                let parts = record.contentID?.split(separator: ":") ?? []
                let seriesID = parts.count >= 3 ? parts.dropLast(2).joined(separator: ":") : record.contentID
                key = record.contentType + ":" + (seriesID ?? record.title.components(separatedBy: " · ").first ?? record.title)
            } else { key = record.id }
            return seen.insert(key).inserted
        }
    }
    func markWatched(_ episode: CatalogTitle.Episode, watched: Bool, poster: URL?, type: String) {
        let key = type + ":" + episode.id
        if let index = records.firstIndex(where: { $0.id == key }) {
            records[index].watchedOverride=watched
            save(); return
        }
        guard watched else { return }
        let stream = AddonStream()
        records.append(WatchRecord(id: key, title: episode.label, contentType: type, contentID: episode.id, poster: poster, stream: stream, genres: [], position: 1, duration: 1, dismissed: true, watchedOverride:true,lastWatched: .distantPast))
        save()
    }
    var continueWatching: [WatchRecord] {
        latestTitles.filter { $0.dismissed != true && $0.stream.playableSource != nil }
    }
    func dismiss(_ record: WatchRecord) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index].dismissed = true; save()
    }
    var preferredGenres: [String] {
        var scores: [String: Int] = [:]
        for (index, record) in records.prefix(20).enumerated() {
            for genre in record.genres { scores[genre, default: 0] += index < 5 ? 3 : 1 }
        }
        return scores.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(2).map(\.key)
    }
    func setArtwork(_ title:CatalogTitle) {
        for index in records.indices where records[index].titleID==title.id && records[index].contentType==title.type {
            records[index].background=title.background
            records[index].thumbnail=title.videos?.first(where:{$0.id==records[index].contentID})?.thumbnail
        }
        save()
    }
    func applySyncedRecords(_ values:[WatchRecord]) { records=values;save() }
    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: file, options: .atomic)
        } catch { self.error = "Could not save viewing history." }
    }
}
