import Foundation

@main
struct AddonChecks {
    static func check(_ condition: Bool, _ label: String) throws {
        if !condition { throw NSError(domain: "AddonChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
    }
    static func main() async throws {
        let manifestJSON = #"{"id":"test","name":"Test","version":"1","types":["movie","series"],"idPrefixes":["tt"],"resources":["meta",{"name":"stream","types":["series"],"idPrefixes":["tt"]},{"name":"stream","types":["movie"]}],"catalogs":[{"id":"top","type":"movie","extra":[{"name":"search"}]},{"id":"genre","type":"movie","extra":[{"name":"search"},{"name":"genre","isRequired":true}]}]}"#
        let manifest = try JSONDecoder().decode(AddonManifest.self, from: Data(manifestJSON.utf8))
        try check(manifest.supports("meta", type: "movie", id: "tt123"), "short resource inherits filtering")
        try check(!manifest.supports("meta", type: "movie", id: "custom"), "short resource rejects wrong prefix")
        try check(manifest.supports("stream", type: "movie", id: "custom"), "full resource without prefixes matches all IDs")
        try check(manifest.supports("stream", type: "series", id: "tt123:2:3"), "episode IDs match without being rewritten")
        try check(!manifest.supports("stream", type: "series", id: "custom"), "full resource prefix filtering")
        try check(manifest.catalogs![0].searchable && !manifest.catalogs![1].searchable, "required extras do not produce invalid searches")
        let roundtrip = try JSONDecoder().decode(AddonManifest.self, from: JSONEncoder().encode(manifest))
        try check(roundtrip.resources[0].short, "persisted manifest preserves short resource semantics")
        let configured = try AddonClient.manifestURL("https://example.com/config/token/manifest.json")
        let endpoint = AddonClient.endpoint(configured, components: ["stream", "series", "tt123:2:3.json"])
        try check(endpoint.path == "/config/token/stream/series/tt123:2:3.json", "configuration path and episode ID preservation")
        let hash = String(repeating: "a", count: 40)
        let streamJSON = "{\"infoHash\":\"\(hash)\",\"fileIdx\":7,\"sources\":[\"tracker:https://example.com/announce?a=1&b=2\",\"dht:node\"],\"behaviorHints\":{\"filename\":\"episode.mkv\",\"bingeGroup\":\"1080\"}}"
        let stream = try JSONDecoder().decode(AddonStream.self, from: Data(streamJSON.utf8))
        let saved = try JSONDecoder().decode(AddonStream.self, from: JSONEncoder().encode(stream))
        try check(saved.fileIdx == 7 && saved.sources?.count == 2 && saved.behaviorHints?.filename == "episode.mkv", "torrent selection survives persistence")
        let magnet = URLComponents(string: stream.playableSource!)!
        try check(magnet.queryItems?.first(where: { $0.name == "tr" })?.value == "https://example.com/announce?a=1&b=2", "tracker query values survive magnet encoding")
        let unsupported = try JSONDecoder().decode(AddonStream.self, from: Data(#"{"ytId":"abc"}"#.utf8))
        try check(unsupported.playableSource == nil, "unsupported sources do not become playable")
        for (label, expected) in [("Torrentio 4k DV | HDR", "4K"), ("movie.2160p.WEB", "4K"), ("1080p", "1080p"), ("720p", "720p"), ("576p", "SD"), ("Unknown source", "Unknown"), ("movie.10800p", "Unknown")] {
            let data = try JSONSerialization.data(withJSONObject: ["name": label])
            let source = try JSONDecoder().decode(AddonStream.self, from: data)
            try check(source.resolution == expected, "resolution label: " + label)
        }
        let srt = "1\r\n00:00:01,000 --> 00:00:03,500\r\n<i>Hello</i>\r\nworld\r\n\r\n2\r\n00:00:04,000 --> 00:00:05,000\r\nNext\r\n"
        let cues = SubtitleParser.parse(srt)
        try check(cues.count == 2 && cues[0].text == "Hello\nworld", "SRT cue parsing and formatting")
        try check(SubtitleParser.active(cues, time: 2, delay: 0) == "Hello\nworld", "playback-clock synchronization")
        try check(SubtitleParser.active(cues, time: 2, delay: 2).isEmpty, "positive timing delay")
        try check(SubtitleParser.active(cues, time: 4, delay: 0) == "Next", "seek updates cue")
        let vtt = SubtitleParser.parse("WEBVTT\n\n00:01.000 --> 00:02.000 align:center\nCaption\n")
        try check(vtt.count == 1 && vtt[0].start == 1, "WebVTT timings with cue settings")
        try check(SubtitleParser.parse("not subtitles").isEmpty, "unsupported subtitle content rejected")
        let testAddon = InstalledAddon(manifestURL: configured, manifest: manifest)
        let obscure = FoundTitle(title: CatalogTitle(id: "tt-obscure", type: "movie", name: "Obscure matching movie"), addon: testAddon)
        let popular = FoundTitle(title: CatalogTitle(id: "tt-popular", type: "series", name: "Popular matching series"), addon: testAddon)
        try check(CatalogPopularity.ranked([obscure, popular], ranks: [popular.id: 50]).first?.id == popular.id, "popular series ranks ahead of unranked movie")
        try check(CatalogPopularity.ranked([obscure, popular], ranks: [:]).first?.id == obscure.id, "unranked results retain provider order")
        print("Protocol, resolution, subtitles, and ranking fixture checks passed.")
        if CommandLine.arguments.contains("--live") {
            let client = AddonClient()
            let subtitleAddon = try await client.install("https://opensubtitles-v3.strem.io/manifest.json")
            let subtitles = try await client.subtitles(subtitleAddon, type: "movie", id: "tt1254207")
            if let track = subtitles.first(where: { $0.lang == "eng" }) ?? subtitles.first {
                let cues = try await client.subtitleFile(track)
                try check(!cues.isEmpty, "live subtitle file parses")
                print("Live subtitle search and download passed (\(subtitles.count) tracks).")
            } else { print("Live subtitle search returned no tracks for the test title.") }
            let catalog = try await client.install("https://v3-cinemeta.strem.io/manifest.json")
            if let genreCatalog = catalog.manifest.catalogs?.first(where: { $0.type == "movie" && ($0.extraSupported ?? []).contains("genre") }) {
                let recommendations = try await client.recommendations(catalog, catalog: genreCatalog, genre: "Drama")
                try check(!recommendations.isEmpty, "live genre recommendation catalog returns titles")
                print("Live genre recommendation query passed.")
            }
            let torrentio = try await client.install("https://torrentio.strem.fun/manifest.json")
            let searchCatalog = catalog.manifest.catalogs!.first { $0.type == "movie" && $0.searchable }!
            let titles = try await client.search(catalog, catalog: searchCatalog, query: "Big Buck Bunny")
            try check(!titles.isEmpty, "live search returns titles")
            let sources = try await client.streams(torrentio, type: "movie", id: "tt1254207")
            let show = FoundTitle(title: CatalogTitle(id: "tt0944947", type: "series", name: "Episode metadata check"), addon: catalog)
            let metadata = try await client.metadata(show)
            try check(metadata.videos?.contains { $0.season != nil && $0.episode != nil && !$0.id.isEmpty } == true, "live series metadata supplies episode IDs")
            print("Live manifest + catalog + episode metadata + stream requests passed (\(titles.count) titles, \(sources.count) sources). No media downloaded.")
        }
    }
}
