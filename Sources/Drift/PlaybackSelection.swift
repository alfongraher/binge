import Foundation

struct PlaybackSelection: Identifiable {
    var id = UUID()
    var title: String
    var stream: AddonStream
    var poster: URL? = nil
    var contentID: String? = nil
    var contentType = "movie"
    var genres: [String] = []
    var episodes: [CatalogTitle.Episode] = []
    var seriesTitle: String? = nil
    var resumePosition: Double = 0
    var automaticSources: [AddonStream] = []
}

