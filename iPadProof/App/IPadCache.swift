import Foundation
import CryptoKit

@MainActor final class IPadCacheLease {
    let key:String
    let folder:URL
    let sourceHash:String?
    let previous:IPadCacheLease?
    var workerFinished=true
    var discard=false
    init(key:String,folder:URL,sourceHash:String?=nil,previous:IPadCacheLease?=nil) { self.key=key;self.folder=folder;self.sourceHash=sourceHash;self.previous=previous }
}
@MainActor final class IPadCacheStore {
    static let shared=IPadCacheStore()
    let root:URL
    private(set) var current:IPadCacheLease?
    private struct Manifest:Codable { var key:String;var folder:String;var completed:Bool?;var sourceHash:String? }
    init(root:URL?=nil) {
        self.root=root ?? FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("binge-watch-cache")
        try? FileManager.default.createDirectory(at:self.root,withIntermediateDirectories:true)
        if let data=try? Data(contentsOf:self.root.appendingPathComponent("current.json")),let saved=try? JSONDecoder().decode(Manifest.self,from:data),UUID(uuidString:saved.folder) != nil {
            let folder=self.root.appendingPathComponent(saved.folder)
            if saved.completed == true { try? FileManager.default.removeItem(at:folder);try? FileManager.default.removeItem(at:self.root.appendingPathComponent("current.json")) }
            else if FileManager.default.fileExists(atPath:folder.path) { current=IPadCacheLease(key:saved.key,folder:folder,sourceHash:saved.sourceHash) }
        }
        if root == nil {
            let caches=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0]
            // Development proofs have isolated caches; they must not accumulate
            // beside the user's retained source when returning to the app.
            for name in ["binge-real-source-proof","binge-audio-proof","binge-feature-proof","binge-upnext-proof","binge-seek-proof"] {
                try? FileManager.default.removeItem(at:caches.appendingPathComponent(name))
            }
            let comparison=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("mac-reference.mp4")
            try? FileManager.default.removeItem(at:comparison)
            for folder in (try? FileManager.default.contentsOfDirectory(at:caches,includingPropertiesForKeys:nil)) ?? [] where folder.lastPathComponent.hasPrefix("binge-ipad-") && UUID(uuidString:String(folder.lastPathComponent.dropFirst("binge-ipad-".count))) != nil { try? FileManager.default.removeItem(at:folder) }
        }
        if let current { pruneCompleted(current,except:nil) }
        // Only our own cache root is managed; retire orphaned prior selections.
        for folder in (try? FileManager.default.contentsOfDirectory(at:self.root,includingPropertiesForKeys:nil)) ?? [] where UUID(uuidString:folder.lastPathComponent) != nil && folder != current?.folder { try? FileManager.default.removeItem(at:folder) }
    }
    func acquire(_ stream:AddonStream)->IPadCacheLease {
        let identity=(stream.infoHash ?? stream.playableSource ?? "")+"|"+String(stream.fileIdx ?? -1)
        let key=SHA256.hash(data:Data(identity.utf8)).map { String(format:"%02x",$0) }.joined()
        let lease:IPadCacheLease
        if let old=current,(old.key==key || (stream.infoHash != nil && old.sourceHash==stream.infoHash)),!old.discard { lease=IPadCacheLease(key:key,folder:old.folder,sourceHash:stream.infoHash,previous:old) }
        else {
            if let old=current { retire(old) }
            lease=IPadCacheLease(key:key,folder:root.appendingPathComponent(UUID().uuidString),sourceHash:stream.infoHash)
        }
        current=lease
        try? FileManager.default.createDirectory(at:lease.folder,withIntermediateDirectories:true)
        if let data=try? JSONEncoder().encode(Manifest(key:key,folder:lease.folder.lastPathComponent,completed:false,sourceHash:lease.sourceHash)) { try? data.write(to:root.appendingPathComponent("current.json"),options:.atomic) }
        return lease
    }
    func markCompleted(_ lease:IPadCacheLease,completed:Bool=true) {
        guard current === lease else { return }
        if let data=try? JSONEncoder().encode(Manifest(key:lease.key,folder:lease.folder.lastPathComponent,completed:completed,sourceHash:lease.sourceHash)) { try? data.write(to:root.appendingPathComponent("current.json"),options:.atomic) }
    }
    func workerEnded(_ lease:IPadCacheLease) { lease.workerFinished=true;if lease.discard { try? FileManager.default.removeItem(at:lease.folder) } }
    func retire(_ lease:IPadCacheLease) {
        lease.discard=true
        if lease.workerFinished { try? FileManager.default.removeItem(at:lease.folder) }
        if current === lease { current=nil;try? FileManager.default.removeItem(at:root.appendingPathComponent("current.json")) }
    }
    func rememberCompletedPayload(_ path:String,in lease:IPadCacheLease) {
        let prefix=lease.folder.standardizedFileURL.path+"/"
        guard path.hasPrefix(prefix) else { return }
        let file=lease.folder.appendingPathComponent("retired.json")
        var names=(try? Data(contentsOf:file)).flatMap { try? JSONDecoder().decode([String].self,from:$0) } ?? []
        let relative=String(path.dropFirst(prefix.count))
        if !names.contains(relative) { names.append(relative) }
        if let data=try? JSONEncoder().encode(names) { try? data.write(to:file,options:.atomic) }
    }
    func pruneCompleted(_ lease:IPadCacheLease,except path:String?) {
        let file=lease.folder.appendingPathComponent("retired.json")
        let names=(try? Data(contentsOf:file)).flatMap { try? JSONDecoder().decode([String].self,from:$0) } ?? []
        for name in names {
            let url=lease.folder.appendingPathComponent(name).standardizedFileURL
            guard url.path.hasPrefix(lease.folder.standardizedFileURL.path+"/"),url.path != path else { continue }
            try? FileManager.default.removeItem(at:url)
        }
        try? FileManager.default.removeItem(at:file)
    }
    func clear() { if let current { retire(current) } }
}
