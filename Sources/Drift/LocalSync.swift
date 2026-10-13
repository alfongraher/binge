import Foundation
import Combine
import Network
import CryptoKit
import Security

struct SyncPeer:Identifiable,Codable,Sendable {
    var id:String
    var name:String
    var publicKey:Data
    var lastSync:Date?
}
struct NearbySyncPeer:Identifiable { var id:String;var name:String;var endpoint:NWEndpoint }
struct SyncPairRequest:Identifiable { var id:UUID;var name:String;var code:String;var confirmed:Bool=false }
private struct SyncWire:Codable {
    var kind:String
    var id:String?;var name:String?;var publicKey:Data?;var nonce:Data?;var pairing:Bool?
    var manual:Bool?
    var sealed:Data?
    var entries:[String:[String:SyncField]]?
}
@MainActor final class LocalSync:ObservableObject {
    static let shared=LocalSync()
    static let serviceType="_binge-sync._tcp"
    @Published var enabled=false { didSet { defaults.set(enabled,forKey:"binge.sync.enabled");updateNetwork() } }
    @Published var automatic=true { didSet { defaults.set(automatic,forKey:"binge.sync.automatic") } }
    @Published var syncHistory=true { didSet { defaults.set(syncHistory,forKey:"binge.sync.history");if syncHistory && configured { syncNow() } } }
    @Published var syncLibrary=true { didSet { defaults.set(syncLibrary,forKey:"binge.sync.library");if syncLibrary && configured { syncNow() } } }
    @Published private(set) var nearby:[NearbySyncPeer]=[]
    @Published private(set) var paired:[SyncPeer]=[]
    @Published private(set) var requests:[SyncPairRequest]=[]
    @Published private(set) var status="Sync is off" { didSet { writeReport() } }
    @Published private(set) var lastSync:Date?
    private let defaults:UserDefaults
    private let folder:URL
    let deviceID:String
    private var privateKey:Curve25519.KeyAgreement.PrivateKey?
    @Published var name:String {
        didSet {
            defaults.set(String(name.prefix(80)),forKey:"binge.sync.name")
            listener?.service=NWListener.Service(name:"binge-"+deviceID,type:Self.serviceType,txtRecord:NWTXTRecord(["id":deviceID,"name":String(name.prefix(80))]))
        }
    }
    private var journal=SyncJournal()
    private var listener:NWListener?
    private var browser:NWBrowser?
    private var sessions:[UUID:SyncSession]=[:]
    private var capture:()->[SyncItem]={[]}
    private var apply:([SyncItem])->Void={_ in}
    private var active=true
    private var applying=false
    private var debounce:Task<Void,Never>?
    private var timer:Task<Void,Never>?
    private var configured=false
    private var networkGeneration=UUID()
    private let queue=DispatchQueue(label:"binge.local-sync")
    #if DEBUG
    var loopbackTest=false
    var testPort:NWEndpoint.Port? { listener?.port }
    #endif
    init(defaults:UserDefaults = .standard,folder:URL?=nil,identity:Curve25519.KeyAgreement.PrivateKey?=nil) {
        self.defaults=defaults
        self.folder=folder ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("BingeSync",isDirectory:true)
        #if os(iOS)
        name=defaults.string(forKey:"binge.sync.name") ?? "iPad"
        #else
        name=defaults.string(forKey:"binge.sync.name") ?? "Mac"
        #endif
        deviceID=defaults.string(forKey:"binge.sync.deviceID") ?? UUID().uuidString
        defaults.set(deviceID,forKey:"binge.sync.deviceID")
        // Identity is local-only and protected by the system keychain.
        privateKey=identity
        enabled=defaults.bool(forKey:"binge.sync.enabled")
        automatic=defaults.object(forKey:"binge.sync.automatic") as? Bool ?? true
        syncHistory=defaults.object(forKey:"binge.sync.history") as? Bool ?? true
        syncLibrary=defaults.object(forKey:"binge.sync.library") as? Bool ?? true
        if let data=try? Data(contentsOf:self.folder.appendingPathComponent("journal.json")),let saved=try? JSONDecoder().decode(SyncJournal.self,from:data) { journal=saved }
        if let data=defaults.data(forKey:"binge.sync.paired"),let saved=try? JSONDecoder().decode([SyncPeer].self,from:data) { paired=saved }
    }
    func configure(capture:@escaping()->[SyncItem],apply:@escaping([SyncItem])->Void) {
        guard !configured else { return };configured=true;self.capture=capture;self.apply=apply
        captureNow();updateNetwork()
    }
    func localChanged() {
        guard configured,!applying else { return }
        debounce?.cancel();debounce=Task { try? await Task.sleep(for:.milliseconds(500));guard !Task.isCancelled else { return };captureNow();if automatic { broadcast() } }
    }
    func setActive(_ value:Bool) { active=value;if !value { captureNow() };updateNetwork() }
    func pair(_ peer:NearbySyncPeer) { guard enabled else { return };connect(peer,pairing:true) }
    func confirm(_ id:UUID) {
        guard let session=sessions[id],session.key != nil else { return }
        session.localApproved=true
        if let index=requests.firstIndex(where:{$0.id==id}) { requests[index].confirmed=true }
        sendEncrypted(SyncWire(kind:"approved"),session:session);finishApproval(session)
    }
    func cancel(_ id:UUID) { close(id) }
    func forget(_ peer:SyncPeer) {
        paired.removeAll {$0.id==peer.id};persistPeers();status="Device forgotten"
        for id in sessions.values.filter({$0.remoteID==peer.id}).map(\.id) { close(id) }
    }
    func syncNow() { refresh(manual:true) }
    private func refresh(manual:Bool) {
        captureNow()
        for peer in nearby where paired.contains(where:{$0.id==peer.id}) { connect(peer,pairing:false,manual:manual) }
        if manual { for session in sessions.values where session.authorized { sendEncrypted(SyncWire(kind:"request"),session:session) } }
        broadcast(manual:manual)
    }
    private func captureNow() { guard configured,!applying else { return };if journal.capture(capture(),author:deviceID) { persistJournal() } }
    private func updateNetwork() {
        guard configured else { return }
        guard enabled,active else {
            networkGeneration=UUID()
            timer?.cancel();timer=nil;browser?.cancel();browser=nil;listener?.cancel();listener=nil
            for id in Array(sessions.keys) { close(id) };nearby=[];status=enabled ? "Sync resumes when binge is open" : "Sync is off";return
        }
        guard listener==nil else { return }
        do {
            let generation=UUID();networkGeneration=generation
            if privateKey==nil { privateKey=try Self.loadIdentity() }
            captureNow()
            let listener=try NWListener(using:.tcp)
            var advertise=true
            #if DEBUG
            advertise = !loopbackTest
            #endif
            if advertise { listener.service=NWListener.Service(name:"binge-"+deviceID,type:Self.serviceType,txtRecord:NWTXTRecord(["id":deviceID,"name":name])) }
            listener.newConnectionHandler={ [weak self] connection in Task { @MainActor in guard let self,self.networkGeneration==generation else { connection.cancel();return };self.accept(connection,pairing:false) } }
            listener.stateUpdateHandler={ [weak self] state in Task { @MainActor in guard let self,self.networkGeneration==generation else { return };if case .failed(let error)=state { self.status="Local network unavailable: "+error.localizedDescription } } }
            self.listener=listener;listener.start(queue:queue)
            #if DEBUG
            if loopbackTest { status="Loopback test ready";return }
            #endif
            let browser=NWBrowser(for:.bonjourWithTXTRecord(type:Self.serviceType,domain:nil),using:.tcp)
            browser.browseResultsChangedHandler={ [weak self] results,_ in
                Task { @MainActor in guard let self,self.networkGeneration==generation else { return };self.found(results) }
            }
            browser.stateUpdateHandler={ [weak self] state in Task { @MainActor in guard let self,self.networkGeneration==generation else { return };if case .waiting(let error)=state { self.status="Allow Local Network access in system Settings. "+error.localizedDescription } } }
            self.browser=browser;browser.start(queue:queue);status="Looking for devices on this network"
            timer=Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for:.seconds(15));guard !Task.isCancelled else { return }
                    if automatic { refresh(manual:false) }
                }
            }
        } catch { status="Couldn’t start local sync: "+error.localizedDescription }
    }
    private func found(_ results:Set<NWBrowser.Result>) {
        nearby=results.compactMap { result in
            guard case .bonjour(let txt)=result.metadata,let id=txt["id"],id != deviceID else { return nil }
            return NearbySyncPeer(id:id,name:txt["name"] ?? "binge device",endpoint:result.endpoint)
        }.sorted {$0.name<$1.name}
        if automatic { for peer in nearby where paired.contains(where:{$0.id==peer.id}) { connect(peer,pairing:false) } }
        writeReport()
    }
    private func connect(_ peer:NearbySyncPeer,pairing:Bool,manual:Bool=false) {
        guard !sessions.values.contains(where:{$0.expectedID==peer.id || $0.remoteID==peer.id}) else { return }
        accept(NWConnection(to:peer.endpoint,using:.tcp),pairing:pairing,expectedID:peer.id,manual:manual)
    }
    private func accept(_ connection:NWConnection,pairing:Bool,expectedID:String?=nil,manual:Bool=false) {
        guard sessions.count<8 else { connection.cancel();return }
        let session=SyncSession(connection:connection,pairing:pairing,expectedID:expectedID,manual:manual);sessions[session.id]=session
        status="Connecting to device…"
        connection.stateUpdateHandler={ [weak self] state in
            Task { @MainActor in
                guard let self,self.sessions[session.id] != nil else { return }
                #if DEBUG
                FileHandle.standardError.write(Data("sync connection: \(state)\n".utf8))
                #endif
                switch state {
                case .ready:
                    self.send(SyncWire(kind:"hello",id:self.deviceID,name:self.name,publicKey:self.privateKey?.publicKey.rawRepresentation,nonce:session.nonce,pairing:pairing,manual:session.manual),session:session)
                    self.receive(session)
                case .waiting(let error):self.status="Couldn’t reach the device: "+error.localizedDescription
                case .failed(let error):self.status="Connection failed: "+error.localizedDescription;self.close(session.id)
                case .cancelled:self.close(session.id)
                default:break
                }
            }
        }
        connection.start(queue:queue)
        session.timeout=Task { try? await Task.sleep(for:.seconds(120));guard !Task.isCancelled else { return };if !session.authorized { self.status="Pairing timed out. Try again.";self.close(session.id) } }
    }
    private func receive(_ session:SyncSession) {
        session.connection.receive(minimumIncompleteLength:4,maximumLength:4) { [weak self] data,_,done,error in
            Task { @MainActor in
                guard let self,self.sessions[session.id] != nil,let data,data.count==4,error==nil else { self?.close(session.id);return }
                let size=data.reduce(0) {($0<<8)|Int($1)}
                guard size>0,size<=4*1024*1024,!done else { self.close(session.id);return }
                session.connection.receive(minimumIncompleteLength:size,maximumLength:size) { [weak self] bytes,_,finished,error in
                    Task { @MainActor in
                        guard let self,self.sessions[session.id] != nil,let bytes,bytes.count==size,error==nil,let wire=try? JSONDecoder().decode(SyncWire.self,from:bytes) else { self?.close(session.id);return }
                        self.handle(wire,session:session)
                        if finished { self.close(session.id) } else if self.sessions[session.id] != nil { self.receive(session) }
                    }
                }
            }
        }
    }
    private func handle(_ wire:SyncWire,session:SyncSession) {
        #if DEBUG
        FileHandle.standardError.write(Data("sync frame: \(wire.kind)\n".utf8))
        #endif
        if wire.kind=="hello" {
            guard session.key==nil,let id=wire.id,id != deviceID,id.count<=128,session.expectedID==nil || session.expectedID==id,
                  let publicData=wire.publicKey,let remoteKey=try? Curve25519.KeyAgreement.PublicKey(rawRepresentation:publicData),let nonce=wire.nonce,nonce.count==16,
                  let privateKey=self.privateKey,let secret=try? privateKey.sharedSecretFromKeyAgreement(with:remoteKey) else { close(session.id);return }
            session.remoteID=id;session.remoteName=String((wire.name ?? "binge device").prefix(80));session.remotePublic=publicData
            let salt=id<deviceID ? nonce+session.nonce : session.nonce+nonce
            session.key=secret.hkdfDerivedSymmetricKey(using:SHA256.self,salt:salt,sharedInfo:Data("binge-sync-v1".utf8),outputByteCount:32)
            session.manual = session.manual || wire.manual==true || wire.pairing==true
            if let peer=paired.first(where:{$0.id==id}) {
                guard peer.publicKey==publicData else { status="Device identity changed. Forget it and pair again.";close(session.id);return }
                session.localApproved=true
                if wire.pairing==true { requests.append(pairRequest(session,confirmed:true)) }
                sendEncrypted(SyncWire(kind:"approved"),session:session)
            } else {
                guard session.pairing || wire.pairing==true else { close(session.id);return }
                requests.append(pairRequest(session,confirmed:false))
                status="Compare the pairing code on both devices"
            }
            return
        }
        guard wire.kind=="sealed",let key=session.key,let sealed=wire.sealed,let box=try? AES.GCM.SealedBox(combined:sealed),
              let plain=try? AES.GCM.open(box,using:key),let message=try? JSONDecoder().decode(SyncWire.self,from:plain) else { close(session.id);return }
        if message.kind=="approved" { session.remoteApproved=true;finishApproval(session);return }
        guard session.authorized else { close(session.id);return }
        if message.kind=="request" { captureNow();sendState(session,manual:true);return }
        if message.kind=="data",let entries=message.entries,entries.count<=2000 {
            guard automatic || message.manual==true else { return }
            captureNow()
            for (key,fields) in entries { for (name,field) in fields { session.sent[key,default:[:]][name]=max(session.sent[key]?[name] ?? field.stamp,field.stamp) } }
            if journal.merge(entries,history:syncHistory,library:syncLibrary) {
                applying=true;apply(journal.snapshot(history:syncHistory,library:syncLibrary));journal.acceptBaseline(capture());applying=false;persistJournal()
                for other in sessions.values where other.id != session.id && other.authorized { sendState(other) }
            }
            lastSync=Date();status="Up to date with "+session.remoteName
            if let index=paired.firstIndex(where:{$0.id==session.remoteID}) { paired[index].lastSync=lastSync;persistPeers() }
            writeReport()
        }
    }
    private func finishApproval(_ session:SyncSession) {
        guard session.localApproved,session.remoteApproved,!session.authorized,let id=session.remoteID,let publicKey=session.remotePublic else { return }
        session.authorized=true;session.timeout?.cancel();requests.removeAll {$0.id==session.id}
        if !paired.contains(where:{$0.id==id}) { paired.append(SyncPeer(id:id,name:session.remoteName,publicKey:publicKey)) }
        else if let index=paired.firstIndex(where:{$0.id==id}) { paired[index].name=session.remoteName }
        persistPeers()
        status="Paired with "+session.remoteName;captureNow();sendState(session,manual:session.manual)
    }
    private func sendState(_ session:SyncSession,manual:Bool=false) {
        let selected=journal.entries.filter {(syncHistory && $0.key.hasPrefix("history|")) || (syncLibrary && $0.key.hasPrefix("library|"))}
        var batch:[String:[String:SyncField]]=[:],size=0
        func flush() {
            guard !batch.isEmpty else { return }
            if sendEncrypted(SyncWire(kind:"data",manual:manual,entries:batch),session:session) {
                for (key,fields) in batch { for (name,field) in fields { session.sent[key,default:[:]][name]=field.stamp } }
            }
            batch=[:];size=0
        }
        for (key,fields) in selected.sorted(by:{$0.key<$1.key}) {
            let changed=fields.filter { name,field in manual || session.sent[key]?[name].map({$0<field.stamp}) != false }
            guard !changed.isEmpty else { continue }
            let rowSize=(try? JSONEncoder().encode([key:changed]).count) ?? 0
            guard rowSize<=1024*1024 else { status="One sync record is too large. Local data was retained.";continue }
            if size+rowSize>1024*1024 || batch.count>=150 { flush() }
            batch[key]=changed;size+=rowSize
        }
        if batch.isEmpty && manual { sendEncrypted(SyncWire(kind:"data",manual:true,entries:[:]),session:session) }
        else { flush() }
    }
    private func broadcast(manual:Bool=false) { for session in sessions.values where session.authorized { sendState(session,manual:manual) } }
    private func pairRequest(_ session:SyncSession,confirmed:Bool)->SyncPairRequest {
        let digest=SHA256.hash(data:session.key!.withUnsafeBytes {Data($0)})
        let number=digest.prefix(4).reduce(UInt32(0)) {($0<<8)|UInt32($1)}%1_000_000
        return SyncPairRequest(id:session.id,name:session.remoteName,code:String(format:"%06u",number),confirmed:confirmed)
    }
    @discardableResult private func sendEncrypted(_ message:SyncWire,session:SyncSession)->Bool {
        guard let key=session.key,let bytes=try? JSONEncoder().encode(message),let box=try? AES.GCM.seal(bytes,using:key),let combined=box.combined else { return false }
        return send(SyncWire(kind:"sealed",sealed:combined),session:session)
    }
    @discardableResult private func send(_ message:SyncWire,session:SyncSession)->Bool {
        guard let bytes=try? JSONEncoder().encode(message),bytes.count<=4*1024*1024 else { status="Too much history for one sync. No data was removed.";return false }
        var size=UInt32(bytes.count).bigEndian;let header=withUnsafeBytes(of:&size) {Data($0)}
        session.connection.send(content:header+bytes,completion:.contentProcessed { [weak self] error in if error != nil { Task { @MainActor in self?.close(session.id) } } })
        return true
    }
    private func close(_ id:UUID) { guard let session=sessions.removeValue(forKey:id) else { return };session.timeout?.cancel();session.connection.stateUpdateHandler=nil;session.connection.cancel();requests.removeAll {$0.id==id} }
    private func persistJournal() {
        do { try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);let data=try JSONEncoder().encode(journal);try data.write(to:folder.appendingPathComponent("journal.json"),options:.atomic) }
        catch { status="Couldn’t save sync changes locally. "+error.localizedDescription }
    }
    private func persistPeers() { if let data=try? JSONEncoder().encode(paired) { defaults.set(data,forKey:"binge.sync.paired") } }
    private func writeReport() {
        #if os(iOS)
        let url=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("sync-result.json")
        if let data=try? JSONSerialization.data(withJSONObject:["status":status,"paired":paired.count,"nearby":nearby.count,"requests":requests.count,"entries":journal.entries.count],options:.prettyPrinted) { try? data.write(to:url) }
        #endif
    }
    private static func loadIdentity() throws ->Curve25519.KeyAgreement.PrivateKey {
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"local.binge.sync",kSecAttrAccount as String:"identity",kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var result:CFTypeRef?
        let lookup=SecItemCopyMatching(query as CFDictionary,&result)
        if lookup==errSecSuccess,let data=result as? Data { return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation:data) }
        guard lookup==errSecItemNotFound else { throw NSError(domain:NSOSStatusErrorDomain,code:Int(lookup)) }
        let key=Curve25519.KeyAgreement.PrivateKey()
        var add=query;add.removeValue(forKey:kSecReturnData as String);add.removeValue(forKey:kSecMatchLimit as String);add[kSecValueData as String]=key.rawRepresentation
        #if os(iOS)
        add[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        let saved=SecItemAdd(add as CFDictionary,nil)
        guard saved==errSecSuccess else { throw NSError(domain:NSOSStatusErrorDomain,code:Int(saved)) }
        return key
    }
}
@MainActor private final class SyncSession {
    let id=UUID()
    let connection:NWConnection
    let pairing:Bool
    let expectedID:String?
    let nonce=Data((0..<16).map {_ in UInt8.random(in:0...255)})
    var manual:Bool
    var sent:[String:[String:SyncStamp]]=[:]
    var key:SymmetricKey?
    var remoteID:String?;var remoteName="binge device";var remotePublic:Data?
    var localApproved=false;var remoteApproved=false;var authorized=false
    var timeout:Task<Void,Never>?
    init(connection:NWConnection,pairing:Bool,expectedID:String?,manual:Bool) { self.connection=connection;self.pairing=pairing;self.expectedID=expectedID;self.manual=manual || pairing }
}
