import SwiftUI
import SafariServices
struct IPadAppView:View {
    @StateObject private var library=IPadLibrary()
    @State private var tab="home"
    @StateObject private var addons=AddonStore.shared
    @StateObject private var sync=LocalSync.shared
    @StateObject private var settings=BingeSettingsPresentation()
    @ObservedObject private var history=IPadHistory.shared
    @Environment(\.scenePhase) private var phase
    init() { _ = IPadCacheStore.shared }
    var body:some View {
        TabView(selection:$tab) {
            IPadHomeView().tabItem { Label("Home",systemImage:"house") }.tag("home")
            IPadBrowseView().tabItem { Label("Explore",systemImage:"safari") }.tag("explore")
            IPadSavedView(explore:{tab="explore"}).tabItem { Label("Library",systemImage:"books.vertical") }.tag("library")
        }.environmentObject(library).environmentObject(addons).environmentObject(sync).environmentObject(settings)
        .sheet(isPresented:$settings.presented) {
            NavigationStack { BingeSettingsView().navigationTitle("Settings").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { settings.presented=false } } } }
                .environmentObject(addons).environmentObject(sync)
        }
        .task { if ProcessInfo.processInfo.arguments.contains("--settings") { settings.presented=true };sync.setActive(phase == .active);sync.configure(capture:{IPadSyncAdapter.snapshot(history:history,library:library)},apply:{IPadSyncAdapter.apply($0,history:history,library:library)});await addons.ensureDefaults() }
        .onReceive(history.$records.dropFirst()) { _ in sync.localChanged() }
        .onReceive(library.$titles.dropFirst()) { _ in sync.localChanged() }
        .onChange(of:phase) { _,value in sync.setActive(value == .active) }
        .tint(Color(red:0.96,green:0.77,blue:0.36)).preferredColorScheme(.dark)
    }
}
struct IPadBrowseView:View {
    @ObservedObject private var addons=AddonStore.shared
    @ViewState<String> private var query=""
    @ViewState<String> private var submitted=""
    @ViewState<String> private var type="movie"
    @ViewState<String> private var genre="All genres"
    @ViewState<[String]> private var genres=[]
    @ViewState<InstalledAddon?> private var catalog:InstalledAddon?
    @ViewState<[FoundTitle]> private var titles=[]
    @ViewState<Bool> private var busy=false
    @ViewState<String?> private var error:String?
    @ViewState<Bool> private var more=true
    @ViewState<Int> private var offset=0
    @ViewState<UUID> private var pageGeneration=UUID()
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:24) {
                    ViewThatFits(in:.horizontal) {
                        HStack(spacing:20) { filters }
                        VStack(alignment:.leading,spacing:16) { filters }
                    }
                    if busy { ProgressView("Finding stories…") }
                    if let error { Text(error).foregroundStyle(.secondary);Button("Try again") { Task { await load() } } }
                    LazyVGrid(columns:[GridItem(.adaptive(minimum:140,maximum:190),spacing:20)],alignment:.leading,spacing:24) {
                        ForEach(titles) { found in NavigationLink { IPadTitleView(found:found) } label: { IPadPoster(name:found.title.name,url:found.title.poster) }.buttonStyle(.plain) }
                        if more && !busy && !titles.isEmpty && submitted.isEmpty { ProgressView().onAppear { Task { await loadMore() } } }
                    }
                    if !busy && error==nil && titles.isEmpty { ContentUnavailableView.search(text:submitted) }
                }.padding(24)
            }.navigationTitle("Explore").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement:.topBarTrailing) { IPadSettingsButton() } }
            .searchable(text:$query,prompt:"Movies and TV shows").onSubmit(of:.search) { genre="All genres";submitted=query.trimmingCharacters(in:.whitespacesAndNewlines) }
            .onChange(of:query) { _, value in if value.isEmpty { submitted="" } }
            .task(id:type+"|"+submitted+"|"+genre+"|"+addons.addons.map(\.id).joined(separator:"|")) { await load() }
        }
    }
    @ViewBuilder private var filters:some View {
        Picker("Titles",selection:$type) { Text("Movies").tag("movie");Text("TV shows").tag("series") }.pickerStyle(.segmented).frame(maxWidth:320)
        if submitted.isEmpty {
            Picker("Genre",selection:$genre) {
                Text("All genres").tag("All genres")
                ForEach(genres,id:\.self) { Text($0).tag($0) }
            }.pickerStyle(.menu).padding(.horizontal,8).background(.white.opacity(0.06),in:Capsule())
        }
    }
    private func load() async {
        pageGeneration=UUID();more=true;offset=0;busy=true;error=nil;titles=[];defer { if !Task.isCancelled { busy=false } }
        do {
            let client=AddonClient()
            let catalog:InstalledAddon
            catalog=try await addons.readyCatalog(type:type)
            try Task.checkCancellation();self.catalog=catalog
            guard let entry=catalog.manifest.catalogs?.first(where:{$0.type==type && $0.id=="top"}) else { throw AddonError.data }
            genres=entry.extra?.first(where:{$0.name=="genre"})?.options ?? []
            if genre != "All genres" && !genres.contains(genre) { genre="All genres";return }
            let results:[FoundTitle]
            if submitted.isEmpty && genre != "All genres" { results=try await client.recommendations(catalog,catalog:entry,genre:genre) }
            else if submitted.isEmpty { results=try await client.browse(catalog,catalog:entry) }
            else { results=try await client.search(catalog,catalog:entry,query:submitted) }
            try Task.checkCancellation();titles=results;offset=results.count;more = !results.isEmpty
            let report:[String:Any]=["type":type,"query":submitted,"genre":genre,"count":results.count,"date":ISO8601DateFormatter().string(from:Date())]
            if let data=try? JSONSerialization.data(withJSONObject:report,options:.prettyPrinted) { try? data.write(to:FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("catalog-result.json")) }
        } catch is CancellationError { } catch { if !Task.isCancelled { self.error=error.localizedDescription } }
    }
    private func loadMore() async {
        guard !busy,more,submitted.isEmpty,let catalog,let entry=catalog.manifest.catalogs?.first(where:{$0.type==type && $0.id=="top"}) else { return }
        let generation=pageGeneration;busy=true
        defer { if generation==pageGeneration { busy=false } }
        do {
            let result=try await AddonClient().browsePage(catalog,catalog:entry,genre:genre=="All genres" ? nil : genre,skip:offset)
            guard generation==pageGeneration,!Task.isCancelled else { return }
            let known=Set(titles.map(\.id));let fresh=result.filter {!known.contains($0.id)}
            offset+=result.count;more = !fresh.isEmpty;titles+=fresh
        } catch is CancellationError {
        } catch { if generation==pageGeneration && !Task.isCancelled { more=false;self.error="Couldn’t load more titles. Try again." } }
    }

}
struct IPadPoster:View {
    var name:String
    var url:URL?
    var homeType:String?=nil
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            GeometryReader { geo in
                AsyncImage(url:url) { image in image.resizable().scaledToFill() } placeholder: { RoundedRectangle(cornerRadius:14).fill(.white.opacity(0.06)).overlay(Image(systemName:"film").foregroundStyle(.secondary)) }
                    .frame(width:geo.size.width,height:geo.size.height).clipped().clipShape(RoundedRectangle(cornerRadius:14))
                    .overlay(alignment:.topLeading) { if let homeType { IPadHomeTypeTag(type:homeType).padding(8) } }
            }.aspectRatio(2.0/3.0,contentMode:.fit)
            Text(name).font(.subheadline.weight(.medium)).lineLimit(2).frame(height:38,alignment:.topLeading)
        }
    }
}
struct IPadTitleView:View {
    var found:FoundTitle
    @EnvironmentObject private var library:IPadLibrary
    @ObservedObject private var history=IPadHistory.shared
    @ViewState<CatalogTitle?> private var detail:CatalogTitle?
    @ViewState<Int> private var season=1
    @ViewState<String> private var episodeID=""
    @ViewState<[ListedStream]> private var streams=[]
    @ViewState<Bool> private var findingSources=false
    @ViewState<String> private var resolution="All"
    @ViewState<UUID> private var sourceRequest=UUID()
    @ViewState<String?> private var error:String?
    var body:some View {
        let title=detail ?? found.title
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                HStack(alignment:.top,spacing:24) {
                    IPadPoster(name:"",url:title.poster).frame(width:150)
                    VStack(alignment:.leading,spacing:14) {
                        Text(title.name).font(.largeTitle.bold())
                        Text((title.genres ?? []).joined(separator:" · ")).foregroundStyle(.secondary)
                        Text(title.description ?? "").foregroundStyle(.secondary)
                        HStack(spacing:12) {
                            if library.contains(title) {
                                Menu {
                                    ForEach(IPadLibraryStatus.allCases,id:\.self) { status in
                                        Button(status.label,systemImage:status.icon) { library.setStatus(status,for:title) }
                                    }
                                    Button("Use viewing progress",systemImage:"arrow.clockwise") { library.setStatus(nil,for:title) }
                                    Button("Remove from library",systemImage:"trash",role:.destructive) { library.toggle(title) }
                                } label: { Label("In library",systemImage:"checkmark") }.buttonStyle(.bordered)
                            } else {
                                Button("Plan to watch",systemImage:"plus") { library.toggle(title) }.buttonStyle(.bordered)
                            }
                            Button { library.toggleFavourite(title) } label: {
                                Label("Favourite",systemImage:library.isFavourite(title) ? "heart.fill" : "heart")
                            }.buttonStyle(.bordered).accessibilityLabel(library.isFavourite(title) ? "Remove from favourites" : "Add to favourites")
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.secondary) }
                if let episodes=title.videos,!episodes.isEmpty {
                    Picker("Season",selection:$season) { ForEach(Array(Set(episodes.compactMap(\.season))).sorted(),id:\.self) { Text($0==0 ? "Specials" : "Season \($0)").tag($0) } }.frame(maxWidth:220)
                    LazyVStack(alignment:.leading,spacing:14) {
                        ForEach(episodes.filter {$0.season==season}.sorted { ($0.episode ?? 0)<($1.episode ?? 0) }) { episode in
                            NavigationLink { IPadEpisodeSources(title:title.name + " · " + episode.label,type:title.type,contentID:episode.id,watchContext:IPadWatchContext(title:title,episode:episode)) } label: {
                            HStack(spacing:16) {
                                AsyncImage(url:episode.thumbnail) { image in image.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.06) }.frame(width:120,height:68).clipped().clipShape(RoundedRectangle(cornerRadius:10))
                                VStack(alignment:.leading,spacing:5) { Text(episode.label).font(.subheadline.weight(.medium));if let date=episode.released { Text(String(date.prefix(10))).font(.caption).foregroundStyle(.secondary) } }
                                Spacer()
                                if history.record(IPadWatchContext(title:title,episode:episode))?.completed == true { Image(systemName:"checkmark.circle.fill").foregroundStyle(.yellow).accessibilityLabel("Watched") }
                            }.padding(12).background(episodeID==episode.id ? Color.yellow.opacity(0.12) : .white.opacity(0.035),in:RoundedRectangle(cornerRadius:14))
                            }.buttonStyle(.plain).id(episode.id)
                            .contextMenu {
                                let context=IPadWatchContext(title:title,episode:episode)
                                let watched=history.record(context)?.completed == true
                                Button(watched ? "Mark as not watched" : "Mark as watched",systemImage:watched ? "circle" : "checkmark.circle") { history.mark(context,watched:!watched) }
                            }
                        }
                    }
                }
                if findingSources { ProgressView("Finding sources…") }
                if !streams.isEmpty {
                    Text("Choose a source under 2 GB. Recommendations balance recent transfer speed, stability, reported peers and file size. They improve as you watch.").font(.caption).foregroundStyle(.secondary)
                    Picker("Resolution",selection:$resolution) { ForEach(["All","4K","1080p","720p","SD","Unknown"],id:\.self) { Text($0).tag($0) } }.pickerStyle(.segmented)
                    LazyVStack(spacing:12) {
                    ForEach(streams.filter { resolution=="All" || $0.stream.resolution==resolution }) { source in
                        NavigationLink { IPadPlaybackView(stream:source.stream,title:title.name,context:IPadWatchContext(title:title)) } label: {
                            HStack(alignment:.top) { VStack(alignment:.leading,spacing:6) { Text(source.stream.name ?? source.addonName).font(.headline);if source.id==streams.first(where:{SourcePolicy.recommendable($0.stream,maxBytes:2*1024*1024*1024) && (resolution=="All" || $0.stream.resolution==resolution)})?.id { Label("Recommended",systemImage:"sparkles").font(.caption.weight(.semibold)).foregroundStyle(.yellow) };Text(source.stream.detail).font(.caption).foregroundStyle(.secondary).lineLimit(4) };Spacer();Image(systemName:"play.circle.fill").font(.title2).foregroundStyle(.yellow) }.padding(16).background(.white.opacity(0.04),in:RoundedRectangle(cornerRadius:14))
                        }.buttonStyle(.plain)
                    }
                    }
                }
            }.padding(24)
        }.navigationTitle(title.name).navigationBarTitleDisplayMode(.inline)
        .task {
            do { let loaded=try await AddonClient().metadata(found);try Task.checkCancellation();detail=loaded
                let latest=history.latest(titleID:loaded.id,type:loaded.type)
                season=latest?.context.season ?? loaded.videos?.compactMap(\.season).filter {$0>0}.min() ?? 1
                episodeID=latest?.context.contentID ?? ""; if loaded.type=="movie" { await loadSources(loaded.id) } }
            catch { if !Task.isCancelled { self.error=error.localizedDescription } }
        }
        .onChange(of:episodeID) { _,id in Task { @MainActor in await Task.yield();proxy.scrollTo(id,anchor:.top) } }
        .onChange(of:history.latest(titleID:title.id,type:title.type)?.context.contentID) { _,id in
            if let latest=history.latest(titleID:title.id,type:title.type),let id { season=latest.context.season ?? season;episodeID=id }
        }
        }
    }
    private func loadSources(_ id:String) async {
        let request=UUID();sourceRequest=request
        findingSources=true;streams=[];error=nil;defer { if sourceRequest==request { findingSources=false } }
        do {
            let foundSources=try await AddonStore.shared.readyStreams(type:found.title.type,id:id)
            try Task.checkCancellation();guard sourceRequest==request else { return };let ranked=await SourcePolicy.orderedAsync(foundSources.filter {$0.stream.playableSource != nil},profile:SourceExperience.shared.profile,duration:(detail ?? found.title).estimatedDuration,maxBytes:2*1024*1024*1024)
            try Task.checkCancellation();guard sourceRequest==request else {return};streams=ranked
            if streams.isEmpty { error="No playable sources found for this title." }
        } catch { if !Task.isCancelled && sourceRequest==request { self.error=error.localizedDescription } }
    }
}
struct IPadEpisodeSources:View {
    var title:String
    var type:String
    var contentID:String
    var watchContext:IPadWatchContext?=nil
    @ViewState<[ListedStream]> private var sources=[]
    @ViewState<Bool> private var busy=true
    @ViewState<String?> private var error:String?
    @ViewState<String> private var resolution="All"
    var body:some View {
        ScrollView {
            LazyVStack(alignment:.leading,spacing:18) {
                if busy { ProgressView("Finding sources…").frame(maxWidth:.infinity).padding(32) }
                if let error { Text(error).foregroundStyle(.secondary);Button("Try again") { Task { await load() } } }
                if !sources.isEmpty {
                    Text("Choose a source under 2 GB. Recommendations balance recent transfer speed, stability, reported peers and file size. They improve as you watch.").font(.caption).foregroundStyle(.secondary)
                    Picker("Resolution",selection:$resolution) { ForEach(["All","4K","1080p","720p","SD","Unknown"],id:\.self) { Text($0).tag($0) } }.pickerStyle(.segmented)
                    ForEach(sources.filter { resolution=="All" || $0.stream.resolution==resolution }) { source in
                        NavigationLink { IPadPlaybackView(stream:source.stream,title:title,context:watchContext) } label: {
                            HStack(alignment:.top) { VStack(alignment:.leading,spacing:6) { Text(source.stream.name ?? source.addonName).font(.headline);if source.id==sources.first(where:{SourcePolicy.recommendable($0.stream,maxBytes:2*1024*1024*1024) && (resolution=="All" || $0.stream.resolution==resolution)})?.id { Label("Recommended",systemImage:"sparkles").font(.caption.weight(.semibold)).foregroundStyle(.yellow) };Text(source.stream.detail).font(.caption).foregroundStyle(.secondary).lineLimit(5) };Spacer();Image(systemName:"play.circle.fill").font(.title2).foregroundStyle(.yellow) }.padding(16).background(.white.opacity(0.04),in:RoundedRectangle(cornerRadius:14))
                        }.buttonStyle(.plain)
                    }
                    if !sources.contains(where:{resolution=="All" || $0.stream.resolution==resolution}) { Text("No sources match this resolution.").foregroundStyle(.secondary) }
                }
            }.padding(24)
        }.navigationTitle(title).navigationBarTitleDisplayMode(.inline).task { await load() }
    }
    private func load() async {
        busy=true;error=nil;defer { busy=false }
        do {
            let result=try await AddonStore.shared.readyStreams(type:type,id:contentID)
            try Task.checkCancellation();let ranked=await SourcePolicy.orderedAsync(result.filter {$0.stream.playableSource != nil},profile:SourceExperience.shared.profile,duration:watchContext?.estimatedDuration ?? (type=="movie" ? 5400 : 2700),maxBytes:2*1024*1024*1024)
            try Task.checkCancellation();sources=ranked
            if sources.isEmpty { error="No playable sources were returned for this episode." }
            let report:[String:Any]=["id":contentID,"count":sources.count,"type":type]
            if let data=try? JSONSerialization.data(withJSONObject:report) { try? data.write(to:FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("episode-sources-result.json")) }
        } catch { if !Task.isCancelled { self.error=error.localizedDescription } }
    }
}

enum IPadSourceOrder {
    @MainActor static func sorted(_ sources:[ListedStream])->[ListedStream] {
        SourcePolicy.ordered(sources,profile:SourceExperience.shared.profile,duration:2700,maxBytes:2*1024*1024*1024)
    }
}

struct IPadContinueWatching:View {
    @ObservedObject private var addons=AddonStore.shared
    @ObservedObject private var history=IPadHistory.shared
    @ViewState<InstalledAddon?> private var catalog:InstalledAddon?
    @ViewState<FoundTitle?> private var info:FoundTitle?
    private var artworkKey:String { history.continuing.prefix(16).map(\.id).joined(separator:"|") }
    var body:some View {
        if !history.continuing.isEmpty {
            VStack(alignment:.leading,spacing:16) {
                Text("Continue watching").font(.title2.bold())
                ScrollView(.horizontal,showsIndicators:false) {
                    LazyHStack(alignment:.top,spacing:20) {
                        ForEach(history.continuing) { record in
                            ZStack(alignment:.bottomTrailing) {
                                if let stream=record.stream {
                                    NavigationLink {
                                        IPadPlaybackView(stream:stream,title:record.context.displayName,context:record.context)
                                    } label: { IPadContinueCard(record:record) }.buttonStyle(.plain)
                                }
                                Menu {
                                    if let catalog {
                                        Button("More info",systemImage:"info.circle") {
                                            info=FoundTitle(title:CatalogTitle(id:record.context.titleID,type:record.context.type,name:record.context.name,poster:record.context.poster),addon:catalog)
                                        }
                                    }
                                    Button("Remove from Continue Watching",systemImage:"xmark",role:.destructive) { history.hide(record) }
                                } label: {
                                    Image(systemName:"ellipsis").font(.title3.bold()).foregroundStyle(.white)
                                        .frame(width:44,height:44).contentShape(Rectangle())
                                }.padding(.trailing,8).padding(.bottom,4)
                                .accessibilityLabel("Options for \(record.context.name)")
                            }.frame(width:300)
                        }
                    }.padding(.bottom,6)
                }
            }
            .navigationDestination(isPresented:Binding(get:{info != nil},set:{if !$0 { info=nil }})) { if let info { IPadTitleView(found:info) } }
            .task(id:artworkKey+"|"+addons.addons.map(\.id).joined(separator:"|")) {
                let client=AddonClient()
                guard let addon=try? await addons.readyCatalog(),!Task.isCancelled else { catalog=nil;return }
                catalog=addon
                for record in history.continuing.prefix(16) where record.context.background==nil && record.context.thumbnail==nil {
                    let found=FoundTitle(title:CatalogTitle(id:record.context.titleID,type:record.context.type,name:record.context.name),addon:addon)
                    if let title=try? await client.metadata(found),!Task.isCancelled { history.setArtwork(title) }
                    if Task.isCancelled { return }
                }
            }
        }
    }
}
private struct IPadContinueCard:View {
    var record:IPadWatchRecord
    private var subtitle:String {
        let episode=record.context.season.flatMap { season in record.context.episode.map { "S\(season), E\($0)" } }
        let remaining=max(0,record.duration-record.position)
        let time=record.completed ? "Watched" : record.duration>0 ? "\(max(1,Int(ceil(remaining/60))))m left" : "Resume"
        return [episode,time].compactMap {$0}.joined(separator:" · ")
    }
    var body:some View {
        ZStack(alignment:.bottomLeading) {
            GeometryReader { geo in
                AsyncImage(url:record.context.thumbnail ?? record.context.background ?? record.context.poster) { image in
                    image.resizable().scaledToFill()
                } placeholder: { Color.white.opacity(0.06).overlay(Image(systemName:"film").font(.largeTitle).foregroundStyle(.secondary)) }
                .frame(width:geo.size.width,height:geo.size.height).clipped()
            }
            LinearGradient(colors:[.clear,.black.opacity(0.2),.black.opacity(0.92)],startPoint:.top,endPoint:.bottom)
            VStack { HStack { IPadHomeTypeTag(type:record.context.type);Spacer() };Spacer() }.padding(12)
            VStack(alignment:.leading,spacing:12) {
                Text(record.context.name).font(.headline).lineLimit(2).shadow(radius:4)
                HStack(spacing:9) {
                    Image(systemName:"play.fill").font(.caption)
                    GeometryReader { geo in
                        Capsule().fill(.white.opacity(0.3))
                        Capsule().fill(Color(red:0.96,green:0.77,blue:0.36))
                            .frame(width:geo.size.width * min(1,max(0,record.duration>0 ? record.position/record.duration : 0)))
                    }.frame(width:34,height:4)
                    Text(subtitle).font(.caption.weight(.medium)).lineLimit(1)
                    Spacer(minLength:40)
                }
            }.foregroundStyle(.white).padding(16)
        }.frame(height:188).clipShape(RoundedRectangle(cornerRadius:18))
            .overlay(RoundedRectangle(cornerRadius:18).strokeBorder(.white.opacity(0.14),lineWidth:1))
            .accessibilityElement(children:.ignore)
            .accessibilityLabel("Keep watching \(record.context.displayName), \(subtitle)")
    }
}

private struct IPadHomeShelf:Identifiable {
    var id:String
    var title:String
    var detail:String
    var titles:[FoundTitle]
}
struct IPadHomeView:View {
    @ObservedObject private var addons=AddonStore.shared
    @ObservedObject private var history=IPadHistory.shared
    @ViewState<[IPadHomeShelf]> private var shelves=[]
    @ViewState<[FoundTitle]> private var featured=[]
    @ViewState<Bool> private var busy=false
    @ViewState<String?> private var error:String?
    @ViewState<InstalledAddon?> private var catalog:InstalledAddon?
    private var recommendationKey:String {
        history.continuing.prefix(5).map { $0.context.type+":"+$0.context.titleID }.joined(separator:"|")
    }
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:32) {
                    if !featured.isEmpty { IPadFeaturedBanner(titles:featured) }
                    IPadContinueWatching()
                    if history.continuing.isEmpty {
                        Label("Your next watch starts here. Played titles will appear in Continue Watching.",systemImage:"play.rectangle")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if busy && shelves.isEmpty { ProgressView("Finding recommendations…") }
                    ForEach(shelves) { shelf in
                        VStack(alignment:.leading,spacing:16) {
                            VStack(alignment:.leading,spacing:6) {
                                Text(shelf.title).font(.title2.bold())
                                Text(shelf.detail).font(.subheadline).foregroundStyle(.secondary)
                            }
                            ScrollView(.horizontal,showsIndicators:false) {
                                LazyHStack(alignment:.top,spacing:20) {
                                    ForEach(shelf.titles) { found in
                                        NavigationLink { IPadTitleView(found:found) } label: {
                                            IPadPoster(name:found.title.name,url:found.title.poster,homeType:found.title.type).frame(width:170)
                                        }.buttonStyle(.plain)
                                    }
                                }.padding(.bottom,6)
                            }
                        }
                    }
                    if let error {
                        VStack(alignment:.leading,spacing:12) {
                            Text(error).foregroundStyle(.secondary)
                            Button("Try again") { Task { await load() } }.buttonStyle(.bordered)
                        }
                    }
                }.padding(24)
            }.navigationTitle("binge").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement:.topBarTrailing) { IPadSettingsButton() } }
            .task(id:recommendationKey+"|"+addons.addons.map(\.id).joined(separator:"|")) { await load() }
            .refreshable { await load() }
        }
    }
    @MainActor private func load() async {
        busy=true;error=nil
        defer { if !Task.isCancelled { busy=false } }
        do {
            let client=AddonClient()
            let addon:InstalledAddon
            addon=try await addons.readyCatalog()
            try Task.checkCancellation();catalog=addon
            // Enrich older history without resetting progress or last-watched dates.
            for record in history.continuing.prefix(5) where record.context.genres == nil {
                let context=record.context
                let found=FoundTitle(title:CatalogTitle(id:context.titleID,type:context.type,name:context.name,poster:context.poster),addon:addon)
                if let detail=try? await client.metadata(found) {
                    try Task.checkCancellation()
                    history.setGenres(detail.genres ?? [],titleID:context.titleID,type:context.type)
                }
                try Task.checkCancellation()
            }
            var scores:[String:Int]=[:]
            for (index,record) in history.continuing.prefix(5).enumerated() {
                for genre in record.context.genres ?? [] { scores[genre,default:0]+=5-index }
            }
            let preferred=scores.keys.sorted { scores[$0]==scores[$1] ? $0<$1 : scores[$0,default:0]>scores[$1,default:0] }.prefix(2)
            guard let movies=addon.manifest.catalogs?.first(where:{$0.type=="movie" && $0.id=="top"}),
                  let shows=addon.manifest.catalogs?.first(where:{$0.type=="series" && $0.id=="top"}) else { throw AddonError.data }
            async let popularMovies=client.browse(addon,catalog:movies)
            async let popularShows=client.browse(addon,catalog:shows)
            let (popularM,popularS)=try await (popularMovies,popularShows)
            try Task.checkCancellation()
            if featured.isEmpty {
                var candidates:[FoundTitle]=[]
                for index in 0..<3 {
                    if index<popularM.count { candidates.append(popularM[index]) }
                    if index<popularS.count { candidates.append(popularS[index]) }
                }
                let details=await withTaskGroup(of:(Int,FoundTitle).self) { group in
                    for (index,found) in candidates.enumerated() {
                        group.addTask {
                            let title=(try? await client.metadata(found)) ?? found.title
                            return (index,FoundTitle(title:title,addon:found.addon))
                        }
                    }
                    var results:[(Int,FoundTitle)]=[]
                    for await result in group { results.append(result) }
                    return results.sorted {$0.0<$1.0}.map { $0.1 }
                }
                try Task.checkCancellation();featured=details
            }
            let watched=Set(history.records.map {$0.context.type+":"+$0.context.titleID})
            var rows:[IPadHomeShelf]=[]
            for genre in preferred {
                async let movieTitles=client.recommendations(addon,catalog:movies,genre:genre)
                async let showTitles=client.recommendations(addon,catalog:shows,genre:genre)
                let matches=((try? await movieTitles) ?? [])+((try? await showTitles) ?? [])
                try Task.checkCancellation()
                var seen=Set<String>()
                // Interleave movies and shows instead of filling the shelf with only one type.
                let grouped=Dictionary(grouping:matches,by:{$0.title.type})
                let m=grouped["movie"] ?? [],s=grouped["series"] ?? []
                var mixed:[FoundTitle]=[]
                for index in 0..<max(m.count,s.count) {
                    if index<m.count { mixed.append(m[index]) }
                    if index<s.count { mixed.append(s[index]) }
                }
                let titles=Array(mixed.filter {
                    let key=$0.title.type+":"+$0.title.id
                    return !watched.contains(key) && seen.insert(key).inserted
                }.prefix(18))
                if !titles.isEmpty {
                    rows.append(IPadHomeShelf(id:genre,title:"More \(genre.lowercased()) for you",detail:"Based on your recent watches",titles:titles))
                }
            }
            if rows.isEmpty {
                let (m,s)=(popularM,popularS)
                try Task.checkCancellation()
                rows=[IPadHomeShelf(id:"movies",title:"Movies to try",detail:"Popular movies right now",titles:m.filter {!watched.contains($0.title.type+":"+$0.title.id)}),
                      IPadHomeShelf(id:"shows",title:"Shows to discover",detail:"Popular TV shows right now",titles:s.filter {!watched.contains($0.title.type+":"+$0.title.id)})].filter {!$0.titles.isEmpty}
            }
            shelves=rows
            if rows.isEmpty { error="No recommendations available right now. Explore has more titles to browse." }
        } catch is CancellationError { } catch {
            if !Task.isCancelled { self.error="Couldn’t load recommendations. "+error.localizedDescription }
        }
    }
}

private struct IPadTrailer:Identifiable {
    var id:String { url.absoluteString }
    var url:URL
}
private struct IPadHomeTypeTag:View {
    var type:String
    var body:some View {
        Text(type=="movie" ? "Movie" : "Series").font(.caption2.weight(.semibold))
            .foregroundStyle(.white).padding(.horizontal,9).padding(.vertical,5)
            .background(.black.opacity(0.65),in:Capsule())
    }
}
private struct IPadFeaturedBanner:View {
    var titles:[FoundTitle]
    @Environment(\.scenePhase) private var scenePhase
    // Duplicate end pages allow forward/backward swipes to wrap naturally.
    @ViewState<Int> private var selection=1
    @ViewState<Bool> private var visible=false
    @ViewState<Bool> private var appeared=false
    @ViewState<Bool> private var dragging=false
    @ViewState<IPadTrailer?> private var trailer:IPadTrailer?
    private var active:Bool { visible && appeared && scenePhase == .active && trailer==nil }
    private var timerKey:String { "\(selection)|\(active)|\(dragging)" }
    private var pageIndex:Int { (selection-1+titles.count)%max(1,titles.count) }
    var body:some View {
        GeometryReader { geo in
            VStack(spacing:12) {
                TabView(selection:$selection) {
                    ForEach(0..<(titles.count+2),id:\.self) { page in
                        let index=(page-1+titles.count)%titles.count
                        IPadFeaturedPage(found:titles[index]) { url in trailer=IPadTrailer(url:url) }.tag(page)
                    }
                }.tabViewStyle(.page(indexDisplayMode:.never))
                .simultaneousGesture(DragGesture(minimumDistance:15).onChanged { _ in dragging=true }.onEnded { _ in dragging=false })
                HStack(spacing:8) {
                    ForEach(titles.indices,id:\.self) { index in
                        Button { withAnimation(.easeInOut(duration:0.35)) { selection=index+1 } } label: {
                            Capsule().fill(index==pageIndex ? Color.white : Color.white.opacity(0.3)).frame(width:index==pageIndex ? 22 : 6,height:6)
                                .padding(.vertical,8)
                        }.buttonStyle(.plain).accessibilityLabel("Featured title \(index+1) of \(titles.count)")
                    }
                }
            }
        }.frame(height:450)
            .onGeometryChange(for:Bool.self) { proxy in
                let frame=proxy.frame(in:.global),intersection=frame.intersection(UIScreen.main.bounds)
                return frame.height>0 && !intersection.isNull && intersection.height/frame.height>0.65
            } action: { visible=$0 }
            .onAppear { appeared=true }
            .onDisappear { appeared=false;dragging=false }
            .task(id:timerKey) {
                guard active,!dragging,titles.count>1 else { return }
                do {
                    try await Task.sleep(for:.seconds(20))
                    try Task.checkCancellation()
                    withAnimation(.easeInOut(duration:0.35)) { selection+=1 }
                } catch { }
            }
            .task(id:selection) {
                guard selection==0 || selection==titles.count+1 else { return }
                do {
                    try await Task.sleep(for:.milliseconds(400));try Task.checkCancellation()
                    var transaction=Transaction();transaction.disablesAnimations=true
                    withTransaction(transaction) { selection=selection==0 ? titles.count : 1 }
                } catch { }
            }
            .sheet(item:$trailer) { IPadTrailerBrowser(url:$0.url).ignoresSafeArea() }
    }
}
private struct IPadFeaturedPage:View {
    var found:FoundTitle
    var playTrailer:(URL)->Void
    @EnvironmentObject private var library:IPadLibrary
    var body:some View {
        GeometryReader { geo in
            ZStack(alignment:.bottomLeading) {
                AsyncImage(url:found.title.background ?? found.title.poster) { image in
                    image.resizable().scaledToFit().mask(LinearGradient(stops:[.init(color:.clear,location:0),.init(color:.black,location:0.2),.init(color:.black,location:1)],startPoint:.leading,endPoint:.trailing))
                } placeholder: { Color.white.opacity(0.04) }
                .frame(width:geo.size.width,height:geo.size.height,alignment:.trailing).background(Color.black).clipped()
                LinearGradient(colors:[.black.opacity(0.8),.black.opacity(0.3),.clear],startPoint:.leading,endPoint:.trailing)
                LinearGradient(colors:[.clear,.black.opacity(0.92)],startPoint:.top,endPoint:.bottom)
                VStack(alignment:.leading,spacing:14) {
                    Text("POPULAR NOW").font(.caption.weight(.bold)).tracking(2).foregroundStyle(Color(red:0.96,green:0.77,blue:0.36))
                    Text(found.title.name).font(.largeTitle.bold()).lineLimit(2)
                    Text(([found.title.type=="movie" ? "Movie" : "Series"]+Array((found.title.genres ?? []).prefix(2))).joined(separator:" · "))
                        .font(.subheadline).foregroundStyle(.white.opacity(0.8))
                    if let description=found.title.description {
                        Text(description).font(.subheadline).foregroundStyle(.white.opacity(0.8)).lineLimit(3)
                    }
                    ViewThatFits(in:.horizontal) {
                        HStack(spacing:12) { actions }
                        VStack(alignment:.leading,spacing:10) { actions }
                    }.padding(.top,4)
                }.foregroundStyle(.white).frame(maxWidth:min(480,geo.size.width-48),alignment:.leading)
                    .padding(24)
            }.clipShape(RoundedRectangle(cornerRadius:24))
                .overlay(RoundedRectangle(cornerRadius:24).strokeBorder(.white.opacity(0.08),lineWidth:1))
        }
    }
    @ViewBuilder private var actions:some View {
        NavigationLink { IPadTitleView(found:found) } label: {
            Label("More info",systemImage:"info.circle").font(.subheadline.bold()).padding(.horizontal,6)
        }.buttonStyle(.borderedProminent).tint(Color(red:0.96,green:0.77,blue:0.36)).foregroundStyle(.black).buttonBorderShape(.capsule)
        if let url=found.title.trailerURL {
            Button { playTrailer(url) } label: { Label("Trailer",systemImage:"play.fill").font(.subheadline.bold()) }
                .buttonStyle(.bordered).tint(.white).buttonBorderShape(.capsule)
        }
        Button { library.toggle(found.title) } label: {
            Image(systemName:library.contains(found.title) ? "checkmark" : "plus").font(.headline).frame(width:20,height:20)
        }.buttonStyle(.bordered).tint(.white).buttonBorderShape(.circle)
            .accessibilityLabel(library.contains(found.title) ? "Remove from library" : "Plan to watch")
    }
}
private struct IPadTrailerBrowser:UIViewControllerRepresentable {
    var url:URL
    func makeUIViewController(context:Context)->SFSafariViewController {
        let controller=SFSafariViewController(url:url)
        controller.preferredControlTintColor=UIColor(red:0.96,green:0.77,blue:0.36,alpha:1)
        return controller
    }
    func updateUIViewController(_ controller:SFSafariViewController,context:Context) { }
}

