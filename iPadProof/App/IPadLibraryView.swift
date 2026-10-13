import SwiftUI

private struct IPadLibraryRemoval {
    var item:IPadSavedTitle
    var index:Int
}
struct IPadSavedView:View {
    var explore:()->Void
    @EnvironmentObject private var library:IPadLibrary
    @ObservedObject private var addons=AddonStore.shared
    @ObservedObject private var history=IPadHistory.shared
    @AppStorage("binge.ipad.library.section") private var section="all"
    @AppStorage("binge.ipad.library.type") private var type="all"
    @AppStorage("binge.ipad.library.sort") private var sort="added"
    @State private var query=""
    @State private var catalog:InstalledAddon?
    @State private var error:String?
    @State private var loading=false
    @State private var removed:IPadLibraryRemoval?
    @State private var resume:IPadWatchRecord?
    private var selectedSection:IPadLibrarySection { IPadLibrarySection(rawValue:section) ?? .all }
    private var selectedSort:IPadLibrarySort { IPadLibrarySort(rawValue:sort) ?? .added }
    private var items:[IPadSavedTitle] { library.filtered(section:selectedSection,type:type,query:query,sort:selectedSort,records:history.records) }
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:24) {
                    HStack {
                        Text("\(library.titles.count) saved \(library.titles.count==1 ? "title" : "titles")").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Button("Explore titles",systemImage:"plus",action:explore).buttonStyle(.bordered).buttonBorderShape(.capsule)
                    }
                    ScrollView(.horizontal,showsIndicators:false) {
                        HStack(spacing:10) {
                            ForEach(IPadLibrarySection.allCases,id:\.self) { item in
                                Button { section=item.rawValue } label: {
                                    HStack(spacing:7) {
                                        if item == .favourites { Image(systemName:"heart.fill") }
                                        Text(item.label)
                                        Text("\(count(item))").foregroundStyle(item==selectedSection ? .black.opacity(0.6) : .white.opacity(0.45))
                                    }.font(.subheadline.weight(.medium)).padding(.horizontal,16).padding(.vertical,11)
                                        .foregroundStyle(item==selectedSection ? .black : .white)
                                        .background(item==selectedSection ? Color(red:0.96,green:0.77,blue:0.36) : .white.opacity(0.06),in:Capsule())
                                }.buttonStyle(.plain).accessibilityAddTraits(item==selectedSection ? .isSelected : [])
                            }
                        }
                    }
                    ViewThatFits(in:.horizontal) {
                        HStack(spacing:20) { filters }
                        VStack(alignment:.leading,spacing:14) { filters }
                    }
                    if let error {
                        VStack(alignment:.leading,spacing:10) {
                            Text("Title information is temporarily unavailable. Your saved library is still here.").foregroundStyle(.secondary)
                            Button("Try again") { Task { await loadCatalog() } }.buttonStyle(.bordered)
                            Text(error).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if loading && catalog==nil { ProgressView("Loading title information…") }
                    if items.isEmpty { emptyState }
                    else {
                        LazyVGrid(columns:[GridItem(.adaptive(minimum:145,maximum:200),spacing:20)],alignment:.leading,spacing:26) {
                            ForEach(items,id:\.key) { item in card(item) }
                        }
                    }
                }.padding(24)
            }.navigationTitle("Library").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement:.topBarTrailing) { IPadSettingsButton() } }
                .searchable(text:$query,prompt:"Search your library")
                .task(id:addons.addons.map(\.id).joined(separator:"|")) { catalog=nil;await loadCatalog() }
                .navigationDestination(isPresented:Binding(get:{resume != nil},set:{if !$0 { resume=nil }})) {
                    if let record=resume,let stream=record.stream { IPadPlaybackView(stream:stream,title:record.context.displayName,context:record.context) }
                }
                .safeAreaInset(edge:.bottom) {
                    if let removed {
                        HStack(spacing:16) {
                            Text("Removed \(removed.item.name)").font(.subheadline).lineLimit(1)
                            Spacer()
                            Button("Undo") { library.restore(removed.item,at:removed.index);self.removed=nil }.font(.subheadline.bold())
                            Button { self.removed=nil } label: { Image(systemName:"xmark") }.accessibilityLabel("Dismiss undo")
                        }.padding(16).background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:16)).padding(.horizontal,24).padding(.bottom,12)
                    }
                }
        }
    }
    @ViewBuilder private var filters:some View {
        Picker("Type",selection:$type) {
            Text("All types").tag("all");Text("Movies").tag("movie");Text("Series").tag("series")
        }.pickerStyle(.segmented).frame(maxWidth:340)
        Menu {
            Picker("Sort",selection:$sort) { ForEach(IPadLibrarySort.allCases,id:\.self) { Text($0.label).tag($0.rawValue) } }
        } label: { Label(selectedSort.label,systemImage:"arrow.up.arrow.down").font(.subheadline) }
    }
    @ViewBuilder private func card(_ item:IPadSavedTitle)->some View {
        let status=library.status(for:item,records:history.records)
        VStack(alignment:.leading,spacing:7) {
            ZStack(alignment:.topTrailing) {
                if let catalog {
                    NavigationLink { IPadTitleView(found:FoundTitle(title:item.catalogTitle,addon:catalog)) } label: {
                        IPadPoster(name:item.name,url:item.poster)
                    }.buttonStyle(.plain)
                } else { IPadPoster(name:item.name,url:item.poster) }
                Button { library.toggleFavourite(item.catalogTitle) } label: {
                    Image(systemName:item.favourite ? "heart.fill" : "heart").font(.subheadline.bold())
                        .foregroundStyle(item.favourite ? Color(red:0.96,green:0.77,blue:0.36) : .white)
                        .frame(width:36,height:36).background(.black.opacity(0.65),in:Circle())
                }.buttonStyle(.plain).padding(8).accessibilityLabel(item.favourite ? "Remove \(item.name) from favourites" : "Add \(item.name) to favourites")
            }
            HStack(spacing:6) {
                Label(status.label,systemImage:status.icon).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength:0)
                Menu { actions(item) } label: {
                    Image(systemName:"ellipsis").font(.subheadline.bold()).frame(width:32,height:28).contentShape(Rectangle())
                }.accessibilityLabel("Options for \(item.name)")
            }
            if item.type=="series" {
                let watched=history.records.filter {$0.context.titleID==item.id && $0.context.type==item.type && $0.completed}.count
                if watched>0 { Text("\(watched) \(watched==1 ? "episode" : "episodes") watched").font(.caption2).foregroundStyle(.secondary) }
            }
        }.contextMenu { actions(item) }
    }
    @ViewBuilder private func actions(_ item:IPadSavedTitle)->some View {
        Button(item.favourite ? "Remove from favourites" : "Add to favourites",systemImage:item.favourite ? "heart.slash" : "heart") { library.toggleFavourite(item.catalogTitle) }
        if let record=history.latest(titleID:item.id,type:item.type),record.stream != nil {
            Button("Keep watching",systemImage:"play.fill") { resume=record }
        }
        Section("Move to") {
            ForEach(IPadLibraryStatus.allCases,id:\.self) { status in
                Button(status.label,systemImage:status.icon) { library.setStatus(status,for:item.catalogTitle) }
            }
            if item.statusOverride != nil {
                Button("Use viewing progress",systemImage:"arrow.clockwise") { library.setStatus(nil,for:item.catalogTitle) }
            }
        }
        Button("Remove from library",systemImage:"trash",role:.destructive) {
            if let index=library.remove(item) { removed=IPadLibraryRemoval(item:item,index:index) }
        }
    }
    @ViewBuilder private var emptyState:some View {
        VStack(spacing:16) {
            if !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || type != "all" {
                ContentUnavailableView("No matching titles",systemImage:"magnifyingglass",description:Text("Try a different search or type filter."))
                Button("Clear filters") { query="";type="all" }.buttonStyle(.bordered)
            } else {
                ContentUnavailableView(emptyTitle,systemImage:selectedSection == .favourites ? "heart" : "books.vertical",description:Text(emptyDetail))
                if selectedSection == .all || selectedSection == .planned { Button("Explore titles",action:explore).buttonStyle(.borderedProminent).foregroundStyle(.black) }
                else { Button("See all titles") { section="all" }.buttonStyle(.bordered) }
            }
        }.frame(maxWidth:.infinity).padding(.vertical,20)
    }
    private var emptyTitle:String {
        switch selectedSection {
        case .all:"Build your library"
        case .planned:"Nothing planned yet"
        case .favourites:"Your favourites belong here"
        case .watching:"No saved titles in progress"
        case .watched:"No watched titles yet"
        }
    }
    private var emptyDetail:String {
        switch selectedSection {
        case .all,.planned:"Save movies and shows from Explore for your next watch."
        case .favourites:"Tap the heart on a title to keep your favourites together."
        case .watching:"Saved titles appear here when you start watching."
        case .watched:"Finished saved movies appear here automatically. You can also move a movie or a whole show to Watched."
        }
    }
    private func count(_ section:IPadLibrarySection)->Int {
        library.filtered(section:section,type:"all",query:"",sort:.added,records:history.records).count
    }
    @MainActor private func loadCatalog() async {
        guard catalog==nil,!loading else { return }
        loading=true;error=nil;defer { loading=false }
        do {
            let loaded=try await addons.readyCatalog()
            try Task.checkCancellation();catalog=loaded
        } catch is CancellationError { } catch { self.error=error.localizedDescription }
    }
}
