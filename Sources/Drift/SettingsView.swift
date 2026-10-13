import SwiftUI

@MainActor final class BingeSettingsPresentation:ObservableObject { @Published var presented=false }
struct BingeSettingsView:View {
    @EnvironmentObject private var sync:LocalSync
    @EnvironmentObject private var addons:AddonStore
    @State private var expanded=true
    @State private var manifest=""
    @State private var busy=false
    var body:some View {
        Form {
            Section("Device sync") {
                TextField("This device’s name",text:$sync.name)
                Toggle("Local network sync",isOn:$sync.enabled)
                Text("Pair your devices once, then sync when binge is open on the same network. No account or server required.").font(.caption).foregroundStyle(.secondary)
                if sync.enabled {
                    Toggle("Sync automatically",isOn:$sync.automatic)
                    Toggle("Progress and watched episodes",isOn:$sync.syncHistory)
                    Toggle("Library, favourites and labels",isOn:$sync.syncLibrary)
                    HStack { Text(sync.status).foregroundStyle(.secondary);Spacer();Button("Sync now") { sync.syncNow() }.disabled(sync.paired.isEmpty) }
                    if let date=sync.lastSync { Text("Last synced \(date.formatted(date:.omitted,time:.shortened))").font(.caption).foregroundStyle(.secondary) }
                }
                Text("Video downloads, local files and add-ons stay on this device. On iPad, syncing pauses when binge is in the background.").font(.caption).foregroundStyle(.secondary)
            }
            if sync.enabled {
                ForEach(sync.requests) { request in
                    Section("Pair with \(request.name)") {
                        Text(request.code).font(.system(size:32,weight:.semibold,design:.monospaced)).tracking(4)
                        Text("Check that this code is identical on both screens. Confirm on both devices to pair them.").font(.callout)
                        HStack {
                            Button(request.confirmed ? "Waiting for the other device" : "Codes match") { sync.confirm(request.id) }.disabled(request.confirmed).buttonStyle(.borderedProminent)
                            Button("Cancel") { sync.cancel(request.id) }
                        }
                    }
                }
                Section("Paired devices") {
                    if sync.paired.isEmpty { Text("No devices paired yet").foregroundStyle(.secondary) }
                    ForEach(sync.paired) { peer in
                        HStack { Label(peer.name,systemImage:"checkmark.shield");Spacer();Text(sync.nearby.contains(where:{$0.id==peer.id}) ? "Nearby" : "Offline").foregroundStyle(.secondary);Button("Forget") { sync.forget(peer) } }
                    }
                }
                Section("Nearby devices") {
                    if sync.nearby.isEmpty { Text("Open Settings in binge on your other device and enable local network sync.").foregroundStyle(.secondary) }
                    ForEach(sync.nearby.filter {peer in !sync.paired.contains {$0.id==peer.id}}) { peer in
                        HStack { Label(peer.name,systemImage:"desktopcomputer");Spacer();Button("Pair") { sync.pair(peer) } }
                    }
                }
            }
            Section("Add-ons") {
                DisclosureGroup("Catalogs, sources and subtitles",isExpanded:$expanded) {
                    ForEach(addons.addons) { addon in
                        HStack {
                            VStack(alignment:.leading,spacing:4) { Text(addon.manifest.name).font(.headline);Text(addon.manifest.resources.map(\.name).joined(separator:" · ")).font(.caption).foregroundStyle(.secondary) }
                            Spacer();Button("Remove") { addons.remove(addon) }.disabled(busy)
                        }
                    }
                    TextField("Manifest URL",text:$manifest)
                        #if os(iOS)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        #endif
                    Button(busy ? "Connecting…" : "Connect add-on") { connect(manifest) }.disabled(busy)
                    HStack {
                        Button("Cinemeta") { connect("https://v3-cinemeta.strem.io/manifest.json") }
                        Button("Torrentio") { connect("https://torrentio.strem.fun/manifest.json") }
                        Button("OpenSubtitles") { connect("https://opensubtitles-v3.strem.io/manifest.json") }
                    }.disabled(busy)
                    if let error=addons.error { Text(error).foregroundStyle(.secondary) }
                }
            }
        }.formStyle(.grouped)
        #if os(macOS)
        .frame(maxWidth:850).frame(maxWidth:.infinity)
        #endif
    }
    private func connect(_ text:String) { guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { addons.error="Paste an add-on manifest URL above, then connect.";return };busy=true;addons.error=nil;Task { await addons.install(text);busy=false;if addons.error==nil { manifest="" } } }
}
#if os(iOS)
struct IPadSettingsButton:View {
    @EnvironmentObject private var presentation:BingeSettingsPresentation
    var body:some View { Button { presentation.presented=true } label: { Image(systemName:"gearshape").font(.body) }.accessibilityLabel("Settings") }
}
#endif
