import Foundation
final class OversizedResponse:URLProtocol,@unchecked Sendable {
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        let response=HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:[:])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data(repeating:65,count:16384))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct NetworkSecurityCheck {
    static func main() async throws {
        precondition(!AddonClient.allowedNetworkURL(URL(string:"http://provider.example/manifest.json")!))
        precondition(!AddonClient.allowedNetworkURL(URL(string:"https://name:password@provider.example/manifest.json")!))
        precondition(!AddonClient.allowedNetworkURL(URL(string:"file:///etc/passwd")!))
        precondition(AddonClient.allowedNetworkURL(URL(string:"http://127.0.0.1/manifest.json")!))
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[OversizedResponse.self]
        let session=URLSession(configuration:config);defer {session.invalidateAndCancel()}
        let original=URL(string:"https://fixture.example/start")!
        let redirectResponse=HTTPURLResponse(url:original,statusCode:302,httpVersion:"HTTP/1.1",headerFields:[:])!
        let task=session.dataTask(with:original)
        let redirected:URLRequest?=await withCheckedContinuation { continuation in
            SecureAddonRedirects.shared.urlSession(session,task:task,willPerformHTTPRedirection:redirectResponse,newRequest:URLRequest(url:URL(string:"http://127.0.0.1/private")!),completionHandler:{ continuation.resume(returning:$0) })
        }
        precondition(redirected==nil);task.cancel()
        let client=AddonClient(session:session)
        do { _=try await client.boundedData(URLRequest(url:URL(string:"https://fixture.example/large")!),limit:1024);fatalError("Oversized chunked response accepted") }
        catch AddonError.oversized { }
        var journal=SyncJournal()
        let field=SyncField(value:SyncJournal.data(true),stamp:SyncStamp(clock:1,author:"fixture"))
        _=journal.merge(["library|movie|fixture":["unknown":field,"member":field]],history:true,library:true)
        precondition(journal.entries["library|movie|fixture"]?["unknown"]==nil)
        precondition(journal.entries["library|movie|fixture"]?["member"] != nil)
        let file=URL(fileURLWithPath:"/private/tmp/binge-private-check-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:file)}
        try PrivateDataFile.write(Data("private".utf8),to:file)
        try PrivateDataFile.write(Data("updated".utf8),to:file)
        let attributes=try FileManager.default.attributesOfItem(atPath:file.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue==0o600)
        print("PASS: insecure/credential/file URLs rejected, localhost opt-in, oversized unknown-length response rejected, unknown sync fields rejected")
    }
}
