import SwiftUI
import AVKit
import UniformTypeIdentifiers

struct LibraryView:View {
    @EnvironmentObject private var library:LibraryStore
    @EnvironmentObject private var history:WatchHistory
    @EnvironmentObject private var addons:AddonStore
    @Binding var query:String
    var explore:()->Void
    var openAddons:()->Void
    @AppStorage("binge.mac.library.section") private var section="all"
    @AppStorage("binge.mac.library.type") private var type="all"
    @AppStorage("binge.mac.library.sort") private var sort="added"
    @ViewState<Bool> private var showAdd=false
    @ViewState<Bool> private var importFile=false
    @ViewState<FoundTitle?> private var selected:FoundTitle?
    @ViewState<PlaybackSelection?> private var playback:PlaybackSelection?
    @ViewState<String?> private var message:String?
    @ViewState<LibraryItem?> private var removed:LibraryItem?
    @ViewState<AVPlayer?> private var localPlayer:AVPlayer?
    @ViewState<Int> private var removedIndex=0
    private let sections=[("all","All titles"),("planned","Plan to watch"),("favourites","Favourites"),("watching","Watching"),("watched","Watched")]
    private var visibleItems:[LibraryItem] {
        let indexed=library.items.enumerated().filter { _,item in
            (type=="all" || item.type==type) && (query.isEmpty || item.title.localizedStandardContains(query)) && matches(item,section)
        }
        return indexed.sorted { a,b in
            if sort=="title" { let order=a.element.title.localizedStandardCompare(b.element.title);return order == .orderedSame ? a.offset<b.offset : order == .orderedAscending }
            if sort=="watched" {
                let ad=latest(a.element)?.lastWatched ?? .distantPast,bd=latest(b.element)?.lastWatched ?? .distantPast
                return ad==bd ? a.offset<b.offset : ad>bd
            }
            return a.element.added==b.element.added ? a.offset<b.offset : a.element.added>b.element.added
        }.map(\.element)
    }
    var body:some View {
        Group {
            if let playback { PlaybackView(selection:playback,close:{self.playback=nil}) }
            else if let selected { DiscoverView(query:.constant(""),submission:0,home:false,initialTitle:selected,onBack:{self.selected=nil},openAddons:openAddons) }
            else {
                VStack(alignment:.leading,spacing:22) {
                    HStack {
                        Text("\(library.items.count) saved titles").foregroundStyle(.secondary)
                        Spacer()
                        Button("Explore titles",systemImage:"plus",action:explore).buttonStyle(.bordered)
                        Button("Open file",systemImage:"folder") { importFile=true }.buttonStyle(.bordered)
                        Button("Add source",systemImage:"link") { showAdd=true }.buttonStyle(.bordered)
                    }
                    HStack(spacing:10) {
                        ForEach(sections,id:\.0) { key,label in
                            Button { section=key } label: {
                                HStack(spacing:7) { if key=="favourites" { Image(systemName:"heart.fill") };Text(label);Text("\(library.items.filter { matches($0,key) }.count)").opacity(0.6) }
                                    .font(.system(size:12,weight:.medium)).padding(.horizontal,14).padding(.vertical,10)
                                    .foregroundStyle(section==key ? Color.black : .white).background(section==key ? DriftTheme.accent : .white.opacity(0.06),in:Capsule())
                            }.buttonStyle(.plain)
                        }
                        Spacer()
                    }
                    HStack {
                        Picker("Type",selection:$type) { Text("All types").tag("all");Text("Movies").tag("movie");Text("Series").tag("series");Text("Other videos").tag("video") }.pickerStyle(.segmented).frame(width:380)
                        Spacer()
                        Picker("Sort",selection:$sort) { Text("Recently added").tag("added");Text("Title A–Z").tag("title");Text("Recently watched").tag("watched") }.frame(width:230)
                    }
                    ScrollView {
                        if visibleItems.isEmpty {
                            DriftEmptyState(icon:section=="favourites" ? "heart" : "books.vertical",title:query.isEmpty ? emptyTitle : "No matching titles",detail:query.isEmpty ? emptyDetail : "Try a different search or filter.")
                            if !query.isEmpty || type != "all" { Button("Clear filters") { query="";type="all" }.buttonStyle(.bordered) }
                            else { Button("Explore titles",action:explore).buttonStyle(.borderedProminent) }
                        } else {
                            LazyVGrid(columns:[GridItem(.adaptive(minimum:150,maximum:190),spacing:24)],alignment:.leading,spacing:26) {
                                ForEach(visibleItems) { item in
                                    VStack(alignment:.leading,spacing:8) {
                                        ZStack(alignment:.topTrailing) {
                                            Button { showInfo(item) } label: { PosterCard(title:item.title,subtitle:"",url:item.poster) }.buttonStyle(.plain)
                                            Button { library.toggleFavourite(item) } label: { Image(systemName:item.favourite == true ? "heart.fill" : "heart").foregroundStyle(item.favourite == true ? DriftTheme.accent : .white).frame(width:30,height:30).background(.black.opacity(0.65),in:Circle()) }.buttonStyle(.plain).padding(8).help(item.favourite == true ? "Remove from favourites" : "Add to favourites")
                                        }
                                        HStack {
                                            Text(statusLabel(library.status(item,history:history.records))).font(.caption).foregroundStyle(.secondary)
                                            Spacer()
                                            Menu { actions(item) } label: { Image(systemName:"ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width:22)
                                        }
                                        if item.type=="series",let id=item.titleID {
                                            let count=history.records.filter {$0.titleID==id && $0.contentType==item.type && $0.complete}.count
                                            if count>0 { Text("\(count) episodes watched").font(.caption2).foregroundStyle(.secondary) }
                                        }
                                    }.contextMenu { actions(item) }
                                }
                            }.padding(.top,8)
                        }
                    }
                    if let removed {
                        HStack {
                            Text("Removed \(removed.title)").lineLimit(1);Spacer()
                            Button("Undo") { library.restore(removed,at:removedIndex);self.removed=nil }
                            Button { self.removed=nil } label: { Image(systemName:"xmark") }.buttonStyle(.plain)
                        }.padding(14).background(.regularMaterial,in:RoundedRectangle(cornerRadius:14))
                    }
                }.padding(32)
            }
        }.sheet(isPresented:$showAdd) { AddSourceView().environmentObject(library) }
            .sheet(isPresented:Binding(get:{localPlayer != nil},set:{if !$0 { localPlayer?.pause();localPlayer=nil }})) {
                VStack {
                    HStack { Spacer();Button("Close") { localPlayer?.pause();localPlayer=nil } }
                    if let localPlayer { NativePlayerView(player:localPlayer) }
                }.padding(20).frame(width:800,height:500)
            }
            .fileImporter(isPresented:$importFile,allowedContentTypes:[.movie,.video]) { result in
                do { let url=try result.get();library.add(title:url.deletingPathExtension().lastPathComponent,source:url.absoluteString,kind:"Video") }
                catch { message=error.localizedDescription }
            }
            .alert("binge",isPresented:Binding(get:{message != nil || library.error != nil},set:{if !$0 { message=nil;library.error=nil }})) { Button("OK") { message=nil;library.error=nil } } message: { Text(message ?? library.error ?? "") }
    }
    @ViewBuilder private func actions(_ item:LibraryItem)->some View {
        if item.catalogTitle != nil { Button("More info") { showInfo(item) } }
        if latest(item) != nil || !item.source.isEmpty { Button("Keep watching") { play(item) } }
        Button(item.favourite == true ? "Remove from favourites" : "Add to favourites") { library.toggleFavourite(item) }
        Divider()
        ForEach(["planned","watching","watched"],id:\.self) { status in Button(statusLabel(status)) { library.setStatus(status,for:item) } }
        if item.statusOverride != nil { Button("Use viewing progress") { library.setStatus(nil,for:item) } }
        Divider()
        Button("Remove from library",role:.destructive) { if let index=library.remove(item) { removedIndex=index;removed=item } }
    }
    private func matches(_ item:LibraryItem,_ section:String)->Bool { section=="all" || (section=="favourites" ? item.favourite == true : library.status(item,history:history.records)==section) }
    private func statusLabel(_ status:String)->String { status=="watching" ? "Watching" : status=="watched" ? "Watched" : "Plan to watch" }
    private var emptyTitle:String { section=="favourites" ? "Your favourites belong here" : section=="planned" ? "Nothing planned yet" : section=="watching" ? "No saved titles in progress" : section=="watched" ? "No watched titles yet" : "Build your library" }
    private var emptyDetail:String { section=="favourites" ? "Tap the heart on a title to keep your favourites together." : "Save movies and shows from Explore, or add your own video." }
    private func latest(_ item:LibraryItem)->WatchRecord? { history.records.filter {$0.contentType==item.type && $0.titleID==item.titleID && $0.stream.playableSource != nil}.max {$0.lastWatched<$1.lastWatched} }
    private func showInfo(_ item:LibraryItem) {
        guard let title=item.catalogTitle else { play(item);return }
        guard let addon=addons.addons.first(where:{$0.manifest.supports("meta",type:title.type,id:title.id)}) else { message="Connect a catalog in Add-ons to see title information.";return }
        selected=FoundTitle(title:title,addon:addon)
    }
    private func play(_ item:LibraryItem) {
        if let url=URL(string:item.source),url.isFileURL { localPlayer=AVPlayer(url:url);localPlayer?.play();return }
        if let record=latest(item) { playback=PlaybackSelection(title:record.title,stream:record.stream,poster:record.poster,contentID:record.contentID,contentType:record.contentType,genres:record.genres,resumePosition:record.position);return }
        if let stream=item.stream { playback=PlaybackSelection(title:item.title,stream:stream,poster:item.poster,contentID:item.contentID,contentType:item.type);return }
        guard !item.source.isEmpty else { showInfo(item);return }
        let stream=item.source.hasPrefix("magnet:") ? AddonStream(infoHash:URLComponents(string:item.source)?.queryItems?.first(where:{$0.name=="xt"})?.value?.components(separatedBy:":").last) : AddonStream(url:item.source)
        playback=PlaybackSelection(title:item.title,stream:stream,poster:item.poster,contentID:item.contentID,contentType:item.type)
    }
}
