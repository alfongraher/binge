import Foundation
import Combine

@MainActor
final class AddonStore: ObservableObject {
    static let shared=AddonStore()
    private var needsDefaults=false
    private var defaultsTask:Task<Void,Never>?
    @Published var addons: [InstalledAddon] = []
    @Published var error: String?
    private let file: URL
    init() {
        #if os(iOS)
        file=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Binge/addons.json")
        needsDefaults = !FileManager.default.fileExists(atPath:file.path)
        #else
        file=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Drift/addons.json")
        #endif
        do {
            try PrivateDataFile.protectExisting(self.file)
            if FileManager.default.fileExists(atPath: file.path) {
                addons = try JSONDecoder().decode([InstalledAddon].self, from: Data(contentsOf: file))
            }
        } catch { self.error = "Could not load add-ons." }
    }
    func ensureDefaults() async {
        guard needsDefaults else { return }
        if let defaultsTask { await defaultsTask.value;return }
        let task=Task { @MainActor in
            for url in ["https://v3-cinemeta.strem.io/manifest.json","https://torrentio.strem.fun/manifest.json","https://opensubtitles-v3.strem.io/manifest.json"] { await install(url) }
            needsDefaults=false;save()
        }
        defaultsTask=task;await task.value;defaultsTask=nil
    }
    func catalog(type:String="movie")->InstalledAddon? { addons.first { ($0.manifest.catalogs ?? []).contains {$0.type==type} } }
    func readyCatalog(type:String="movie") async throws ->InstalledAddon {
        await ensureDefaults()
        guard let catalog=catalog(type:type) else { throw AddonError.response }
        return catalog
    }
    func readyStreams(type:String,id:String) async throws ->[ListedStream] {
        await ensureDefaults()
        let providers=addons.filter {$0.manifest.supports("stream",type:type,id:id)}
        guard !providers.isEmpty else { throw AddonError.response }
        var streams:[ListedStream]=[],failures=0
        for provider in providers {
            do { streams += try await AddonClient().streams(provider,type:type,id:id) }
            catch { failures+=1 }
            try Task.checkCancellation()
        }
        if streams.isEmpty && failures==providers.count { throw AddonError.response }
        return streams
    }
    func install(_ url: String) async {
        do {
            let addon = try await AddonClient().install(url)
            try Task.checkCancellation()
            addons.removeAll { $0.id == addon.id }
            addons.append(addon); save()
        } catch is CancellationError {} catch { self.error = "Could not install add-on. Check the manifest URL and try again." }
    }
    func refreshCatalogOptions() async {
        // Older cached manifests were encoded before genre options were stored.
        for addon in addons where (addon.manifest.catalogs ?? []).contains(where:{ catalog in
            let supports=(catalog.extraSupported ?? []).contains("genre") || (catalog.extra ?? []).contains {$0.name=="genre"}
            return supports && catalog.extra?.first(where:{$0.name=="genre"})?.options==nil
        }) {
            guard let updated=try? await AddonClient().install(addon.manifestURL.absoluteString),!Task.isCancelled else { continue }
            if let index=addons.firstIndex(where:{$0.id==addon.id}) { addons[index]=updated;save() }
        }
    }
    func remove(_ addon: InstalledAddon) { addons.removeAll { $0.id == addon.id }; save() }
    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PrivateDataFile.write(JSONEncoder().encode(addons),to:file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { self.error = "Could not save add-ons." }
    }
}

