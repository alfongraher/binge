import Foundation

@MainActor enum MacSyncAdapter {
    static func snapshot(history:WatchHistory,library:LibraryStore)->[SyncItem] {
        var items=history.records.compactMap { record->SyncItem? in
            guard let titleID=record.titleID,let contentID=record.contentID else { return nil }
            let pieces=record.title.components(separatedBy:" · ")
            let episode=record.contentID?.split(separator:":") ?? []
            let title=SyncTitle(id:titleID,type:record.contentType,name:pieces[0],poster:record.poster,background:record.background,thumbnail:record.thumbnail,episodeLabel:pieces.count>1 ? pieces.dropFirst().joined(separator:" · ") : nil,season:episode.count>=3 ? Int(episode[episode.count-2]) : nil,episode:episode.count>=3 ? Int(episode.last!) : nil,genres:record.genres)
            var fields=["title":SyncJournal.data(title),"progress":SyncJournal.data(SyncProgress(position:record.position,duration:record.duration,watchedAt:record.lastWatched)),"watched":SyncJournal.data(record.complete),"hidden":SyncJournal.data(record.dismissed ?? false)]
            if record.stream.playableSource != nil { fields["stream"]=SyncJournal.data(record.stream) }
            return SyncItem(key:"history|"+record.contentType+"|"+contentID,fields:fields,date:record.lastWatched)
        }
        let groups=Dictionary(grouping:library.items.filter {$0.titleID != nil},by:{$0.type+"|"+$0.titleID!})
        items += groups.compactMap { key,values in
            guard let item=values.first,let title=item.catalogTitle else { return nil }
            let date=values.map(\.added).min() ?? item.added
            let status=item.statusOverride ?? (item.watched ? "watched" : nil)
            return SyncItem(key:"library|"+key,fields:["title":SyncJournal.data(SyncTitle(id:title.id,type:title.type,name:title.name,poster:title.poster)),"member":SyncJournal.data(true),"favourite":SyncJournal.data(values.contains {$0.favourite == true}),"status":SyncJournal.data(status),"added":SyncJournal.data(date)],date:date)
        }
        return items
    }
    static func apply(_ snapshot:[SyncItem],history:WatchHistory,library:LibraryStore) {
        var records=history.records,items=library.items
        for item in snapshot {
            let parts=item.key.split(separator:"|",maxSplits:2).map(String.init)
            guard parts.count==3,["movie","series","anime"].contains(parts[1]),!parts[2].isEmpty,let title=SyncJournal.decode(SyncTitle.self,item.fields["title"]),title.type==parts[1] else { continue }
            if parts[0]=="history" {
                let id=title.type+":"+parts[2]
                let index=records.firstIndex {$0.id==id}
                var value=index.map {records[$0]} ?? WatchRecord(id:id,title:title.name,contentType:title.type,contentID:parts[2],poster:title.poster,stream:AddonStream(),genres:[],position:0,duration:0,lastWatched:.distantPast)
                value.title=title.name+(title.episodeLabel.map {" · "+$0} ?? "");value.poster=title.poster;value.background=title.background;value.thumbnail=title.thumbnail;value.genres=title.genres ?? []
                if let p=SyncJournal.decode(SyncProgress.self,item.fields["progress"]),p.position.isFinite,p.duration.isFinite,p.position>=0,p.duration>=0 { value.position=p.position;value.duration=p.duration;value.lastWatched=p.watchedAt }
                if let watched=SyncJournal.decode(Bool.self,item.fields["watched"]) { value.watchedOverride=watched }
                if let hidden=SyncJournal.decode(Bool.self,item.fields["hidden"]) { value.dismissed=hidden }
                if let stream=SyncJournal.decode(AddonStream.self,item.fields["stream"]),stream.playableSource != nil { value.stream=stream }
                if let index { records[index]=value } else { records.append(value) }
            } else if parts[0]=="library",title.id==parts[2] {
                if SyncJournal.decode(Bool.self,item.fields["member"])==false { items.removeAll {$0.titleID==title.id && $0.type==title.type};continue }
                guard SyncJournal.decode(Bool.self,item.fields["member"])==true else { continue }
                let indexes=items.indices.filter {items[$0].titleID==title.id && items[$0].type==title.type}
                if indexes.isEmpty {
                    items.append(LibraryItem(title:title.name,source:"",kind:title.type=="movie" ? "Movie" : "Series",contentID:title.id,poster:title.poster,catalogueType:title.type,catalogueID:title.id))
                }
                for index in items.indices where items[index].titleID==title.id && items[index].type==title.type {
                    if let favourite=SyncJournal.decode(Bool.self,item.fields["favourite"]) { items[index].favourite=favourite }
                    if item.fields["status"] != nil { items[index].statusOverride=SyncJournal.decode(String.self,item.fields["status"]);items[index].watched=items[index].statusOverride=="watched" }
                    if let date=SyncJournal.decode(Date.self,item.fields["added"]) { items[index].added=date }
                    if items[index].poster==nil { items[index].poster=title.poster }
                }
            }
        }
        history.applySyncedRecords(records);library.applySyncedItems(items)
    }
}
