import Foundation

@MainActor enum IPadSyncAdapter {
    static func snapshot(history:IPadHistory,library:IPadLibrary)->[SyncItem] {
        var items=history.records.map { record in
            let c=record.context
            let title=SyncTitle(id:c.titleID,type:c.type,name:c.name,poster:c.poster,background:c.background,thumbnail:c.thumbnail,episodeLabel:c.episodeLabel,season:c.season,episode:c.episode,genres:c.genres)
            var fields=["title":SyncJournal.data(title),"progress":SyncJournal.data(SyncProgress(position:record.position,duration:record.duration,watchedAt:record.updated)),"watched":SyncJournal.data(record.completed),"hidden":SyncJournal.data(record.hidden)]
            if let stream=record.stream { fields["stream"]=SyncJournal.data(stream) }
            return SyncItem(key:"history|"+c.type+"|"+c.contentID,fields:fields,date:record.updated)
        }
        items += library.titles.map { item in
            SyncItem(key:"library|"+item.type+"|"+item.id,fields:["title":SyncJournal.data(SyncTitle(id:item.id,type:item.type,name:item.name,poster:item.poster)),"member":SyncJournal.data(true),"favourite":SyncJournal.data(item.favourite),"status":SyncJournal.data(item.statusOverride?.rawValue),"added":SyncJournal.data(item.addedAt)],date:item.addedAt)
        }
        return items
    }
    static func apply(_ snapshot:[SyncItem],history:IPadHistory,library:IPadLibrary) {
        var records=history.records,titles=library.titles
        for item in snapshot {
            let parts=item.key.split(separator:"|",maxSplits:2).map(String.init)
            guard parts.count==3,["movie","series","anime"].contains(parts[1]),!parts[2].isEmpty,let title=SyncJournal.decode(SyncTitle.self,item.fields["title"]),title.type==parts[1] else { continue }
            if parts[0]=="history" {
                let contentID=parts[2]
                var context=IPadWatchContext(title:CatalogTitle(id:title.id,type:title.type,name:title.name,poster:title.poster,genres:title.genres,background:title.background))
                context.contentID=contentID;context.episodeLabel=title.episodeLabel;context.season=title.season;context.episode=title.episode;context.thumbnail=title.thumbnail
                let index=records.firstIndex {$0.context.type==title.type && $0.context.contentID==contentID}
                var record=index.map {records[$0]} ?? IPadWatchRecord(context:context,position:0,duration:0,completed:false,hidden:true,updated:.distantPast)
                record.context=context
                if let p=SyncJournal.decode(SyncProgress.self,item.fields["progress"]),p.position.isFinite,p.duration.isFinite,p.position>=0,p.duration>=0 { record.position=p.position;record.duration=p.duration;record.updated=p.watchedAt }
                if let watched=SyncJournal.decode(Bool.self,item.fields["watched"]) { record.completed=watched }
                if let hidden=SyncJournal.decode(Bool.self,item.fields["hidden"]) { record.hidden=hidden }
                if let stream=SyncJournal.decode(AddonStream.self,item.fields["stream"]),stream.playableSource != nil { record.stream=stream }
                if let index { records[index]=record } else { records.append(record) }
            } else if parts[0]=="library",title.id==parts[2] {
                let index=titles.firstIndex {$0.type==title.type && $0.id==title.id}
                if SyncJournal.decode(Bool.self,item.fields["member"])==false { if let index { titles.remove(at:index) };continue }
                guard SyncJournal.decode(Bool.self,item.fields["member"])==true else { continue }
                var value=index.map {titles[$0]} ?? IPadSavedTitle(title:CatalogTitle(id:title.id,type:title.type,name:title.name,poster:title.poster))
                value.name=title.name;value.poster=title.poster
                if let favourite=SyncJournal.decode(Bool.self,item.fields["favourite"]) { value.favourite=favourite }
                if item.fields["status"] != nil { value.statusOverride=SyncJournal.decode(String.self,item.fields["status"]).flatMap(IPadLibraryStatus.init(rawValue:)) }
                if let date=SyncJournal.decode(Date.self,item.fields["added"]) { value.addedAt=date }
                if let index { titles[index]=value } else { titles.append(value) }
            }
        }
        history.applySyncedRecords(records);library.applySyncedTitles(titles)
    }
}
