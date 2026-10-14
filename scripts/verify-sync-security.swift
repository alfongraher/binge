import Foundation
import CryptoKit
import Network

@main struct SyncSecurityCheck {
    static func send(_ object:[String:Any],_ connection:NWConnection) async throws {
        let payload=try JSONSerialization.data(withJSONObject:object)
        var count=UInt32(payload.count).bigEndian
        let frame=withUnsafeBytes(of:&count) { Data($0) }+payload
        try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in connection.send(content:frame,completion:.contentProcessed { error in if let error {c.resume(throwing:error)} else {c.resume()} }) }
    }
    static func read(_ size:Int,_ connection:NWConnection) async throws ->Data {
        try await withCheckedThrowingContinuation { c in connection.receive(minimumIncompleteLength:size,maximumLength:size) { data,_,_,error in
            if let error {c.resume(throwing:error)} else if let data,data.count==size {c.resume(returning:data)} else {c.resume(throwing:NSError(domain:"closed",code:1))}
        } }
    }
    static func frame(_ connection:NWConnection) async throws ->[String:Any] {
        let header=try await read(4,connection),size=header.reduce(0) {($0<<8)|Int($1)}
        let bytes=try await read(size,connection)
        return try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
    }
    static func envelope(_ message:[String:Any],key:SymmetricKey,sender:String,recipient:String,counter:UInt64) throws ->[String:Any] {
        let box=try AES.GCM.seal(JSONSerialization.data(withJSONObject:message),using:key,authenticating:Data("\(sender)|\(recipient)|\(counter)".utf8))
        return ["kind":"sealed","counter":counter,"sealed":box.combined!.base64EncodedString()]
    }
    @MainActor static func main() async throws {
        let suite="binge.security.sync."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        let folder=URL(fileURLWithPath:"/private/tmp/binge-security-sync-"+UUID().uuidString)
        defer {defaults.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:folder)}
        let clientID=UUID().uuidString,identity=Curve25519.KeyAgreement.PrivateKey()
        defaults.set(try JSONEncoder().encode([SyncPeer(id:clientID,name:"test peer",publicKey:identity.publicKey.rawRepresentation)]),forKey:"binge.sync.paired")
        let server=LocalSync(defaults:defaults,folder:folder,identity:Curve25519.KeyAgreement.PrivateKey());server.loopbackTest=true
        server.configure(capture:{[]},apply:{_ in});server.enabled=true
        defer {server.enabled=false}
        for _ in 0..<100 { if server.testPort?.rawValue ?? 0>0 {break};try await Task.sleep(for:.milliseconds(20)) }
        guard let port=server.testPort,port.rawValue>0 else {fatalError("Listener not ready")}
        for reflection in [false,true] {
            let connection=NWConnection(host:"127.0.0.1",port:port,using:.tcp);connection.start(queue:.global())
            let hello=try await frame(connection),nonce=Data((0..<16).map {_ in UInt8.random(in:0...255)}),ephemeral=Curve25519.KeyAgreement.PrivateKey()
            let remoteNonce=Data(base64Encoded:hello["nonce"] as! String)!,remoteID=hello["id"] as! String
            let staticPublic=try Curve25519.KeyAgreement.PublicKey(rawRepresentation:Data(base64Encoded:hello["publicKey"] as! String)!)
            let transientPublic=try Curve25519.KeyAgreement.PublicKey(rawRepresentation:Data(base64Encoded:hello["ephemeral"] as! String)!)
            let secret=try identity.sharedSecretFromKeyAgreement(with:staticPublic),transient=try ephemeral.sharedSecretFromKeyAgreement(with:transientPublic)
            let material=secret.withUnsafeBytes {Data($0)}+transient.withUnsafeBytes {Data($0)}
            let key=HKDF<SHA256>.deriveKey(inputKeyMaterial:SymmetricKey(data:material),salt:clientID<remoteID ? nonce+remoteNonce : remoteNonce+nonce,info:Data("binge-sync-v2".utf8),outputByteCount:32)
            try await send(["kind":"hello","version":2,"id":clientID,"name":"test peer","nonce":nonce.base64EncodedString(),"publicKey":identity.publicKey.rawRepresentation.base64EncodedString(),"ephemeral":ephemeral.publicKey.rawRepresentation.base64EncodedString()],connection)
            let approved=try await frame(connection)
            precondition(approved["kind"] as? String=="sealed")
            if reflection {
                // Echo the server's own approval. It must not authenticate the peer.
                try await send(approved,connection)
            } else {
                try await send(envelope(["kind":"approved"],key:key,sender:clientID,recipient:remoteID,counter:1),connection)
                let message=try envelope(["kind":"data","manual":true,"entries":[:]],key:key,sender:clientID,recipient:remoteID,counter:2)
                try await send(message,connection)
                for _ in 0..<100 {if server.lastSync != nil {break};try await Task.sleep(for:.milliseconds(10))}
                precondition(server.lastSync != nil)
                try await send(message,connection) // Exact replay of an accepted frame.
            }
            do {_=try await read(4,connection);fatalError("Reflected/replayed frame did not close connection")}
            catch { connection.cancel() }
        }
        let oversized=NWConnection(host:"127.0.0.1",port:port,using:.tcp);oversized.start(queue:.global())
        _=try await frame(oversized)
        do {try await send(["kind":"hello","padding":String(repeating:"x",count:32768)],oversized)} catch { }
        do {_=try await read(4,oversized);fatalError("Oversized unauthenticated frame accepted")} catch {oversized.cancel()}
        print("PASS: live sync listener rejects reflected approval and repeated authenticated data frames")
    }
}
