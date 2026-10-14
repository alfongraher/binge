import Foundation

struct SubtitleOption: Codable, Identifiable, Sendable {
    var id: String
    var url: URL
    var lang: String
    var label: String?
    var displayName: String { label ?? (Locale.current.localizedString(forLanguageCode: lang) ?? lang) }
}
struct SubtitleCue: Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
}
enum SubtitleParser {
    static func time(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        let fields = parts.compactMap { Double($0) }
        guard fields.count == parts.count, fields.allSatisfy({ $0.isFinite && $0 >= 0 }), fields.count == 2 || fields.count == 3 else { return nil }
        return fields.count == 3 ? fields[0] * 3600 + fields[1] * 60 + fields[2] : fields[0] * 60 + fields[1]
    }
    static func parse(_ text: String) -> [SubtitleCue] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var result: [SubtitleCue] = []; var index = 0
        while index < lines.count {
            let line = lines[index]; index += 1
            guard line.contains("-->") else { continue }
            let times = line.components(separatedBy: "-->")
            guard times.count == 2, let start = time(times[0]), let end = time(String(times[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "")), end >= start else { continue }
            var body: [String] = []
            while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty { body.append(lines[index]); index += 1 }
            let clean = body.joined(separator: "\n").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            if !clean.isEmpty { result.append(SubtitleCue(start: start, end: end, text: clean)) }
        }
        return result.sorted { $0.start < $1.start }
    }
    static func active(_ cues: [SubtitleCue], time: Double, delay: Double) -> String {
        let adjusted = time - delay
        return cues.filter { $0.start <= adjusted && adjusted < $0.end }.map(\.text).joined(separator: "\n")
    }
}
extension AddonClient {
    func subtitles(_ addon: InstalledAddon, type: String, id: String) async throws -> [SubtitleOption] {
        struct Response: Decodable, Sendable { var subtitles: [SubtitleOption] }
        return try await fetch(Response.self, url: Self.endpoint(addon.manifestURL, components: ["subtitles", type, id + ".json"])).subtitles
    }
    func subtitleFile(_ option: SubtitleOption) async throws -> [SubtitleCue] {
        guard AddonClient.allowedNetworkURL(option.url) else { throw AddonError.data }
        var request = URLRequest(url: option.url); request.timeoutInterval = 20
        let (data, _) = try await boundedData(request)
        try Task.checkCancellation()
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else { throw AddonError.data }
        let cues = SubtitleParser.parse(text)
        guard !cues.isEmpty else { throw AddonError.data }
        return cues
    }
}
