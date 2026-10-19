import Foundation
import CryptoKit

/// Throughput is a conservative observation of torrent transfers, not an ISP speed test.
struct SourcePolicy {
    static func number(_ pattern: String, in text: String) -> Double? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[range])
    }
    static func bytes(_ stream: AddonStream) -> Double? {
        let text = stream.detail
        if let size = number("([0-9]+(?:\\.[0-9]+)?)\\s*G(?:i)?B\\b", in: text) { return size * 1_073_741_824 }
        return number("([0-9]+(?:\\.[0-9]+)?)\\s*M(?:i)?B\\b", in: text).map { $0 * 1_048_576 }
    }
    static func peers(_ stream:AddonStream)->Double? {
        number("(?:👤|👥|seeders?|seeds?|peers?)\\s*[:=]?\\s*([0-9]+)",in:stream.detail)
            ?? number("([0-9]+)\\s*(?:seeders?|seeds?|peers?)",in:stream.detail)
    }
    static func eligible(_ stream:AddonStream,maxBytes:Double?=nil)->Bool {
        guard stream.playableSource != nil,!([stream.name,stream.detail].compactMap {$0}.joined().lowercased().contains("av1")) else { return false }
        if let maxBytes,let size=bytes(stream),size>maxBytes { return false }
        return true
    }
    static func recommendable(_ stream:AddonStream,maxBytes:Double?=nil)->Bool {
        guard eligible(stream,maxBytes:maxBytes) else {return false}
        return stream.playableSource?.hasPrefix("magnet:") != true || peers(stream) != 0
    }
    static func ranked(_ streams:[AddonStream],throughput:Double,duration:Double=5400)->[AddonStream] {
        let profile=SourceConnectionProfile(throughput:throughput)
        let scored:[(index:Int,stream:AddonStream,score:Double)]=streams.enumerated().compactMap { row in
            guard eligible(row.element) else {return nil}
            return (row.offset,row.element,assessment(row.element,profile:profile,duration:duration))
        }
        return scored.sorted {$0.score == $1.score ? $0.index<$1.index : $0.score>$1.score}.map {$0.stream}
    }
    static func ordered(_ sources:[ListedStream],profile:SourceConnectionProfile,duration:Double,maxBytes:Double?=nil)->[ListedStream] {
        let scored:[(index:Int,source:ListedStream,eligible:Bool,score:Double)]=sources.enumerated().map { ($0.offset,$0.element,recommendable($0.element.stream,maxBytes:maxBytes),assessment($0.element.stream,profile:profile,duration:duration)) }
        return scored.sorted {
            if $0.eligible != $1.eligible { return $0.eligible }
            return $0.score == $1.score ? $0.index<$1.index : $0.score>$1.score
        }.map(\.source)
    }
    static func orderedAsync(_ sources:[ListedStream],profile:SourceConnectionProfile,duration:Double,maxBytes:Double?=nil) async ->[ListedStream] {
        await Task.detached(priority:.userInitiated) { ordered(sources,profile:profile,duration:duration,maxBytes:maxBytes) }.value
    }
    static func score(_ stream:AddonStream,throughput:Double,duration:Double)->Double {
        assessment(stream,profile:SourceConnectionProfile(throughput:throughput),duration:duration)
    }
    static func assessment(_ stream:AddonStream,profile:SourceConnectionProfile,duration:Double)->Double {
        let quality:Double=["4K":4,"1080p":3,"720p":2,"SD":1][stream.resolution] ?? 1
        let size=bytes(stream)
        let needed:Double=size.map {$0/max(600,duration)} ?? (["4K":2_500_000.0,"1080p":900_000.0,"720p":450_000.0][stream.resolution] ?? 450_000)
        let budget:Double=profile.throughput>0 ? profile.throughput*max(0.3,0.65-profile.variability*0.3) : 750_000
        let seeds=peers(stream)
        let peerBonus:Double=seeds.map {$0==0 ? -30 : min(15,log2($0+1)*1.7)} ?? -3
        let bandwidthPenalty=max(0,needed/max(1,budget)-1)*55
        let startupPenalty=min(12,log2(1+(size ?? 1_500_000_000)/500_000_000)*2)
        let text=([stream.name,stream.detail].compactMap {$0}).joined(separator:" ").lowercased()
        let formatBonus=(text.contains("aac") ? 2.0 : 0)-(text.contains("truehd") || text.contains("dts") ? 3.0 : 0)
        let outcome=profile.outcomes[SourceExperience.key(stream)]
        let reliabilityPenalty=outcome.map { value in
            let failures=Double(value.failures)/Double(max(1,value.failures+value.successes))*30
            let startupBonus=value.successes>0 ? max(-12,6-value.startup/10) : 0
            return failures-startupBonus
        } ?? 0
        return quality*10+peerBonus+formatBonus-bandwidthPenalty-startupPenalty-reliabilityPenalty
    }
    static func compatible(_ a: AddonStream, _ b: AddonStream) -> Bool {
        let editions = ["extended", "uncut", "director", "theatrical", "remastered"]
        let first = a.detail.lowercased(), second = b.detail.lowercased()
        return editions.allSatisfy { first.contains($0) == second.contains($0) }
    }
    static func matchingRuntime(_ a: Double, _ b: Double) -> Bool { a > 0 && b > 0 && abs(a - b) <= 2 }
}

struct SourceOutcome:Codable,Sendable { var successes=0;var failures=0;var startup=0.0;var updated=Date() }
struct SourceConnectionProfile:Sendable {
    var throughput:Double=0
    var variability:Double=0
    var samples:Int=0
    var outcomes:[String:SourceOutcome]=[:]
}
/// Local measurements describe this device's real transfers, not an ISP speed test.
@MainActor final class SourceExperience {
    static let shared=SourceExperience()
    private let defaults:UserDefaults
    private var lastSample=Date.distantPast
    init(defaults:UserDefaults = .standard) { self.defaults=defaults }
    nonisolated static func key(_ stream:AddonStream)->String {
        let identity=(stream.infoHash ?? stream.url ?? "")+"|"+String(stream.fileIdx ?? -1)
        return SHA256.hash(data:Data(identity.utf8)).map {String(format:"%02x",$0)}.joined()
    }
    var profile:SourceConnectionProfile {
        let recent=Date().timeIntervalSince1970-defaults.double(forKey:"binge.connection.updated")<3600
        let mean=recent ? defaults.double(forKey:"binge.connection.mean") : 0
        let outcomes=(defaults.data(forKey:"binge.source.outcomes").flatMap {try? JSONDecoder().decode([String:SourceOutcome].self,from:$0)} ?? [:]).filter {Date().timeIntervalSince($0.value.updated)<7*86400}
        return SourceConnectionProfile(throughput:mean,variability:mean>0 ? min(1,defaults.double(forKey:"binge.connection.deviation")/mean) : 0,samples:recent ? defaults.integer(forKey:"binge.connection.samples") : 0,outcomes:outcomes)
    }
    func observe(rate:Double) {
        guard rate.isFinite,rate>=32768,Date().timeIntervalSince(lastSample)>=1 else { return }
        lastSample=Date()
        let previous=profile,mean=previous.throughput>0 ? previous.throughput : rate
        defaults.set(mean*0.85+rate*0.15,forKey:"binge.connection.mean")
        defaults.set(previous.throughput>0 ? defaults.double(forKey:"binge.connection.deviation")*0.85+abs(rate-mean)*0.15 : 0,forKey:"binge.connection.deviation")
        defaults.set(min(1000,previous.samples+1),forKey:"binge.connection.samples")
        defaults.set(Date().timeIntervalSince1970,forKey:"binge.connection.updated")
    }
    func record(_ stream:AddonStream,success:Bool,startup:Double=0) {
        let startup=startup.isFinite ? max(0,min(600,startup)) : 600
        var outcomes=profile.outcomes;let key=Self.key(stream);var value=outcomes[key] ?? SourceOutcome()
        if success { value.successes=min(100,value.successes+1);value.startup=value.startup>0 ? value.startup*0.7+startup*0.3 : startup }
        else { value.failures=min(100,value.failures+1) }
        value.updated=Date();outcomes[key]=value
        if outcomes.count>128 { for item in outcomes.sorted(by:{$0.value.updated>$1.value.updated}).dropFirst(128) {outcomes.removeValue(forKey:item.key)} }
        if let data=try? JSONEncoder().encode(outcomes) { defaults.set(data,forKey:"binge.source.outcomes") }
    }
}
