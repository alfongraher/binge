import Foundation
@main struct MacLibraryCheck {
    @MainActor static func main() throws {
        let root=URL(fileURLWithPath:"/private/tmp").appendingPathComponent("binge-mac-model-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let old=LibraryItem(title:"The Mentalist · S1 E1",source:"magnet:?xt=urn:btih:abcd",kind:"TV episode",stream:AddonStream(infoHash:String(repeating:"a",count:40),fileIdx:0),contentID:"tt1196946:1:1")
        var data=try JSONSerialization.jsonObject(with:JSONEncoder().encode([old])) as! [[String:Any]]
        for key in ["favourite","statusOverride","catalogueType","catalogueID"] { data[0].removeValue(forKey:key) }
        let file=root.appendingPathComponent("library.json");try JSONSerialization.data(withJSONObject:data).write(to:file)
        let library=LibraryStore(file:file)
        precondition(library.items.count==1 && library.items[0].titleID=="tt1196946" && library.items[0].type=="series")
        let show=CatalogTitle(id:"tt1196946",type:"series",name:"The Mentalist")
        library.addCatalog(show);library.toggleFavourite(show)
        precondition(library.items.count==1 && library.isFavourite(show) && library.items[0].stream?.fileIdx==0)
        let movie=CatalogTitle(id:"movie",type:"movie",name:"Movie")
        library.addCatalog(movie);precondition(library.contains(movie))
        library.toggleFavourite(movie)
        library.add(title:"Movie",source:"https://example.com/movie.mp4",kind:"Movie",stream:AddonStream(url:"https://example.com/movie.mp4"),contentID:"movie")
        precondition(library.items.filter {$0.titleID=="movie"}.count==1 && library.isFavourite(movie) && library.items.first {$0.titleID=="movie"}!.source != "")
        let history=WatchHistory(file:root.appendingPathComponent("history.json"))
        let selection=PlaybackSelection(title:"The Mentalist · S1 E1",stream:AddonStream(infoHash:String(repeating:"a",count:40)),contentID:"tt1196946:1:1",contentType:"series")
        history.record(selection,position:100,duration:100)
        precondition(library.status(library.items.first {$0.type=="series"}!,history:history.records)=="watching")
        history.record(PlaybackSelection(title:"Movie",stream:AddonStream(url:"https://example.com/movie.mp4"),contentID:"movie"),position:100,duration:100)
        precondition(history.continueWatching.count==2)
        let saved=library.items.first {$0.type=="series"}!
        library.setStatus("watched",for:saved);precondition(library.status(library.items.first {$0.id==saved.id}!,history:history.records)=="watched")
        library.setStatus(nil,for:saved);precondition(library.status(library.items.first {$0.id==saved.id}!,history:history.records)=="watching")
        let index=library.remove(saved)!;library.restore(saved,at:index);library.restore(saved,at:index)
        precondition(library.items.filter {$0.id==saved.id}.count==1)
        let restored=LibraryStore(file:file);precondition(restored.isFavourite(show) && restored.items.count==2)
        var detail=show;detail.background=URL(string:"https://example.com/background.jpg")
        detail.videos=[CatalogTitle.Episode(id:"tt1196946:1:1",thumbnail:URL(string:"https://example.com/episode.jpg"),season:1,episode:1)]
        history.setArtwork(detail);history.record(selection,position:90,duration:100)
        precondition(history.records.first {$0.contentID==selection.contentID}!.thumbnail==detail.videos![0].thumbnail)
        let oldRecord=history.records[0]
        history.dismiss(oldRecord)
        precondition(!history.continueWatching.contains {$0.id==oldRecord.id})
        print("PASS: legacy library and source retention, catalog deduplication, favourites persistence, movie/show status, reset, Undo, completed-title continuation, artwork retention, dismissal")
    }
}
