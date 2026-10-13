import Foundation

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
    static func ranked(_ streams: [AddonStream], throughput: Double, duration: Double = 5400) -> [AddonStream] {
        streams.enumerated().filter { $0.element.playableSource != nil && !$0.element.detail.lowercased().contains("av1") }.sorted {
            let a = score($0.element, throughput: throughput, duration: duration)
            let b = score($1.element, throughput: throughput, duration: duration)
            return a == b ? $0.offset < $1.offset : a > b
        }.map(\.element)
    }
    static func score(_ stream: AddonStream, throughput: Double, duration: Double) -> Double {
        let quality: Double = ["4K": 4, "1080p": 3, "720p": 2, "SD": 1][stream.resolution] ?? 1
        let defaults: [String: Double] = ["4K": 2_500_000, "1080p": 900_000, "720p": 450_000]
        let needed: Double = bytes(stream).map { $0 / max(1, duration) } ?? (defaults[stream.resolution] ?? 450_000)
        let budget = throughput > 0 ? throughput * 0.65 : 750_000
        let seeds = number("👤\\s*([0-9]+)", in: stream.detail) ?? 0
        let peerBonus: Double = min(10.0, log2(seeds + 1.0))
        let penalty: Double = max(0.0, needed / budget - 1.0) * 45.0
        return quality * 10.0 + peerBonus - penalty
    }
    static func compatible(_ a: AddonStream, _ b: AddonStream) -> Bool {
        let editions = ["extended", "uncut", "director", "theatrical", "remastered"]
        let first = a.detail.lowercased(), second = b.detail.lowercased()
        return editions.allSatisfy { first.contains($0) == second.contains($0) }
    }
    static func matchingRuntime(_ a: Double, _ b: Double) -> Bool { a > 0 && b > 0 && abs(a - b) <= 2 }
}
