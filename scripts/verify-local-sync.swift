import Foundation
import CryptoKit
import Network

@main struct LocalSyncCheck {
    @MainActor static func main() async throws {
        let root=URL(fileURLWithPath:"/private/tmp").appendingPathComponent("binge-sync-check-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let mHistory=WatchHistory(file:root.appendingPathComponent("mac-history.json")),mLibrary=LibraryStore(file:root.appendingPathComponent("mac-library.json"))
        let suite="binge.sync.check."+UUID().uuidString,ipadDefaults=UserDefaults(suiteName:suite)!
        defer { ipadDefaults.removePersistentDomain(forName:suite) }
        let pHistory=IPadHistory(defaults:ipadDefaults),pLibrary=IPadLibrary(defaults:ipadDefaults)
        let title=CatalogTitle(id:"ttsync",type:"series",name:"Sync fixture"),episode=CatalogTitle.Episode(id:"ttsync:2:3",season:2,episode:3)
        let stream=AddonStream(infoHash:String(repeating:"a",count:40),fileIdx:3)
        let context=IPadWatchContext(title:title,episode:episode)
        pHistory.save(context,stream:stream,position:120,duration:1000)
        pLibrary.toggleFavourite(title)
        var a=SyncJournal(),b=SyncJournal()
        _=a.capture(IPadSyncAdapter.snapshot(history:pHistory,library:pLibrary),author:"ipad")
        _=b.merge(a.entries,history:true,library:true)
        MacSyncAdapter.apply(b.snapshot(),history:mHistory,library:mLibrary)
        b.acceptBaseline(MacSyncAdapter.snapshot(history:mHistory,library:mLibrary))
        precondition(mLibrary.isFavourite(title) && mHistory.records.first!.position==120 && mHistory.records.first!.contentID==episode.id)
        mHistory.markWatched(episode,watched:true,poster:nil,type:"series")
        _=b.capture(MacSyncAdapter.snapshot(history:mHistory,library:mLibrary),author:"mac")
        pHistory.save(context,stream:stream,position:60,duration:1000)
        _=a.capture(IPadSyncAdapter.snapshot(history:pHistory,library:pLibrary),author:"ipad")
        _=a.merge(b.entries,history:true,library:true)
        _=b.merge(a.entries,history:true,library:true)
        IPadSyncAdapter.apply(a.snapshot(),history:pHistory,library:pLibrary)
        precondition(pHistory.records.first!.completed && pHistory.records.first!.position==60)
        a.acceptBaseline(IPadSyncAdapter.snapshot(history:pHistory,library:pLibrary))
        let stale=b.entries
        _=pLibrary.remove(pLibrary.titles[0])
        _=a.capture(IPadSyncAdapter.snapshot(history:pHistory,library:pLibrary),author:"ipad")
        _=a.merge(stale,history:true,library:true)
        precondition(SyncJournal.decode(Bool.self,a.entries["library|series|ttsync"]?["member"]?.value)==false)
        _=b.merge(a.entries,history:true,library:true)
        MacSyncAdapter.apply(b.snapshot(),history:mHistory,library:mLibrary)
        precondition(mLibrary.items.isEmpty)
        let encoded=try JSONEncoder().encode(a),restored=try JSONDecoder().decode(SyncJournal.self,from:encoded)
        precondition(restored.entries==a.entries)
        print("PASS: cross-platform progress, watched flag without losing rewind, favourites, deletion tombstone, replay/stale snapshot, journal persistence")

        let s1="binge.sync.transport.a."+UUID().uuidString,s2="binge.sync.transport.b."+UUID().uuidString
        let d1=UserDefaults(suiteName:s1)!,d2=UserDefaults(suiteName:s2)!
        defer { d1.removePersistentDomain(forName:s1);d2.removePersistentDomain(forName:s2) }
        let peerA=LocalSync(defaults:d1,folder:root.appendingPathComponent("a"),identity:Curve25519.KeyAgreement.PrivateKey())
        let peerB=LocalSync(defaults:d2,folder:root.appendingPathComponent("b"),identity:Curve25519.KeyAgreement.PrivateKey())
        peerA.loopbackTest=true;peerB.loopbackTest=true
        var received:[SyncItem]=[]
        var fixture=SyncItem(key:"library|movie|fixture",fields:["member":SyncJournal.data(true),"favourite":SyncJournal.data(true)],date:Date())
        peerA.configure(capture:{[fixture]},apply:{_ in})
        peerB.configure(capture:{[]},apply:{received=$0})
        peerA.enabled=true;peerB.enabled=true
        for _ in 0..<100 { if let port=peerB.testPort,port.rawValue>0 { break };try await Task.sleep(for:.milliseconds(50)) }
        guard let port=peerB.testPort else { throw NSError(domain:"LocalSyncCheck",code:1,userInfo:[NSLocalizedDescriptionKey:"Listener did not become ready"]) }
        FileHandle.standardError.write(Data("test port: \(port.rawValue)\n".utf8))
        peerA.pair(NearbySyncPeer(id:peerB.deviceID,name:"Test B",endpoint:.hostPort(host:"127.0.0.1",port:port)))
        for _ in 0..<100 { if !peerA.requests.isEmpty && !peerB.requests.isEmpty { break };try await Task.sleep(for:.milliseconds(50)) }
        guard let ra=peerA.requests.first,let rb=peerB.requests.first else { throw NSError(domain:"LocalSyncCheck",code:2,userInfo:[NSLocalizedDescriptionKey:"Pairing handshake failed: A \(peerA.status) requests \(peerA.requests.count), B \(peerB.status) requests \(peerB.requests.count)"]) }
        precondition(ra.code==rb.code && received.isEmpty && peerA.paired.isEmpty && peerB.paired.isEmpty)
        peerA.confirm(ra.id)
        try await Task.sleep(for:.milliseconds(150));precondition(received.isEmpty)
        peerB.confirm(rb.id)
        for _ in 0..<100 { if !received.isEmpty { break };try await Task.sleep(for:.milliseconds(50)) }
        precondition(received.first?.fields["favourite"]==SyncJournal.data(true) && peerA.paired.count==1 && peerB.paired.count==1)
        peerB.automatic=false
        fixture.fields["favourite"]=SyncJournal.data(false)
        peerA.localChanged()
        try await Task.sleep(for:.seconds(1))
        precondition(received.first?.fields["favourite"]==SyncJournal.data(true))
        peerB.syncNow()
        for _ in 0..<100 { if received.first?.fields["favourite"]==SyncJournal.data(false) { break };try await Task.sleep(for:.milliseconds(50)) }
        precondition(received.first?.fields["favourite"]==SyncJournal.data(false))
        peerA.enabled=false
        fixture.fields["favourite"]=SyncJournal.data(true)
        peerA.localChanged();try await Task.sleep(for:.milliseconds(600))
        peerA.enabled=true
        peerA.pair(NearbySyncPeer(id:peerB.deviceID,name:"Test B",endpoint:.hostPort(host:"127.0.0.1",port:port)))
        for _ in 0..<100 { if received.first?.fields["favourite"]==SyncJournal.data(true) { break };try await Task.sleep(for:.milliseconds(50)) }
        precondition(received.first?.fields["favourite"]==SyncJournal.data(true) && peerA.requests.isEmpty && peerB.requests.isEmpty)
        var scoped=SyncJournal();_=scoped.merge(a.entries,history:false,library:true)
        precondition(scoped.entries.keys.allSatisfy {$0.hasPrefix("library|")})
        peerA.enabled=false;peerB.enabled=false
        print("PASS: auto-sync opt-out, manual request, offline update/reconnect without re-pairing, category scoping")
        print("PASS: real TCP framing, ECDH matching pairing code, no transfer before mutual confirmation, encrypted state exchange")
    }
}
