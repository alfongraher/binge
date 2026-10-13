import Foundation
import Combine

enum IPadLibraryStatus:String,Codable,CaseIterable,Sendable {
    case planned,watching,watched
    var label:String { switch self { case .planned:"Plan to watch";case .watching:"Watching";case .watched:"Watched" } }
    var icon:String { switch self { case .planned:"bookmark";case .watching:"play.circle";case .watched:"checkmark.circle" } }
}
enum IPadLibrarySection:String,CaseIterable {
    case all,planned,favourites,watching,watched
    var label:String { switch self { case .all:"All titles";case .planned:"Plan to watch";case .favourites:"Favourites";case .watching:"Watching";case .watched:"Watched" } }
}
enum IPadLibrarySort:String,CaseIterable {
    case added,alphabetical,recentlyWatched
    var label:String { switch self { case .added:"Recently added";case .alphabetical:"Title A–Z";case .recentlyWatched:"Recently watched" } }
}
struct IPadSavedTitle:Codable,Identifiable,Sendable {
    var id:String
    var type:String
    var name:String
    var poster:URL?
    var favourite:Bool=false
    var statusOverride:IPadLibraryStatus?
    var addedAt:Date=Date()
    var key:String { type+":"+id }
    var catalogTitle:CatalogTitle { CatalogTitle(id:id,type:type,name:name,poster:poster) }
    init(title:CatalogTitle) { id=title.id;type=title.type;name=title.name;poster=title.poster }
    private enum CodingKeys:String,CodingKey { case id,type,name,poster,favourite,statusOverride,addedAt }
    init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        id=try c.decode(String.self,forKey:.id);type=try c.decode(String.self,forKey:.type);name=try c.decode(String.self,forKey:.name)
        poster=try c.decodeIfPresent(URL.self,forKey:.poster)
        favourite=try c.decodeIfPresent(Bool.self,forKey:.favourite) ?? false
        statusOverride=try c.decodeIfPresent(IPadLibraryStatus.self,forKey:.statusOverride)
        // Preserve the stored order for older titles, which had no timestamp.
        addedAt=try c.decodeIfPresent(Date.self,forKey:.addedAt) ?? .distantPast
    }
}
@MainActor final class IPadLibrary:ObservableObject {
    @Published private(set) var titles:[IPadSavedTitle]=[]
    private let defaults:UserDefaults
    init(defaults:UserDefaults = .standard) {
        self.defaults=defaults
        if let data=defaults.data(forKey:"binge.ipad.savedTitles"),let saved=try? JSONDecoder().decode([IPadSavedTitle].self,from:data) { titles=saved }
    }
    func contains(_ title:CatalogTitle)->Bool { titles.contains {$0.id==title.id && $0.type==title.type} }
    func isFavourite(_ title:CatalogTitle)->Bool { titles.first {$0.id==title.id && $0.type==title.type}?.favourite == true }
    func toggle(_ title:CatalogTitle) {
        if let index=titles.firstIndex(where:{$0.id==title.id && $0.type==title.type}) { titles.remove(at:index) }
        else { titles.insert(IPadSavedTitle(title:title),at:0) }
        persist()
    }
    func toggleFavourite(_ title:CatalogTitle) {
        let index=ensure(title)
        titles[index].favourite.toggle();persist()
    }
    func setStatus(_ status:IPadLibraryStatus?,for title:CatalogTitle) {
        let index=ensure(title);titles[index].statusOverride=status;persist()
    }
    @discardableResult func remove(_ item:IPadSavedTitle)->Int? {
        guard let index=titles.firstIndex(where:{$0.key==item.key}) else { return nil }
        titles.remove(at:index);persist();return index
    }
    func restore(_ item:IPadSavedTitle,at index:Int) {
        guard !titles.contains(where:{$0.key==item.key}) else { return }
        titles.insert(item,at:min(max(0,index),titles.count));persist()
    }
    func status(for item:IPadSavedTitle,records:[IPadWatchRecord])->IPadLibraryStatus {
        if let status=item.statusOverride { return status }
        let played=records.filter {$0.context.titleID==item.id && $0.context.type==item.type && ($0.stream != nil || $0.completed)}
        guard let latest=played.max(by:{$0.updated<$1.updated}) else { return .planned }
        // An individual completed episode does not mean the whole show is finished.
        return item.type=="movie" && latest.completed ? .watched : .watching
    }
    func filtered(section:IPadLibrarySection,type:String,query:String,sort:IPadLibrarySort,records:[IPadWatchRecord])->[IPadSavedTitle] {
        let groups=Dictionary(grouping:records,by:{$0.context.type+":"+$0.context.titleID})
        let query=query.trimmingCharacters(in:.whitespacesAndNewlines)
        return titles.enumerated().filter { _,item in
            guard (type=="all" || item.type==type),(query.isEmpty || item.name.localizedStandardContains(query)) else { return false }
            let status=status(for:item,records:groups[item.key] ?? [])
            switch section {
            case .all:return true
            case .favourites:return item.favourite
            case .planned:return status == .planned
            case .watching:return status == .watching
            case .watched:return status == .watched
            }
        }.sorted { a,b in
            switch sort {
            case .alphabetical:
                let result=a.element.name.localizedStandardCompare(b.element.name)
                return result == .orderedSame ? a.offset<b.offset : result == .orderedAscending
            case .added:
                return a.element.addedAt==b.element.addedAt ? a.offset<b.offset : a.element.addedAt>b.element.addedAt
            case .recentlyWatched:
                let ad=groups[a.element.key]?.map(\.updated).max() ?? .distantPast
                let bd=groups[b.element.key]?.map(\.updated).max() ?? .distantPast
                return ad==bd ? a.offset<b.offset : ad>bd
            }
        }.map(\.element)
    }
    private func ensure(_ title:CatalogTitle)->Int {
        if let index=titles.firstIndex(where:{$0.id==title.id && $0.type==title.type}) { return index }
        titles.insert(IPadSavedTitle(title:title),at:0);return 0
    }
    func applySyncedTitles(_ values:[IPadSavedTitle]) { titles=values;persist() }
    private func persist() { if let data=try? JSONEncoder().encode(titles) { defaults.set(data,forKey:"binge.ipad.savedTitles") } }
}
