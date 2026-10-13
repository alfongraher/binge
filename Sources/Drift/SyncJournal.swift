import Foundation

struct SyncStamp:Codable,Comparable,Sendable {
    var clock:Int64
    var author:String
    static func <(a:Self,b:Self)->Bool { a.clock==b.clock ? a.author<b.author : a.clock<b.clock }
}
struct SyncField:Codable,Equatable,Sendable {
    var value:Data?
    var stamp:SyncStamp
}
struct SyncItem:Codable,Sendable {
    var key:String
    var fields:[String:Data]
    var date:Date
}
struct SyncTitle:Codable,Sendable {
    var id:String
    var type:String
    var name:String
    var poster:URL?
    var background:URL?
    var thumbnail:URL?
    var episodeLabel:String?
    var season:Int?
    var episode:Int?
    var genres:[String]?
}
struct SyncProgress:Codable,Sendable { var position:Double;var duration:Double;var watchedAt:Date }
struct SyncJournal:Codable,Sendable {
    var clock:Int64=0
    var entries:[String:[String:SyncField]]=[:]
    var baseline:[String:[String:Data]]=[:]
    static func data<T:Encodable>(_ value:T)->Data { let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys;return (try? encoder.encode(value)) ?? Data() }
    static func decode<T:Decodable>(_ type:T.Type,_ data:Data?)->T? { data.flatMap {try? JSONDecoder().decode(type,from:$0)} }
    mutating func capture(_ snapshot:[SyncItem],author:String)->Bool {
        var changed=false
        let old=baseline
        let current=Dictionary(snapshot.map {($0.key,$0.fields)},uniquingKeysWith:{$1})
        for item in snapshot {
            for (name,value) in item.fields where old[item.key]?[name] != value {
                let initial=old[item.key] == nil && entries[item.key]?[name] == nil
                let time=initial ? item.date : Date()
                let raw=time.timeIntervalSince1970*1_000_000
                let initialClock=raw.isFinite ? Int64(min(Double(Int64.max/4),max(0,raw))) : 0
                let stamp=SyncStamp(clock:initial ? initialClock : nextClock(),author:author)
                if let existing=entries[item.key]?[name],existing.stamp>stamp { continue }
                entries[item.key,default:[:]][name]=SyncField(value:value,stamp:stamp);clock=max(clock,stamp.clock);changed=true
            }
        }
        // A removal is an explicit membership tombstone, retained across reconnects.
        for key in old.keys where key.hasPrefix("library|") && current[key]==nil {
            let field=SyncField(value:Self.data(false),stamp:SyncStamp(clock:nextClock(),author:author))
            entries[key,default:[:]]["member"]=field;changed=true
        }
        baseline=current
        return changed
    }
    mutating func nextClock()->Int64 { clock=max(clock,Int64(Date().timeIntervalSince1970*1_000_000))+1;return clock }
    @discardableResult mutating func merge(_ remote:[String:[String:SyncField]],history:Bool,library:Bool)->Bool {
        var changed=false
        for (key,fields) in remote {
            guard key.count<=512,(history && key.hasPrefix("history|")) || (library && key.hasPrefix("library|")) else { continue }
            for (name,value) in fields where name.count<=32 && (value.value?.count ?? 0)<=128*1024 {
                guard value.stamp.clock>=0,value.stamp.clock<Int64.max/2,value.stamp.author.count<=128 else { continue }
                clock=max(clock,value.stamp.clock)
                if entries[key]?[name].map({$0.stamp>=value.stamp}) == true { continue }
                entries[key,default:[:]][name]=value;changed=true
            }
        }
        return changed
    }
    func snapshot(history:Bool=true,library:Bool=true)->[SyncItem] {
        entries.compactMap {key,fields in
            guard (history && key.hasPrefix("history|")) || (library && key.hasPrefix("library|")) else { return nil }
            return SyncItem(key:key,fields:fields.compactMapValues(\.value),date:Date())
        }
    }
    mutating func acceptBaseline(_ snapshot:[SyncItem]) { baseline=Dictionary(snapshot.map {($0.key,$0.fields)},uniquingKeysWith:{$1}) }
}
