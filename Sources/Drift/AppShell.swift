import SwiftUI

enum DriftTheme {
    static let background = Color(red: 0.055, green: 0.06, blue: 0.08)
    static let accent = Color(red: 0.96, green: 0.77, blue: 0.36)
}

struct DriftShell: View {
    @StateObject private var chrome = PlayerChrome()
    @FocusState private var searchFocused: Bool
    @StateObject private var addons = AddonStore.shared
    @StateObject private var sync=LocalSync.shared
    @EnvironmentObject private var library:LibraryStore
    @StateObject private var history = WatchHistory()
    @ViewState<Bool> private var launching = true
    @ViewState<String> private var tab = "Home"
    @ViewState<String> private var query = ""
    @ViewState<Int> private var submission = 0
    var body: some View {
        ZStack {
        ZStack(alignment: .top) {
            Group {
                switch tab {
                case "Home": HomeView(discover: { tab = "Explore" }, openAddons: { tab = "Settings" })
                case "Explore": DiscoverView(query: $query, submission: submission, home: false, openAddons: { tab = "Settings" })
                case "Library": LibraryView(query: $query, explore:{tab="Explore"}, openAddons:{tab="Settings"})
                default: BingeSettingsView()
                }
            }.padding(.top, chrome.playing ? 0 : 76).frame(maxWidth: .infinity, maxHeight: .infinity).environmentObject(addons).environmentObject(history).environmentObject(chrome).environmentObject(sync)
            if !chrome.playing {
            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    ForEach(["Home", "Explore", "Library", "Settings"], id: \.self) { item in
                        Button { tab = item; if item != "Library" { query = "" } } label: {
                            Text(item).font(.system(size: 13, weight: .medium))
                                .foregroundStyle(tab == item ? Color.white : Color.secondary)
                                .padding(.horizontal, 16).padding(.vertical, 10)
                                .background(tab == item ? Color.white.opacity(0.09) : Color.clear, in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }
                Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 22)
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(tab == "Library" ? "Search your library" : "Search movies and series", text: $query)
                        .textFieldStyle(.plain).focused($searchFocused).onSubmit {
                            if tab != "Library" { tab = "Explore"; submission += 1 }
                        }
                    if !query.isEmpty { Button { query = ""; submission += 1 } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
                }.padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(width: 260).background(.white.opacity(0.055), in: Capsule())
            }.padding(7).background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
                .padding(.top, 16).padding(.bottom, 10)
                .opacity(chrome.playing && !chrome.visible ? 0 : 1).allowsHitTesting(!chrome.playing || chrome.visible)
                .zIndex(1)
            }

        }
        if launching {
            VStack(spacing: 16) {
                Image(systemName: "play.circle.fill").font(.system(size: 54, weight: .light)).foregroundStyle(DriftTheme.accent)
                Text("binge").font(.system(size: 34, weight: .semibold, design: .rounded)).tracking(-1)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(DriftTheme.background).transition(.opacity).allowsHitTesting(false)
        }
        }.onReceive(history.$records.dropFirst()) { _ in sync.localChanged() }
        .onReceive(library.$items.dropFirst()) { _ in sync.localChanged() }
        .onAppear { sync.configure(capture:{MacSyncAdapter.snapshot(history:history,library:library)},apply:{MacSyncAdapter.apply($0,history:history,library:library)}) }
        .onChange(of: chrome.playing) { _, playing in if playing { searchFocused = false; NSApp.keyWindow?.makeFirstResponder(nil) } }.onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in PlaybackSession.shared.stop() }.task { try? await Task.sleep(for: .seconds(2)); withAnimation(.easeOut(duration: 0.5)) { launching = false } }.background(chrome.playing && !chrome.visible ? Color.black : DriftTheme.background).tint(DriftTheme.accent).preferredColorScheme(.dark)
    }
}

struct PosterCard: View {
    var title: String
    var subtitle: String
    var url: URL?
    var watched = false
    var homeType: String? = nil
    var posterHeight: CGFloat = 218
    @ViewState<Bool> private var hovering = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                Color.clear.frame(height: posterHeight)
                    .overlay {
                        GeometryReader { geometry in
                            ZStack {
                                LinearGradient(colors: [DriftTheme.accent.opacity(0.16), .white.opacity(0.035)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                Image(systemName: "film").foregroundStyle(.secondary)
                                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color.clear }
                            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        }
                    }.clipShape(RoundedRectangle(cornerRadius: 12))
                if watched { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).padding(8).background(DriftTheme.accent, in: Circle()).foregroundStyle(.black).padding(9) }
                if let homeType { HomeTypeTag(type:homeType).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).padding(8) }
            }.overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hovering ? DriftTheme.accent.opacity(0.8) : .white.opacity(0.07), lineWidth: 1))
            if !title.isEmpty {
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(2).frame(height: 34, alignment: .topLeading).foregroundStyle(.primary)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.onHover { hovering = $0 }.contentShape(Rectangle())
    }
}

struct DriftEmptyState: View {
    var icon: String
    var title: String
    var detail: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 38, weight: .ultraLight)).foregroundStyle(DriftTheme.accent)
            Text(title).font(.system(size: 22, weight: .semibold, design: .rounded))
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 400)
        }.frame(maxWidth: .infinity).padding(.vertical, 80)
    }
}

struct AddonsView: View {
    @EnvironmentObject private var store: AddonStore
    @ViewState<String> private var manifest = "https://torrentio.strem.fun/manifest.json"
    @ViewState<Bool> private var busy = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 18) {
                    Label("Connect an add-on", systemImage: "puzzlepiece.extension").font(.headline)
                    HStack {
                        TextField("Paste a manifest URL", text: $manifest).textFieldStyle(.roundedBorder)
                        Button(busy ? "Connecting…" : "Connect") { connect(manifest) }.buttonStyle(.borderedProminent).disabled(busy || manifest.isEmpty)
                    }
                    HStack {
                        Button("Connect Cinemeta catalog") { connect("https://v3-cinemeta.strem.io/manifest.json") }.buttonStyle(.bordered).disabled(busy)
                        Text("Movie and series discovery").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Connect OpenSubtitles") { connect("https://opensubtitles-v3.strem.io/manifest.json") }.buttonStyle(.bordered).disabled(busy)
                    if let error = store.error { Text(error).font(.callout).foregroundStyle(.orange) }
                }.padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                Text("Your add-ons").font(.title3.weight(.semibold))
                ForEach(store.addons) { addon in
                    HStack(spacing: 16) {
                        Image(systemName: addon.manifest.catalogs?.isEmpty == false ? "film.stack" : "link").font(.title2).foregroundStyle(DriftTheme.accent).frame(width: 44)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(addon.manifest.name).font(.headline)
                            Text(addon.manifest.resources.map(\.name).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("Connected").font(.caption).foregroundStyle(DriftTheme.accent)
                        Button("Remove") { store.remove(addon) }.buttonStyle(.borderless).foregroundStyle(.secondary).disabled(busy)
                    }.padding(20).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                }
            }.frame(maxWidth: 820, alignment: .leading).padding(40).frame(maxWidth: .infinity)
        }
    }
    private func connect(_ url: String) {
        busy = true; store.error = nil
        Task { await store.install(url); busy = false }
    }
}
