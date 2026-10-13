import SwiftUI

struct EpisodeBrowser: View {
    var episodes: [CatalogTitle.Episode]
    var selectedID: String
    var poster: URL? = nil
    var contentType: String = "series"
    var choose: (CatalogTitle.Episode) -> Void
    @ViewState<Int> private var season = 1
    @EnvironmentObject private var history: WatchHistory
    private var lastWatchedID: String? {
        let ids = Set(episodes.map(\.id))
        return history.records.filter { $0.contentID.map(ids.contains) == true && $0.lastWatched != .distantPast }.max { $0.lastWatched < $1.lastWatched }?.contentID
    }
    private var focusID: String? { episodes.contains { $0.id == selectedID } ? selectedID : lastWatchedID }
    private var watchedIDs: Set<String> { Set(history.records.filter(\.complete).compactMap(\.contentID)) }
    private var seasons: [Int] { Array(Set(episodes.map { $0.season ?? 0 })).sorted() }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Picker("Season", selection: $season) { ForEach(seasons, id: \.self) { Text($0 == 0 ? "Specials" : "Season \($0)").tag($0) } }.frame(width: 160)
                Spacer()

            }
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(episodes.filter { ($0.season ?? 0) == season }.sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }) { episode in
                        Button { choose(episode) } label: {
                            HStack(spacing: 14) {
                                AsyncImage(url: episode.thumbnail) { image in image.resizable().scaledToFill() } placeholder: { ZStack { Color.white.opacity(0.06); Image(systemName: "play.rectangle").foregroundStyle(.secondary) } }.frame(width: 100, height: 58).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\(episode.episode ?? 0). " + (episode.title ?? episode.name ?? "Episode \(episode.episode ?? 0)")).font(.callout.weight(.medium))
                                    if let date = episode.released { Text(String(date.prefix(10))).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if watchedIDs.contains(episode.id) { Label("Watched", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(DriftTheme.accent) }
                                if lastWatchedID == episode.id { Text("Last watched").font(.caption2.weight(.semibold)).foregroundStyle(DriftTheme.accent) }
                                if selectedID == episode.id { Image(systemName: "play.circle.fill").foregroundStyle(DriftTheme.accent) }
                            }.padding(10).background((selectedID == episode.id || lastWatchedID == episode.id) ? DriftTheme.accent.opacity(0.12) : .white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain).id(episode.id)
                        .contextMenu {
                            Button(watchedIDs.contains(episode.id) ? "Mark as unwatched" : "Mark as watched") {
                                history.markWatched(episode, watched: !watchedIDs.contains(episode.id), poster: poster, type: contentType)
                            }
                        }
                    }
                }
            }
            .task(id: focusID) {
                guard let id = focusID, let episode = episodes.first(where: { $0.id == id }) else { season = seasons.first ?? 1; return }
                season = episode.season ?? 1
                await Task.yield()
                proxy.scrollTo(id, anchor: .top)
            }
            .onChange(of: season) { _, _ in
                if let id = focusID, episodes.first(where: { $0.id == id })?.season == season { proxy.scrollTo(id, anchor: .top) }
            }
            }
        }
    }
}
