import Foundation
import Combine

struct LibraryItem:Identifiable,Codable {
    var id=UUID()
    var title:String
    var source:String
    var kind:String
    var watched=false
    var added=Date()
    var stream:AddonStream?
    var contentID:String?
    var poster:URL?
    var favourite:Bool?
    var statusOverride:String?
    var catalogueType:String?
    var catalogueID:String?
    var type:String { catalogueType ?? (kind=="Movie" ? "movie" : ["TV episode","Series"].contains(kind) ? "series" : "video") }
    var titleID:String? {
        if let catalogueID { return catalogueID }
        guard let contentID else { return nil }
        let parts=contentID.split(separator:":")
        return type=="series" && parts.count>=3 ? parts.dropLast(2).joined(separator:":") : contentID
    }
    var catalogTitle:CatalogTitle? {
        guard let titleID else { return nil }
        return CatalogTitle(id:titleID,type:type,name:title.components(separatedBy:" · ").first ?? title,poster:poster)
    }
}
@MainActor final class LibraryStore:ObservableObject {
    @Published private(set) var items:[LibraryItem]=[]
    @Published var error:String?
    private let file:URL
    init(file:URL?=nil) {
        self.file=file ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Drift/library.json")
        do {
            try FileManager.default.createDirectory(at:self.file.deletingLastPathComponent(),withIntermediateDirectories:true)
            if FileManager.default.fileExists(atPath:self.file.path) { items=try JSONDecoder().decode([LibraryItem].self,from:Data(contentsOf:self.file)) }
        } catch { self.error="Could not load library: \(error.localizedDescription)" }
    }
    func add(title:String,source:String,kind:String,poster:URL?=nil,stream:AddonStream?=nil,contentID:String?=nil) {
        guard !items.contains(where:{$0.source==source && $0.stream?.fileIdx==stream?.fileIdx && $0.contentID==contentID}) else { return }
        let candidate=LibraryItem(title:title,source:source,kind:kind,stream:stream,contentID:contentID,poster:poster)
        if let titleID=candidate.titleID,let index=items.firstIndex(where:{$0.source.isEmpty && $0.titleID==titleID && $0.type==candidate.type}) {
            items[index].source=source;items[index].stream=stream;items[index].contentID=contentID
            if items[index].poster==nil { items[index].poster=poster }
        } else { items.insert(candidate,at:0) }
        save()
    }
    func contains(_ title:CatalogTitle)->Bool { items.contains {$0.titleID==title.id && $0.type==title.type} }
    func isFavourite(_ title:CatalogTitle)->Bool { items.first {$0.titleID==title.id && $0.type==title.type}?.favourite == true }
    func addCatalog(_ title:CatalogTitle) {
        guard !contains(title) else { return }
        items.insert(LibraryItem(title:title.name,source:"",kind:title.type=="movie" ? "Movie" : "Series",contentID:title.id,poster:title.poster,catalogueType:title.type,catalogueID:title.id),at:0);save()
    }
    func toggleFavourite(_ title:CatalogTitle) {
        addCatalog(title)
        guard let index=items.firstIndex(where:{$0.titleID==title.id && $0.type==title.type}) else { return }
        items[index].favourite = !(items[index].favourite ?? false);save()
    }
    func toggleFavourite(_ item:LibraryItem) { guard let index=items.firstIndex(where:{$0.id==item.id}) else { return };items[index].favourite = !(items[index].favourite ?? false);save() }
    func setStatus(_ status:String?,for item:LibraryItem) {
        guard let index=items.firstIndex(where:{$0.id==item.id}) else { return }
        items[index].statusOverride=status;items[index].watched=status=="watched";save()
    }
    func status(_ item:LibraryItem,history:[WatchRecord])->String {
        if let override=item.statusOverride { return override }
        if item.watched { return "watched" }
        guard let titleID=item.titleID,let record=history.filter({$0.contentType==item.type && $0.titleID==titleID && $0.stream.playableSource != nil}).max(by:{$0.lastWatched<$1.lastWatched}) else { return "planned" }
        return item.type=="movie" && record.complete ? "watched" : "watching"
    }
    func toggle(_ item:LibraryItem) { setStatus(item.watched ? "planned" : "watched",for:item) }
    @discardableResult func remove(_ item:LibraryItem)->Int? { guard let index=items.firstIndex(where:{$0.id==item.id}) else { return nil };items.remove(at:index);save();return index }
    func restore(_ item:LibraryItem,at index:Int) { guard !items.contains(where:{$0.id==item.id}) else { return };items.insert(item,at:min(max(0,index),items.count));save() }
    func applySyncedItems(_ values:[LibraryItem]) { items=values;save() }
    private func save() { do { try JSONEncoder().encode(items).write(to:file,options:.atomic) } catch { self.error="Could not save library: \(error.localizedDescription)" } }
}
