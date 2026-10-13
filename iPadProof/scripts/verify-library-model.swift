import Foundation

// Compile alongside Addons.swift, Subtitles.swift, IPadHistory.swift and IPadLibraryStore.swift.
@main struct LibraryModelCheck {
    @MainActor static func main() throws {
        let suite="binge.ipad.library.model.check"
        let defaults=UserDefaults(suiteName:suite)!
        defaults.removePersistentDomain(forName:suite)
        defer { defaults.removePersistentDomain(forName:suite) }
        let old="""
        [{"id":"movie-one","type":"movie","name":"Zulu"},{"id":"series-one","type":"series","name":"Alpha"}]
        """
        defaults.set(Data(old.utf8),forKey:"binge.ipad.savedTitles")
        let library=IPadLibrary(defaults:defaults)
        precondition(library.titles.count==2 && !library.titles[0].favourite)
        precondition(library.filtered(section:.all,type:"all",query:"",sort:.added,records:[]).map(\.id)==["movie-one","series-one"])
        let movie=library.titles[0].catalogTitle,show=library.titles[1].catalogTitle
        let stream=AddonStream(url:"https://example.com/video.mp4")
        var movieRecord=IPadWatchRecord(context:IPadWatchContext(title:movie),stream:stream,position:100,duration:1000,completed:false,hidden:false,updated:Date(timeIntervalSince1970:100))
        let episode=CatalogTitle.Episode(id:"series-one:1:1",season:1,episode:1)
        let showRecord=IPadWatchRecord(context:IPadWatchContext(title:show,episode:episode),stream:stream,position:1000,duration:1000,completed:true,hidden:false,updated:Date(timeIntervalSince1970:200))
        precondition(library.status(for:library.titles[0],records:[]) == .planned)
        precondition(library.status(for:library.titles[0],records:[movieRecord]) == .watching)
        movieRecord.completed=true
        let records=[movieRecord,showRecord]
        precondition(library.status(for:library.titles[0],records:records) == .watched)
        precondition(library.status(for:library.titles[1],records:records) == .watching)
        library.toggleFavourite(movie)
        precondition(library.filtered(section:.favourites,type:"all",query:"",sort:.added,records:records).map(\.id)==[movie.id])
        let extra=CatalogTitle(id:"extra",type:"movie",name:"Beta")
        library.toggleFavourite(extra);library.toggleFavourite(extra);library.toggleFavourite(extra)
        precondition(library.titles.filter {$0.id==extra.id}.count==1 && library.isFavourite(extra))
        library.setStatus(.watched,for:show)
        precondition(library.filtered(section:.watched,type:"series",query:" alp ",sort:.added,records:records).map(\.id)==[show.id])
        library.setStatus(.planned,for:movie)
        precondition(library.filtered(section:.planned,type:"movie",query:"Zulu",sort:.added,records:records).count==1)
        library.setStatus(nil,for:movie)
        precondition(library.status(for:library.titles.first {$0.id==movie.id}!,records:records) == .watched)
        precondition(library.filtered(section:.all,type:"all",query:"",sort:.alphabetical,records:records).map(\.name)==["Alpha","Beta","Zulu"])
        precondition(library.filtered(section:.all,type:"all",query:"",sort:.recentlyWatched,records:records).first!.id==show.id)
        let saved=library.titles.first {$0.id==show.id}!
        let index=library.remove(saved)!
        precondition(!library.contains(show))
        library.restore(saved,at:index);library.restore(saved,at:index)
        precondition(library.titles.filter {$0.id==show.id}.count==1)
        let restored=IPadLibrary(defaults:defaults)
        precondition(restored.isFavourite(extra) && restored.isFavourite(movie))
        precondition(restored.titles.first {$0.id==show.id}!.statusOverride == .watched)
        precondition(restored.titles.map(\.key)==library.titles.map(\.key))
        print("PASS: legacy saved titles and order; progress-derived movie/show states; favourites without duplicates; manual status/reset; search/type/section/sort; remove/undo; persistence")
    }
}
