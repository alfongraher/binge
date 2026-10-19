import Foundation
@main struct RecommendationCheck {
    static func source(_ resolution:String,_ size:String,_ peers:Int,_ index:Int)->ListedStream {
        ListedStream(addonName:"Fixture",stream:AddonStream(name:resolution,title:"AAC 👤 \(peers) 💾 \(size)",infoHash:String(repeating:String(index),count:40),fileIdx:0))
    }
    @MainActor static func main() async throws {
        for (value,expected) in [("\"43 min\"",2580.0),("120",7200.0),("\"1h 30m\"",5400.0),("\"unknown\"",2700.0)] {
            let data=Data(("{\"id\":\"fixture\",\"type\":\"series\",\"name\":\"Fixture\",\"runtime\":"+value+"}").utf8)
            let title=try JSONDecoder().decode(CatalogTitle.self,from:data)
            precondition(title.estimatedDuration==expected)
        }
        let hd=source("1080p","1.8 GB",100,1),sd=source("720p","0.7 GB",100,2),large=source("4K","12 GB",500,3),empty=source("1080p","1 GB",0,4)
        let list=[large,empty,sd,hd]
        let stable=SourceConnectionProfile(throughput:1_500_000,variability:0)
        let unstable=SourceConnectionProfile(throughput:1_500_000,variability:1)
        precondition(SourcePolicy.ordered(list,profile:stable,duration:2700,maxBytes:2*1024*1024*1024).first?.id==hd.id)
        precondition(SourcePolicy.ordered(list,profile:unstable,duration:2700,maxBytes:2*1024*1024*1024).first?.id==sd.id)
        precondition(!SourcePolicy.recommendable(empty.stream))
        precondition(!SourcePolicy.eligible(large.stream,maxBytes:2*1024*1024*1024))
        var failed=stable;failed.outcomes[SourceExperience.key(hd.stream)]=SourceOutcome(successes:0,failures:2,startup:90)
        precondition(SourcePolicy.ordered(list,profile:failed,duration:2700,maxBytes:2*1024*1024*1024).first?.id==sd.id)
        let unknown=SourcePolicy.ordered([large,empty,hd,sd],profile:SourceConnectionProfile(),duration:2700,maxBytes:2*1024*1024*1024)
        precondition(unknown.first?.id==hd.id)
        let duplicate=ListedStream(addonName:"Tie",stream:hd.stream)
        precondition(SourcePolicy.ordered([duplicate,hd],profile:stable,duration:2700).map(\.id)==[duplicate.id,hd.id])
        let asyncResult=await SourcePolicy.orderedAsync(list,profile:stable,duration:2700,maxBytes:2*1024*1024*1024)
        precondition(asyncResult.first?.id==hd.id)
        let suite="binge.recommendation.check."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        let experience=SourceExperience(defaults:defaults)
        experience.observe(rate:1_000_000)
        precondition(experience.profile.throughput>0 && experience.profile.samples==1)
        defaults.set(Date().addingTimeInterval(-7200).timeIntervalSince1970,forKey:"binge.connection.updated")
        precondition(experience.profile.throughput==0)
        experience.record(hd.stream,success:false)
        precondition(experience.profile.outcomes[SourceExperience.key(hd.stream)]?.failures==1)
        print("PASS: speed/stability tradeoff, peers, iPad size eligibility, source failures, conservative cold start, stable ties, asynchronous ranking, freshness and local outcomes")
    }
}
