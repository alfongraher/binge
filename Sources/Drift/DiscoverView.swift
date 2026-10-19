import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject private var chrome: PlayerChrome
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var store: AddonStore
    @Binding var query: String
    var submission: Int
    var home: Bool
    var initialEpisodeID: String? = nil
    var initialTitle: FoundTitle? = nil
    var onBack: (() -> Void)? = nil
    var openAddons: () -> Void
    @ViewState<[FoundTitle]> private var titles = []
    @ViewState<FoundTitle?> private var selected: FoundTitle?
    @ViewState<[CatalogTitle.Episode]> private var episodes = []
    @ViewState<String> private var videoID = ""
    @ViewState<[ListedStream]> private var streams = []
    @ViewState<[String]> private var failures = []
    @ViewState<Bool> private var busy = false
    @ViewState<Task<Void, Never>?> private var operation: Task<Void, Never>?
    @ViewState<Set<UUID>> private var savedSources = []
    @ViewState<String> private var resolution = "All"
    @ViewState<PlaybackSelection?> private var playback: PlaybackSelection?
    @ViewState<String> private var contentType="all"
    @ViewState<String> private var genre="All genres"
    @ViewState<[String]> private var genres=[]
    @ViewState<Bool> private var more=true
    @ViewState<[String:Int]> private var offsets=[:]
    private var filteredStreams: [ListedStream] { streams.filter { resolution == "All" || $0.stream.resolution == resolution } }

    var body: some View {
        Group {
        if let selected { details(selected) } else {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                if home {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("A LITTLE ESCAPE").font(.system(size: 10, weight: .semibold, design: .rounded)).tracking(3).foregroundStyle(DriftTheme.accent)
                            Text("Make room for\na good story.").font(.system(size: 38, weight: .semibold, design: .rounded)).tracking(-1)
                            Text("Movies, series, and a library that feels like yours.").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "sparkles.tv").font(.system(size: 68, weight: .ultraLight)).foregroundStyle(DriftTheme.accent.opacity(0.65)).padding(32)
                    }.padding(30).frame(maxWidth: .infinity, alignment: .leading)
                        .background(LinearGradient(colors: [DriftTheme.accent.opacity(0.12), Color.white.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 24))
                } else {
                    HStack {
                        if !query.isEmpty { VStack(alignment: .leading, spacing: 6) {
                            Text("Search results").font(.system(size: 30, weight: .semibold, design: .rounded))
                            Text("Matches for “\(query)”").foregroundStyle(.secondary)
                        }
                        }
                        Spacer()
                        if busy { ProgressView().controlSize(.small) }
                    }
                }
                HStack(spacing:20) {
                    Picker("Type",selection:$contentType) { Text("All types").tag("all");Text("Movies").tag("movie");Text("Series").tag("series") }.pickerStyle(.segmented).frame(width:320)
                    if query.isEmpty {
                        Picker("Genre",selection:$genre) { Text("All genres").tag("All genres");ForEach(genres,id:\.self) { Text($0).tag($0) } }.frame(width:210)
                    }
                    Spacer()
                }
                if !failures.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(failures, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                        if store.addons.isEmpty { Button("Set up add-ons", action: openAddons).buttonStyle(.borderedProminent) }
                        else { Button("Try again") { query.isEmpty ? browse() : search() }.buttonStyle(.bordered) }
                    }
                }
                if busy && titles.isEmpty { HStack { ProgressView(); Text("Finding your next watch…").foregroundStyle(.secondary) }.padding(.vertical, 40) }
                if home {
                    posterRow("Popular movies", type: "movie")
                    posterRow("Series to settle into", type: "series")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145, maximum: 185), spacing: 24)], alignment: .leading, spacing: 28) {
                        ForEach(titles) { found in poster(found) }
                        if more && !busy && query.isEmpty && !titles.isEmpty { ProgressView().task { browse(append:true) } }
                    }
                }
                if !busy && titles.isEmpty && failures.isEmpty {
                    DriftEmptyState(icon: "film.stack", title: "Your next watch is out there", detail: "Search above for a movie or series, or connect a catalog in Add-ons.")
                }
            }.padding(32)
        }
        }
        }
        .task {
            if store.addons.isEmpty { await store.install("https://v3-cinemeta.strem.io/manifest.json") }
            await store.refreshCatalogOptions()
            guard !Task.isCancelled else { return }
            if let initialTitle { select(initialTitle) } else if query.isEmpty || home { browse() } else { search() }
        }
        .onChange(of: submission) { _, _ in if !query.isEmpty { genre="All genres" };query.isEmpty ? browse() : search() }
        .onChange(of:contentType) { _,_ in query.isEmpty ? browse() : search() }
        .onChange(of:genre) { _,_ in if query.isEmpty { browse() } }
        .onDisappear { operation?.cancel(); busy = false }

    }

    @ViewBuilder private func posterRow(_ label: String, type: String) -> some View {
        let entries = titles.filter { $0.title.type == type }
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                HStack { Text(label).font(.system(size: 21, weight: .semibold, design: .rounded)); Spacer(); Text("\(entries.count) titles").font(.caption).foregroundStyle(.tertiary) }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 22) { ForEach(entries) { found in poster(found).frame(width: 150) } }.padding(.bottom, 4)
                }
            }
        }
    }
    private func poster(_ found: FoundTitle) -> some View {
        Button { select(found) } label: {
            PosterCard(title: found.title.name, subtitle: found.title.type == "movie" ? "Movie" : "Series", url: found.title.poster)
        }.buttonStyle(.plain)
    }
    private func details(_ found: FoundTitle) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if let playback {
                PlaybackView(selection: playback, close: { self.playback = nil }, selectEpisode: { episode in self.playback = nil; videoID = episode.id; loadStreams(found, id: episode.id) })
            } else {
            HStack(alignment: .top, spacing: 24) {
                Button { operation?.cancel(); busy = false; failures = []; playback = nil; selected = nil; onBack?() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold)).frame(width: 38, height: 38).background(.regularMaterial, in: Circle())
                }.buttonStyle(.plain).help("Back to browse")
                PosterCard(title: "", subtitle: "", url: found.title.poster, posterHeight: 180).frame(width: 120).clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 12) {
                    Text(found.title.type.uppercased()).font(.caption).tracking(2).foregroundStyle(DriftTheme.accent)
                    Text(found.title.name).font(.system(size: 28, weight: .semibold, design: .rounded))
                    if let description = found.title.description { Text(description).foregroundStyle(.secondary).lineLimit(4).fixedSize(horizontal: false, vertical: true) }
                    if found.title.type != "movie" {
                        Text("Choose a season and episode below").font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(spacing:10) {
                    Button(library.contains(found.title) ? "In library" : "Plan to watch",systemImage:library.contains(found.title) ? "checkmark" : "plus") { library.addCatalog(found.title) }.buttonStyle(.bordered).disabled(library.contains(found.title))
                    Button("Favourite",systemImage:library.isFavourite(found.title) ? "heart.fill" : "heart") { library.toggleFavourite(found.title) }.buttonStyle(.bordered)
                }
                Spacer()

            }
            if found.title.type != "movie" {
                HStack(alignment: .top, spacing: 22) {
                    sourceList(found).frame(minWidth: 400, maxWidth: .infinity)
                    EpisodeBrowser(episodes: episodes, selectedID: videoID, poster: found.title.poster, contentType: found.title.type) { episode in videoID = episode.id; loadStreams(found, id: episode.id) }
                        .padding(16).frame(minWidth: 400, maxWidth: .infinity).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
            } else { sourceList(found) }
            }
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity).background(chrome.playing && !chrome.visible ? Color.black : DriftTheme.background).preferredColorScheme(.dark)
    }

    private func sourceList(_ found: FoundTitle) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Available sources").font(.headline); Spacer(); if busy { ProgressView().controlSize(.small) } else { Text("\(filteredStreams.count) of \(streams.count)").foregroundStyle(.secondary) } }
            if !streams.isEmpty {
                Button("Watch automatically", systemImage: "sparkles") {
                    let candidates = filteredStreams.filter {SourcePolicy.eligible($0.stream)}.map(\.stream)
                    if let source = candidates.first {
                        let episode = episodes.first { $0.id == videoID }
                        playback = PlaybackSelection(title: found.title.name + (episode.map { " · \($0.label)" } ?? ""), stream: source, poster: found.title.poster, contentID: found.title.type == "movie" ? found.title.id : videoID, contentType: found.title.type, genres: found.title.genres ?? [], episodes: episodes, seriesTitle: found.title.name, automaticSources: candidates)
                    }
                }.buttonStyle(.borderedProminent).disabled(busy)
            }
            Picker("Resolution", selection: $resolution) {
                ForEach(["All", "4K", "1080p", "720p", "SD", "Unknown"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented)
            ForEach(failures, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            if streams.isEmpty && !busy {
                Text(found.title.type != "movie" && videoID.isEmpty ? "Choose an episode to see its sources." : "No sources yet. Connect a stream provider in Add-ons.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(24)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(filteredStreams) { listed in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(listed.stream.name ?? listed.addonName).font(.headline)
                                if listed.id==filteredStreams.first(where:{SourcePolicy.recommendable($0.stream)})?.id { Label("Recommended",systemImage:"sparkles").font(.caption.weight(.semibold)).foregroundStyle(DriftTheme.accent) }
                                Text(listed.stream.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                Text(listed.addonName).font(.caption).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            if listed.stream.playableSource != nil {
                                VStack(alignment: .trailing, spacing: 10) {
                                Button("Watch", systemImage: "play.fill") {
                                    let episode = episodes.first { $0.id == videoID }
                                    playback = PlaybackSelection(title: found.title.name + (episode.map { " · \($0.label)" } ?? ""), stream: listed.stream, poster: found.title.poster, contentID: found.title.type == "movie" ? found.title.id : videoID, contentType: found.title.type, genres: found.title.genres ?? [], episodes: episodes, seriesTitle: found.title.name)
                                }.buttonStyle(.borderedProminent)
                                Button(savedSources.contains(listed.id) ? "Saved" : "Add to library") { save(listed, for: found); savedSources.insert(listed.id) }.buttonStyle(.bordered).disabled(savedSources.contains(listed.id))
                                }
                            } else { Text("Unsupported source").font(.caption).foregroundStyle(.secondary) }
                        }.padding(16).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            if filteredStreams.isEmpty && !streams.isEmpty { Text("No sources match this resolution.").foregroundStyle(.secondary) }
            Text("Watch immediately, or save a source for later. Quality is based on provider labels.").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func browse(append:Bool=false) {
        guard !append || (!busy && more) else { return }
        operation?.cancel(); busy = true; if !append { titles = []; offsets=[:];more=true }; failures = []
        let addons = store.addons
        let browsingCatalogs=addons.flatMap { addon in
            ["movie","series"].filter { contentType=="all" || $0==contentType }.compactMap { type in
                addon.manifest.catalogs?.first(where:{$0.type==type && ($0.extraRequired ?? []).isEmpty && !($0.extra ?? []).contains(where:{$0.isRequired == true})})
            }
        }
        genres=Array(Set(browsingCatalogs.flatMap {$0.extra?.first(where:{$0.name=="genre"})?.options ?? []})).sorted()
        if genre != "All genres" && !genres.contains(genre) { genre="All genres";return }
        operation = Task {
            var found: [FoundTitle] = []; var errors: [String] = []
            for addon in addons {
                for type in ["movie", "series"] where contentType=="all" || contentType==type {
                    guard let catalog = addon.manifest.catalogs?.first(where: {
                        $0.type == type && ($0.extraRequired ?? []).isEmpty && !($0.extra ?? []).contains(where: { $0.isRequired == true })
                    }) else { continue }
                    do {
                        let options=catalog.extra?.first(where:{$0.name=="genre"})?.options ?? []
                        if genre != "All genres" && !options.contains(genre) { continue }
                        let key=addon.id+":"+catalog.type+":"+catalog.id
                        let page=try await AddonClient().browsePage(addon,catalog:catalog,genre:genre=="All genres" ? nil : genre,skip:offsets[key] ?? 0)
                        guard !Task.isCancelled else { return };offsets[key,default:0]+=page.count;found+=page
                    }
                    catch { if Task.isCancelled { return }; errors.append("\(addon.manifest.name) could not load its catalog.") }
                }
            }
            guard !Task.isCancelled else { return }
            var seen = Set(append ? titles.map(\.id) : []);let fresh=found.filter { seen.insert($0.id).inserted };more = !fresh.isEmpty;if append { titles+=fresh } else { titles=fresh }
            failures = Array(Set(errors)).sorted(); busy = false
            if titles.isEmpty && failures.isEmpty { failures = ["Connect a catalog in Add-ons to start exploring."] }
        }
    }

    private func search() {
        operation?.cancel(); busy = true; titles = []; selected = nil; streams = []; episodes = []; failures = []
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let addons = store.addons
        operation = Task {
            var found: [FoundTitle] = []; var errors: [String] = []
            for addon in addons {
                for catalog in addon.manifest.catalogs ?? [] where catalog.searchable && (contentType=="all" || catalog.type==contentType) {
                    do { found += try await AddonClient().search(addon, catalog: catalog, query: term) }
                    catch { if Task.isCancelled { return }; errors.append("\(addon.manifest.name): title search failed.") }
                }
            }
            guard !Task.isCancelled else { return }
            var seen = Set<String>()
            let unique = found.filter { seen.insert($0.id).inserted }
            var ranks: [String: Int] = [:]
            for addon in addons {
                let values = await CatalogPopularity.shared.ranks(addon)
                for (key, value) in values { ranks[key] = max(ranks[key] ?? 0, value) }
            }
            guard !Task.isCancelled else { return }
            titles = CatalogPopularity.ranked(unique, ranks: ranks)
            failures = Array(Set(errors)).sorted()
            if !addons.contains(where: { ($0.manifest.catalogs ?? []).contains(where: \.searchable) }) {
                failures = ["Install a searchable catalog add-on, such as Cinemeta."]
            } else if titles.isEmpty && failures.isEmpty { failures = ["No matching titles."] }
            busy = false
        }
    }
    private func select(_ found: FoundTitle) {
        operation?.cancel(); resolution = "All"; playback = nil; selected = found; streams = []; episodes = []; videoID = ""; failures = []
        busy = true
        operation = Task {
            do {
                let detail = try await AddonClient().metadata(found)
                guard !Task.isCancelled else { return }
                selected = FoundTitle(title: detail, addon: found.addon)
                if detail.type=="movie" { loadStreams(FoundTitle(title:detail,addon:found.addon),id:detail.id);return }
                episodes = detail.videos ?? []
                if let initialEpisodeID, episodes.contains(where: { $0.id == initialEpisodeID }) {
                    videoID = initialEpisodeID; loadStreams(found, id: initialEpisodeID); return
                }
                if episodes.isEmpty { failures = ["This catalog did not provide episode IDs."] }
            } catch {
                if Task.isCancelled { return }
                if found.title.type=="movie" { loadStreams(found,id:found.title.id);return }
                failures = ["Could not load episodes. Try selecting the show again."]
            }
            busy = false
        }
    }
    private func loadStreams(_ found: FoundTitle, id: String) {
        operation?.cancel(); resolution = "All"; busy = true; streams = []; failures = []
        let addons = store.addons.filter { $0.manifest.supports("stream", type: found.title.type, id: id) }
        operation = Task {
            var results: [ListedStream] = []; var errors: [String] = []
            for addon in addons {
                do { results += try await AddonClient().streams(addon, type: found.title.type, id: id) }
                catch { if Task.isCancelled { return }; errors.append("\(addon.manifest.name): source request failed.") }
            }
            guard !Task.isCancelled else { return }
            let profile=SourceExperience.shared.profile
            let ordered=await SourcePolicy.orderedAsync(results,profile:profile,duration:found.title.estimatedDuration)
            guard !Task.isCancelled else {return}
            streams = ordered; failures = errors
            if addons.isEmpty { failures = ["No installed stream add-on supports this title."] }
            else if results.isEmpty && errors.isEmpty { failures = ["No sources returned for this title."] }
            busy = false
        }
    }
    private func save(_ listed: ListedStream, for found: FoundTitle) {
        guard let source = listed.stream.playableSource else { return }
        let episode = episodes.first { $0.id == videoID }
        let title = found.title.name + (episode.map { " · \($0.label)" } ?? "")
        library.add(title: title, source: source, kind: found.title.type == "movie" ? "Movie" : "TV episode", poster: found.title.poster, stream: listed.stream, contentID: found.title.type == "movie" ? found.title.id : videoID)
    }
}
