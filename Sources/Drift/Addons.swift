import Foundation

struct AddonResource: Codable, Sendable {
    var name: String
    var types: [String]?
    var idPrefixes: [String]?
    var short: Bool
    init(from decoder: Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            self.name = name; types = nil; idPrefixes = nil; short = true
        } else {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            types = try c.decodeIfPresent([String].self, forKey: .types)
            idPrefixes = try c.decodeIfPresent([String].self, forKey: .idPrefixes)
            short = false
        }
    }
    enum CodingKeys: String, CodingKey { case name, types, idPrefixes }
    func encode(to encoder: Encoder) throws {
        if short { var c = encoder.singleValueContainer(); try c.encode(name) }
        else {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(types, forKey: .types)
            try c.encodeIfPresent(idPrefixes, forKey: .idPrefixes)
        }
    }
}
struct AddonCatalog: Codable, Sendable {
    struct Extra: Codable, Sendable { var name: String; var isRequired: Bool?; var options: [String]? }
    var id: String
    var type: String
    var name: String?
    var extra: [Extra]?
    var extraSupported: [String]?
    var extraRequired: [String]?
    var searchable: Bool {
        let required = (extra ?? []).filter { $0.isRequired == true }.map(\.name) + (extraRequired ?? [])
        return ((extra ?? []).contains { $0.name == "search" } || (extraSupported ?? []).contains("search")) && required.allSatisfy { $0 == "search" }
    }
}
struct AddonManifest: Codable, Sendable {
    var id: String
    var name: String
    var version: String
    var types: [String]
    var resources: [AddonResource]
    var idPrefixes: [String]?
    var catalogs: [AddonCatalog]?
    func supports(_ resource: String, type: String, id: String) -> Bool {
        resources.contains {
            guard $0.name == resource, ($0.types ?? types).contains(type) else { return false }
            let prefixes = $0.short ? idPrefixes : $0.idPrefixes
            return prefixes == nil || prefixes!.contains { id.hasPrefix($0) }
        }
    }
}
struct InstalledAddon: Identifiable, Codable, Sendable {
    var id: String { manifestURL.absoluteString }
    var manifestURL: URL
    var manifest: AddonManifest
}
struct CatalogTitle: Decodable, Identifiable, Sendable {
    var id: String
    var type: String
    var name: String
    var poster: URL?
    var description: String?
    var videos: [Episode]?
    var genres: [String]?
    var background: URL?
    var logo: URL?
    var trailers: [Trailer]?
    var trailerStreams: [TrailerStream]?
    struct Trailer: Decodable, Sendable { var source: String?; var type: String? }
    struct TrailerStream: Decodable, Sendable { var ytId: String? }
    var trailerURL: URL? {
        let candidates=(trailerStreams ?? []).compactMap(\.ytId)+(trailers ?? []).compactMap(\.source)
        guard let id=candidates.first(where: { $0.count==11 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0=="_" || $0=="-") } }) else { return nil }
        return URL(string:"https://www.youtube.com/watch?v=\(id)")
    }
    struct Episode: Decodable, Identifiable, Sendable {
        var id: String
        var title: String?
        var name: String?
        var thumbnail: URL?
        var released: String?
        var season: Int?
        var episode: Int?
        var label: String { "S\(season ?? 0) E\(episode ?? 0) · \(title ?? name ?? "Episode \(episode ?? 0)")" }
    }
}
struct AddonStream: Codable, Sendable {
    struct Hints: Codable, Sendable {
        var filename: String?
        var bingeGroup: String?
        var notWebReady: Bool?
    }
    var name: String?
    var title: String?
    var description: String?
    var url: String?
    var infoHash: String?
    var fileIdx: Int?
    var sources: [String]?
    var behaviorHints: Hints?
    var subtitles: [SubtitleOption]?
    var detail: String { description ?? title ?? behaviorHints?.filename ?? "Source" }
    var resolution: String {
        let text = [name, title, description, behaviorHints?.filename].compactMap { $0 }.joined(separator: " ").lowercased()
        for (pattern, label) in [
            (#"(?<![a-z0-9])(2160p?|4k|uhd)(?![a-z0-9])"#, "4K"),
            (#"(?<![a-z0-9])(1080[pi]?|fhd)(?![a-z0-9])"#, "1080p"),
            (#"(?<![a-z0-9])720p?(?![a-z0-9])"#, "720p"),
            (#"(?<![a-z0-9])(480p?|576p?|sd)(?![a-z0-9])"#, "SD")
        ] where text.range(of: pattern, options: .regularExpression) != nil { return label }
        return "Unknown"
    }
    var playableSource: String? {
        if let url, let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme ?? ""), parsed.host != nil { return url }
        guard let infoHash, infoHash.count == 40, infoHash.allSatisfy({ $0.isHexDigit }) else { return nil }
        var c = URLComponents(); c.scheme = "magnet"
        c.queryItems = [URLQueryItem(name: "xt", value: "urn:btih:\(infoHash)")]
        for tracker in sources ?? [] where tracker.hasPrefix("tracker:") {
            c.queryItems?.append(URLQueryItem(name: "tr", value: String(tracker.dropFirst(8))))
        }
        return c.string
    }
}
struct ListedStream: Identifiable, Sendable {
    var id = UUID()
    var addonName: String
    var stream: AddonStream
}
struct FoundTitle: Identifiable, Sendable {
    var id: String { "\(title.type):\(title.id)" }
    var title: CatalogTitle
    var addon: InstalledAddon
}

enum AddonError: Error, LocalizedError {
    case invalidURL, response, data
    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter an HTTP(S) manifest.json URL without a query or fragment."
        case .response: "The add-on did not return a successful response."
        case .data: "The add-on returned invalid or unsupported data."
        }
    }
}
struct AddonClient: Sendable {
    static let networkSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }()
    var session: URLSession = networkSession
    static func manifestURL(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme ?? ""), url.host != nil,
              url.lastPathComponent == "manifest.json", url.query == nil, url.fragment == nil else { throw AddonError.invalidURL }
        return url
    }
    static func endpoint(_ manifest: URL, components: [String]) -> URL {
        var result = manifest.deletingLastPathComponent()
        for part in components { result.appendPathComponent(part) }
        return result
    }
    func fetch<T: Decodable & Sendable>(_ type: T.Type, url: URL) async throws -> T {
        var request = URLRequest(url: url); request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw AddonError.response }
        do { return try JSONDecoder().decode(type, from: data) } catch { throw AddonError.data }
    }
    func install(_ text: String) async throws -> InstalledAddon {
        let url = try Self.manifestURL(text)
        let manifest = try await fetch(AddonManifest.self, url: url)
        guard !manifest.id.isEmpty, !manifest.name.isEmpty, !manifest.resources.isEmpty else { throw AddonError.data }
        return InstalledAddon(manifestURL: url, manifest: manifest)
    }
    func search(_ addon: InstalledAddon, catalog: AddonCatalog, query: String) async throws -> [FoundTitle] {
        struct Response: Decodable, Sendable { var metas: [CatalogTitle] }
        let escaped = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        // The extra argument is already encoded; assigning the encoded path avoids encoding '%' twice.
        var url = URLComponents(url: Self.endpoint(addon.manifestURL, components: ["catalog", catalog.type, catalog.id]), resolvingAgainstBaseURL: false)!
        url.percentEncodedPath += "/search=\(escaped).json"
        let response = try await fetch(Response.self, url: url.url!)
        return response.metas.map { FoundTitle(title: $0, addon: addon) }
    }
    func browse(_ addon: InstalledAddon, catalog: AddonCatalog, skip:Int=0) async throws -> [FoundTitle] {
        try await page(addon,catalog:catalog,genre:nil,skip:skip)
    }
    func recommendations(_ addon: InstalledAddon, catalog: AddonCatalog, genre: String, skip:Int=0) async throws -> [FoundTitle] {
        try await page(addon,catalog:catalog,genre:genre,skip:skip)
    }
    func browsePage(_ addon:InstalledAddon,catalog:AddonCatalog,genre:String?,skip:Int) async throws ->[FoundTitle] { try await page(addon,catalog:catalog,genre:genre,skip:skip) }
    private func page(_ addon:InstalledAddon,catalog:AddonCatalog,genre:String?,skip:Int) async throws ->[FoundTitle] {
        struct Response:Decodable,Sendable { var metas:[CatalogTitle] }
        var url=URLComponents(url:Self.endpoint(addon.manifestURL,components:["catalog",catalog.type,catalog.id]),resolvingAgainstBaseURL:false)!
        var extras:[String]=[]
        if let genre { extras.append("genre="+(genre.addingPercentEncoding(withAllowedCharacters:.alphanumerics) ?? "")) }
        if skip>0 { extras.append("skip=\(skip)") }
        url.percentEncodedPath += extras.isEmpty ? ".json" : "/"+extras.joined(separator:"&")+".json"
        return try await fetch(Response.self,url:url.url!).metas.map { FoundTitle(title:$0,addon:addon) }
    }
    func metadata(_ title: FoundTitle) async throws -> CatalogTitle {
        struct Response: Decodable, Sendable { var meta: CatalogTitle }
        return try await fetch(Response.self, url: Self.endpoint(title.addon.manifestURL, components: ["meta", title.title.type, title.title.id + ".json"])).meta
    }
    func streams(_ addon: InstalledAddon, type: String, id: String) async throws -> [ListedStream] {
        struct Response: Decodable, Sendable { var streams: [AddonStream] }
        return try await fetch(Response.self, url: Self.endpoint(addon.manifestURL, components: ["stream", type, id + ".json"])).streams.map {
            ListedStream(addonName: addon.manifest.name, stream: $0)
        }
    }
}

actor CatalogPopularity {
    static let shared = CatalogPopularity()
    nonisolated static func ranked(_ titles: [FoundTitle], ranks: [String: Int]) -> [FoundTitle] {
        titles.enumerated().sorted {
            let left = ranks[$0.element.id] ?? 0, right = ranks[$1.element.id] ?? 0
            return left == right ? $0.offset < $1.offset : left > right
        }.map(\.element)
    }
    private var cache: [String: (Date, [String: Int])] = [:]
    func ranks(_ addon: InstalledAddon) async -> [String: Int] {
        if let cached = cache[addon.id], Date().timeIntervalSince(cached.0) < 900 { return cached.1 }
        struct Response: Decodable, Sendable { var metas: [CatalogTitle] }
        var result: [String: Int] = [:]
        for type in ["movie", "series"] {
            guard let catalog = addon.manifest.catalogs?.first(where: { $0.type == type && ($0.id == "top" || $0.name?.localizedCaseInsensitiveContains("popular") == true) && ($0.extraRequired ?? []).isEmpty && !($0.extra ?? []).contains { $0.isRequired == true } }) else { continue }
            if let data = try? await AddonClient().fetch(Response.self, url: AddonClient.endpoint(addon.manifestURL, components: ["catalog", type, catalog.id + ".json"])) {
                for (index, title) in data.metas.enumerated() { result[type + ":" + title.id] = max(1, 10000 - index) }
            }
        }
        cache[addon.id] = (Date(), result)
        return result
    }
}

/// Catalogs do not supply credit timestamps; use a bounded end-of-video estimate.
enum CreditsTiming {
    static func reached(position:Double,duration:Double,type:String)->Bool {
        guard position.isFinite,duration.isFinite,duration>0 else { return false }
        let window=min(duration*0.05,type=="movie" ? 180.0 : 60.0)
        return position>=duration-window
    }
}
