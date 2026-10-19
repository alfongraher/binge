import Foundation
import Combine

struct IPadWatchContext: Codable, Sendable {
    var titleID:String
    var type:String
    var contentID:String
    var name:String
    var poster:URL?
    var episodeLabel:String?
    var season:Int?
    var episode:Int?
    var genres:[String]?
    var estimatedDuration:Double?
    var background:URL?
    var thumbnail:URL?
    var displayName:String { episodeLabel.map { name + " · " + $0 } ?? name }
    init(title:CatalogTitle,episode:CatalogTitle.Episode?=nil) {
        titleID=title.id;type=title.type;contentID=episode?.id ?? title.id
        name=title.name;poster=title.poster;episodeLabel=episode?.label;season=episode?.season;self.episode=episode?.episode
        genres=title.genres;estimatedDuration=title.estimatedDuration
        background=title.background;thumbnail=episode?.thumbnail
    }
}
struct IPadWatchRecord: Codable, Identifiable, Sendable {
    var id:String { context.type+":"+context.contentID }
    var context:IPadWatchContext
    var stream:AddonStream?
    var position:Double
    var duration:Double
    var completed:Bool
    var hidden:Bool
    var updated:Date
}
@MainActor final class IPadHistory:ObservableObject {
    static let shared=IPadHistory()
    @Published private(set) var records:[IPadWatchRecord]=[]
    private let defaults:UserDefaults
    init(defaults:UserDefaults = .standard) {
        self.defaults=defaults
        if let data=defaults.data(forKey:"binge.ipad.watchHistory"),let saved=try? JSONDecoder().decode([IPadWatchRecord].self,from:data) { records=saved }
    }
    var continuing:[IPadWatchRecord] {
        var seen=Set<String>()
        return records.filter {$0.stream != nil}.sorted {$0.updated>$1.updated}.filter {
            let key=$0.context.type+":"+$0.context.titleID
            guard seen.insert(key).inserted else { return false }
            return !$0.hidden && $0.stream != nil
        }
    }
    func record(_ context:IPadWatchContext)->IPadWatchRecord? { records.first {$0.context.type==context.type && $0.context.contentID==context.contentID} }
    func latest(titleID:String,type:String)->IPadWatchRecord? { records.filter {$0.context.titleID==titleID && $0.context.type==type && $0.stream != nil}.max {$0.updated<$1.updated} }
    func save(_ context:IPadWatchContext,stream:AddonStream,position:Double,duration:Double,completed:Bool=false) {
        guard position.isFinite,position>=0,duration.isFinite,duration>=0 else { return }
        let previous=record(context)
        guard position>=3 || completed || previous != nil else { return }
        var enriched=context
        if enriched.genres == nil { enriched.genres=previous?.context.genres }
        if enriched.background == nil { enriched.background=previous?.context.background }
        if enriched.thumbnail == nil { enriched.thumbnail=previous?.context.thumbnail }
        let value=IPadWatchRecord(context:enriched,stream:stream,position:position,duration:duration>0 ? duration : previous?.duration ?? 0,completed:completed || CreditsTiming.reached(position:position,duration:duration,type:context.type) || previous?.completed == true,hidden:false,updated:Date())
        records.removeAll {$0.id==value.id};records.append(value);persist()
    }
    func queueNext(_ context:IPadWatchContext,stream:AddonStream) {
        guard record(context)?.completed != true else { return }
        let previous=record(context)
        let value=IPadWatchRecord(context:context,stream:stream,position:previous?.position ?? 0,duration:previous?.duration ?? 0,completed:false,hidden:false,updated:Date())
        records.removeAll {$0.id==value.id};records.append(value);persist()
    }
    func mark(_ context:IPadWatchContext,watched:Bool) {
        var value=record(context) ?? IPadWatchRecord(context:context,position:0,duration:0,completed:false,hidden:true,updated:Date())
        value.completed=watched
        // Marking elsewhere doesn't change the last episode actually played.
        if let index=records.firstIndex(where:{$0.id==value.id}) { records[index]=value } else { records.append(value) }
        persist()
    }
    func hide(_ record:IPadWatchRecord) {
        guard let index=records.firstIndex(where:{$0.id==record.id}) else { return };records[index].hidden=true;persist()
    }
    func setGenres(_ genres:[String],titleID:String,type:String) {
        for index in records.indices where records[index].context.titleID==titleID && records[index].context.type==type {
            records[index].context.genres=genres
        }
        persist()
    }
    func setArtwork(_ title:CatalogTitle) {
        for index in records.indices where records[index].context.titleID==title.id && records[index].context.type==title.type {
            records[index].context.background=title.background
            records[index].context.thumbnail=title.videos?.first(where:{$0.id==records[index].context.contentID})?.thumbnail
        }
        persist()
    }
    func applySyncedRecords(_ values:[IPadWatchRecord]) { records=values;persist() }
    private func persist() { if let data=try? JSONEncoder().encode(records) { defaults.set(data,forKey:"binge.ipad.watchHistory") } }
}
