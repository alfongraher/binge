import Foundation
@main struct SourcePolicyChecks {
    static func stream(_ name: String, _ detail: String, hash: String) throws -> AddonStream {
        try JSONDecoder().decode(AddonStream.self, from: JSONSerialization.data(withJSONObject: ["name": name, "title": detail, "infoHash": hash]))
    }
    static func main() throws {
        let hd = try stream("1080p", "Movie 1080p 👤 200 💾 2 GB", hash: String(repeating: "a", count: 40))
        let uhd = try stream("4K", "Movie 2160p 👤 100 💾 20 GB", hash: String(repeating: "b", count: 40))
        assert(SourcePolicy.ranked([uhd, hd], throughput: 1_000_000).first?.infoHash == hd.infoHash)
        assert(SourcePolicy.ranked([hd, uhd], throughput: 12_000_000).first?.infoHash == uhd.infoHash)
        assert(SourcePolicy.bytes(hd) == 2 * 1_073_741_824)
        let extended = try stream("1080p", "Movie extended 1080p", hash: String(repeating: "c", count: 40))
        assert(!SourcePolicy.compatible(hd, extended))
        assert(SourcePolicy.matchingRuntime(5400, 5401))
        assert(!SourcePolicy.matchingRuntime(5400, 5450))
        assert(!SourcePolicy.matchingRuntime(0, 0))
        print("Source ranking, bandwidth budget, edition and runtime safety checks passed.")
    }
}
