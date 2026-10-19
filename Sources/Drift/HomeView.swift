import SwiftUI

struct HomeTypeTag:View {
    var type:String
    var body:some View { Text(type=="movie" ? "Movie" : "Series").font(.system(size:10,weight:.semibold)).foregroundStyle(.white).padding(.horizontal,9).padding(.vertical,5).background(.black.opacity(0.65),in:Capsule()) }
}
struct HomeView:View {
    @EnvironmentObject private var history:WatchHistory
    @EnvironmentObject private var addons:AddonStore
    @ViewState<PlaybackSelection?> private var playback:PlaybackSelection?
    @ViewState<FoundTitle?> private var selected:FoundTitle?
    @ViewState<String?> private var requestedEpisode:String?
    @ViewState<[FoundTitle]> private var featured=[]
    @ViewState<[FoundTitle]> private var recommendations=[]
    @ViewState<String> private var reason=""
    @ViewState<Bool> private var loading=false
    @ViewState<String?> private var message:String?
    var discover:()->Void
    var openAddons:()->Void
    private var historyKey:String { history.continueWatching.prefix(5).map(\.id).joined(separator:"|") }
    var body:some View {
        Group {
            if let playback {
                PlaybackView(selection:playback,close:{self.playback=nil},selectEpisode:{ episode in
                    if let id=EpisodePlayback.seriesID(playback.contentID),let addon=addons.addons.first(where:{$0.manifest.supports("meta",type:"series",id:id)}) {
                        requestedEpisode=episode.id
                        selected=FoundTitle(title:CatalogTitle(id:id,type:"series",name:playback.seriesTitle ?? playback.title.components(separatedBy:" · ")[0],poster:playback.poster),addon:addon)
                        self.playback=nil
                    }
                })
            } else if let selected {
                DiscoverView(query:.constant(""),submission:0,home:false,initialEpisodeID:requestedEpisode,initialTitle:selected,onBack:{self.selected=nil},openAddons:openAddons)
            } else {
                ScrollView {
                    VStack(alignment:.leading,spacing:32) {
                        if !featured.isEmpty { HomeFeaturedBanner(titles:featured,select:{requestedEpisode=nil;selected=$0}) }
                        if let error=history.error { Text(error).font(.caption).foregroundStyle(.orange) }
                        if !history.continueWatching.isEmpty {
                            Text("Continue watching").font(.title2.weight(.semibold))
                            ScrollView(.horizontal,showsIndicators:false) {
                                LazyHStack(spacing:20) {
                                    ForEach(history.continueWatching.prefix(16)) { record in
                                        ContinueWatchingCard(record:record,resume:{
                                            playback=PlaybackSelection(title:record.title,stream:record.stream,poster:record.poster,contentID:record.contentID,contentType:record.contentType,genres:record.genres,resumePosition:record.position)
                                        },info:{showInfo(record)},dismiss:{history.dismiss(record)})
                                    }
                                }
                            }
                        } else { Button("Explore movies and shows",action:discover).buttonStyle(.bordered) }
                        if loading && recommendations.isEmpty { ProgressView("Finding recommendations…") }
                        if !recommendations.isEmpty {
                            VStack(alignment:.leading,spacing:16) {
                                Text("Recommended for you").font(.title2.weight(.semibold))
                                Text(reason).font(.subheadline).foregroundStyle(.secondary)
                                ScrollView(.horizontal,showsIndicators:false) {
                                    LazyHStack(alignment:.top,spacing:22) {
                                        ForEach(recommendations) { found in
                                            Button { requestedEpisode=nil;selected=found } label: {
                                                PosterCard(title:found.title.name,subtitle:"",url:found.title.poster,homeType:found.title.type).frame(width:155)
                                            }.buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                        }
                        if let message { Text(message).foregroundStyle(.secondary);Button("Try again") { Task { await recommend() } }.buttonStyle(.bordered) }
                    }.padding(32)
                }.coordinateSpace(name:"homeScroll").task(id:historyKey) { await recommend() }
            }
        }
    }
    private func showInfo(_ record:WatchRecord) {
        guard let id=record.titleID,let addon=addons.addons.first(where:{$0.manifest.supports("meta",type:record.contentType,id:id)}) else { message="Connect a catalog in Add-ons to see title information.";return }
        requestedEpisode=nil;selected=FoundTitle(title:CatalogTitle(id:id,type:record.contentType,name:record.title.components(separatedBy:" · ")[0],poster:record.poster),addon:addon)
    }
    private func recommend() async {
        loading=true;message=nil;defer { if !Task.isCancelled { loading=false } }
        if addons.addons.isEmpty { await addons.install("https://v3-cinemeta.strem.io/manifest.json") }
        let client=AddonClient()
        guard let addon=addons.addons.first(where:{($0.manifest.catalogs ?? []).contains {$0.id=="top" && $0.type=="movie"}}),
              let movies=addon.manifest.catalogs?.first(where:{$0.id=="top" && $0.type=="movie"}),
              let shows=addon.manifest.catalogs?.first(where:{$0.id=="top" && $0.type=="series"}) else { message="Connect Cinemeta in Add-ons for popular titles and recommendations.";return }
        do {
            async let m=client.browse(addon,catalog:movies)
            async let s=client.browse(addon,catalog:shows)
            let (popularM,popularS)=try await (m,s);try Task.checkCancellation()
            if featured.isEmpty {
                var candidates:[FoundTitle]=[]
                for index in 0..<3 { if index<popularM.count { candidates.append(popularM[index]) };if index<popularS.count { candidates.append(popularS[index]) } }
                let details=await withTaskGroup(of:(Int,FoundTitle).self) { group in
                    for (index,found) in candidates.enumerated() { group.addTask { (index,FoundTitle(title:(try? await client.metadata(found)) ?? found.title,addon:found.addon)) } }
                    var result:[(Int,FoundTitle)]=[];for await row in group { result.append(row) };return result.sorted {$0.0<$1.0}.map {$0.1}
                }
                try Task.checkCancellation();featured=details
            }
            for record in history.continueWatching.prefix(16) where record.background==nil || record.genres.isEmpty {
                guard let id=record.titleID else { continue }
                if let detail=try? await client.metadata(FoundTitle(title:CatalogTitle(id:id,type:record.contentType,name:record.title),addon:addon)) {
                    try Task.checkCancellation();history.setArtwork(detail);history.setGenres(detail.genres ?? [],for:record.id)
                }
                try Task.checkCancellation()
            }
            var matches:[FoundTitle]=[]
            let preferred=history.preferredGenres
            for genre in preferred {
                async let m=client.recommendations(addon,catalog:movies,genre:genre)
                async let s=client.recommendations(addon,catalog:shows,genre:genre)
                let a=(try? await m) ?? [],b=(try? await s) ?? []
                for index in 0..<max(a.count,b.count) { if index<a.count { matches.append(a[index]) };if index<b.count { matches.append(b[index]) } }
                try Task.checkCancellation()
            }
            reason=preferred.isEmpty ? "Popular movies and shows" : "Based on your recent "+preferred.joined(separator:" and ").lowercased()+" watches"
            if matches.isEmpty {
                reason="Popular movies and shows"
                for index in 0..<max(popularM.count,popularS.count) { if index<popularM.count { matches.append(popularM[index]) };if index<popularS.count { matches.append(popularS[index]) } }
            }
            let watched=Set(history.records.compactMap { $0.titleID.map {$0} })
            var seen=Set<String>();recommendations=Array(matches.filter {!watched.contains($0.title.id) && seen.insert($0.id).inserted}.prefix(24))
        } catch is CancellationError { } catch { if !Task.isCancelled { message="Couldn’t load recommendations. Try again." } }
    }
}
private struct ContinueWatchingCard:View {
    var record:WatchRecord
    var resume:()->Void
    var info:()->Void
    var dismiss:()->Void
    @ViewState<Bool> private var hovering=false
    private var name:String { record.title.components(separatedBy:" · ")[0] }
    private var subtitle:String {
        let parts=record.contentID?.split(separator:":") ?? []
        let episode=parts.count>=3 && record.contentType != "movie" ? "S\(parts[parts.count-2]), E\(parts.last!)" : nil
        let time=record.complete ? "Watched" : record.duration>0 ? "\(max(1,Int(ceil(max(0,record.duration-record.position)/60))))m left" : "Resume"
        return [episode,time].compactMap {$0}.joined(separator:" · ")
    }
    var body:some View {
        ZStack(alignment:.bottomTrailing) {
            Button(action:resume) {
                ZStack(alignment:.bottomLeading) {
                    AsyncImage(url:record.thumbnail ?? record.background ?? record.poster) { image in image.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.06) }
                        .frame(width:300,height:188).clipped()
                    LinearGradient(colors:[.clear,.black.opacity(0.2),.black.opacity(0.92)],startPoint:.top,endPoint:.bottom)
                    VStack(alignment:.leading,spacing:12) {
                        Text(name).font(.headline).lineLimit(2)
                        HStack(spacing:9) {
                            Image(systemName:"play.fill").font(.caption)
                            GeometryReader { geo in
                                Capsule().fill(.white.opacity(0.3));Capsule().fill(DriftTheme.accent).frame(width:geo.size.width*record.fraction)
                            }.frame(width:34,height:4)
                            Text(subtitle).font(.caption).lineLimit(1);Spacer(minLength:40)
                        }
                    }.foregroundStyle(.white).padding(16)
                    VStack { HStack { HomeTypeTag(type:record.contentType);Spacer() };Spacer() }.padding(12)
                }.frame(width:300,height:188).clipShape(RoundedRectangle(cornerRadius:18))
            }.buttonStyle(.plain)
            Menu { Button("Keep watching",action:resume);Button("More info",action:info);Button("Remove from Continue Watching",role:.destructive,action:dismiss) } label: { Image(systemName:"ellipsis").font(.headline).frame(width:34,height:32) }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width:34).padding(12)
            if hovering { VStack { HStack { Spacer();Button(action:dismiss) { Image(systemName:"xmark").font(.caption.bold()).frame(width:26,height:26).background(.black.opacity(0.65),in:Circle()) }.buttonStyle(.plain).help("Remove from Continue Watching") };Spacer() }.padding(10) }
        }.frame(width:300,height:188).overlay(RoundedRectangle(cornerRadius:18).strokeBorder(.white.opacity(hovering ? 0.3 : 0.12),lineWidth:1)).onHover { hovering=$0 }
            .contextMenu { Button("Keep watching",action:resume);Button("More info",action:info);Button("Remove from Continue Watching",role:.destructive,action:dismiss) }
    }
}
private struct HomeFeaturedBanner:View {
    var titles:[FoundTitle]
    var select:(FoundTitle)->Void
    @EnvironmentObject private var library:LibraryStore
    @Environment(\.scenePhase) private var scenePhase
    @ViewState<Int> private var index=0
    @ViewState<Bool> private var appeared=false
    @ViewState<Bool> private var visible=true
    @ViewState<Bool> private var hovering=false
    private var timerKey:String { "\(index)|\(appeared)|\(visible)|\(hovering)|\(scenePhase)" }
    var body:some View {
        VStack(spacing:12) {
            let found=titles[index]
            GeometryReader { geo in
                ZStack(alignment:.bottomLeading) {
                    AsyncImage(url:found.title.background ?? found.title.poster) { image in image.resizable().scaledToFit().mask(LinearGradient(stops:[.init(color:.clear,location:0),.init(color:.black,location:0.2),.init(color:.black,location:1)],startPoint:.leading,endPoint:.trailing)) } placeholder: { Color.white.opacity(0.04) }.frame(width:geo.size.width,height:geo.size.height,alignment:.trailing).background(.black).clipped()
                    LinearGradient(colors:[.black.opacity(0.8),.black.opacity(0.3),.clear],startPoint:.leading,endPoint:.trailing)
                    LinearGradient(colors:[.clear,.black.opacity(0.92)],startPoint:.top,endPoint:.bottom)
                    VStack(alignment:.leading,spacing:14) {
                        Text("POPULAR NOW").font(.caption.weight(.bold)).tracking(2).foregroundStyle(DriftTheme.accent)
                        Text(found.title.name).font(.system(size:34,weight:.semibold,design:.rounded)).lineLimit(2)
                        Text(([found.title.type=="movie" ? "Movie" : "Series"]+Array((found.title.genres ?? []).prefix(2))).joined(separator:" · ")).foregroundStyle(.secondary)
                        if let detail=found.title.description { Text(detail).lineLimit(3).foregroundStyle(.white.opacity(0.8)) }
                        HStack(spacing:12) {
                            Button { select(found) } label: { Label("More info",systemImage:"info.circle").font(.system(size:13,weight:.semibold)).padding(.horizontal,18).padding(.vertical,11).background(DriftTheme.accent,in:Capsule()).foregroundStyle(.black) }.buttonStyle(.plain)
                            if let url=found.title.trailerURL { Button { NSWorkspace.shared.open(url) } label: { Label("Trailer",systemImage:"play.fill").font(.system(size:13,weight:.semibold)).padding(.horizontal,18).padding(.vertical,11).background(.regularMaterial,in:Capsule()) }.buttonStyle(.plain) }
                            Button { library.addCatalog(found.title) } label: { Image(systemName:library.contains(found.title) ? "checkmark" : "plus") }.buttonStyle(.bordered).disabled(library.contains(found.title)).help("Plan to watch")
                        }
                    }.frame(maxWidth:480,alignment:.leading).padding(28)
                }.clipShape(RoundedRectangle(cornerRadius:24)).id(found.id).transition(.opacity)
            }.frame(height:400)
            HStack(spacing:10) {
                Button { advance(-1) } label: { Image(systemName:"chevron.left") }.buttonStyle(.plain).help("Previous featured title")
                ForEach(titles.indices,id:\.self) { page in Button { withAnimation { index=page } } label: { Capsule().fill(page==index ? Color.white : .white.opacity(0.3)).frame(width:page==index ? 22 : 6,height:6) }.buttonStyle(.plain).help("Featured title \(page+1)") }
                Button { advance(1) } label: { Image(systemName:"chevron.right") }.buttonStyle(.plain).help("Next featured title")
            }.frame(height:20)
        }.onHover { hovering=$0 }.onAppear { appeared=true }.onDisappear { appeared=false }
            .onGeometryChange(for:Bool.self) { $0.frame(in:.named("homeScroll")).maxY>0 } action: { visible=$0 }
            .task(id:timerKey) {
                guard appeared,visible,!hovering,scenePhase == .active,titles.count>1 else { return }
                do { try await Task.sleep(for:.seconds(20));try Task.checkCancellation();advance(1) } catch { }
            }
    }
    private func advance(_ direction:Int) { withAnimation(.easeInOut(duration:0.35)) { index=(index+direction+titles.count)%titles.count } }
}
