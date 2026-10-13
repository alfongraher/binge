import SwiftUI
import AVKit

struct PlaybackView: View {
    var selection: PlaybackSelection
    @ViewState<PlaybackSelection?> private var playingSelection = nil
    private var currentSelection: PlaybackSelection { playingSelection ?? selection }
    @ViewState<PlaybackSelection?> private var upcomingSelection = nil
    @ViewState<Task<Void, Never>?> private var episodeTask = nil
    @ViewState<Task<Void, Never>?> private var countdownTask = nil
    @ViewState<Int> private var countdown = 10
    @ViewState<Bool> private var autoplayCancelled = false
    @ViewState<String?> private var episodeError = nil
    var close: () -> Void
    var selectEpisode: ((CatalogTitle.Episode) -> Void)? = nil
    @ViewState<Bool> private var showEpisodes = false
    @ViewState<[CatalogTitle.Episode]> private var playerEpisodes = []
    @StateObject private var session = PlaybackSession.shared
    @EnvironmentObject private var chrome: PlayerChrome
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var history: WatchHistory
    @ViewState<Double> private var lastHistorySave = 0
    @ViewState<Double> private var volume = 1
    @ViewState<Bool> private var muted = false
    @ViewState<Bool> private var showVolume = false
    @ViewState<Double> private var scrub = 0
    @ViewState<Bool> private var scrubbing = false
    @ViewState<Bool> private var showSubtitles = false
    @ViewState<[SubtitleOption]> private var subtitleOptions = []
    @ViewState<String> private var subtitleID = "off"
    @ViewState<String> private var subtitleLanguage = "eng"
    @ViewState<String?> private var subtitleMessage: String?
    @ViewState<Bool> private var searchingSubtitles = false
    @ViewState<Double> private var subtitleDelay = 0
    @ViewState<Task<Void, Never>?> private var subtitleTask: Task<Void, Never>?
    private var languageOptions: [SubtitleOption] {
        subtitleOptions.filter { subtitleLanguage == "all" || $0.lang == subtitleLanguage || (subtitleLanguage == "eng" && $0.lang == "en") || (subtitleLanguage == "spa" && $0.lang == "es") }
    }
    private var loader: some View {
        CoverLoadingView(poster: currentSelection.poster, title: currentSelection.title, message: session.message,
                         progress: session.bufferProgress, peers: session.peers, rate: session.rate)
    }

    var body: some View {
        ZStack {
            if session.failed {
                DriftEmptyState(icon: "exclamationmark.triangle", title: "Couldn’t start this source", detail: session.message)
                Button("Try again") { session.start(currentSelection) }.buttonStyle(.borderedProminent)
            } else if let player = session.player {
                ZStack {
                    NativePlayerView(player: player, showsControls: false).opacity(session.readyToPlay ? 1 : 0)
                    if !session.readyToPlay { loader }
                    if session.readyToPlay && !session.subtitleText.isEmpty {
                        VStack { Spacer(); Text(session.subtitleText).font(.system(size: 24, weight: .semibold)).multilineTextAlignment(.center).foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 8).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8)).padding(.bottom, chrome.visible ? 120 : 30).padding(.horizontal, 32) }.allowsHitTesting(false)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black).clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                loader.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            VStack {
                playerHeader.padding(.top, 12)
                Spacer()
                if session.duration > 0 && !session.failed { controls.opacity(chrome.visible ? 1 : 0).allowsHitTesting(chrome.visible) }
            }.padding(20)


        }.overlay(alignment: .bottomTrailing) { upNextCard }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(chrome.visible ? DriftTheme.background : .black)
         .onAppear { chrome.begin(); session.start(currentSelection); subtitleOptions = currentSelection.stream.subtitles ?? []; playerEpisodes = currentSelection.episodes }
        .task(id: currentSelection.id) {
            guard currentSelection.contentType == "series", playerEpisodes.isEmpty, let id = EpisodePlayback.seriesID(currentSelection.contentID) else { return }
            let baseID = String(id)
            guard let addon = addons.addons.first(where: { $0.manifest.supports("meta", type: "series", id: baseID) }) else { return }
            if let meta = try? await AddonClient().metadata(FoundTitle(title: CatalogTitle(id: baseID, type: "series", name: currentSelection.seriesTitle ?? currentSelection.title), addon: addon)), !Task.isCancelled { playerEpisodes = meta.videos ?? [] }
        }
        .onReceive(NotificationCenter.default.publisher(for: .driftVolumeChanged)) { _ in volume = Double(session.player?.volume ?? 1); muted = false }
        .onChange(of: showSubtitles) { _, value in chrome.pinned = value || showEpisodes || showVolume; chrome.activity() }
        .onChange(of: showEpisodes) { _, value in chrome.pinned = value || showSubtitles || showVolume; chrome.activity() }
        .onChange(of: showVolume) { _, value in chrome.pinned = value || showSubtitles || showEpisodes; chrome.activity() }
        .onChange(of: playerEpisodes.count) { _, _ in if session.finished { prepareUpcomingEpisode(); beginCountdown() } }
        .onChange(of: session.finished) { _, ended in if ended { saveHistory(); chrome.pinned = true; chrome.activity(); prepareUpcomingEpisode(); beginCountdown() } else { countdownTask?.cancel(); countdownTask = nil; chrome.pinned = false; chrome.activity() } }
        .onChange(of: session.failed) { _, failed in if failed { chrome.pinned = true; chrome.activity() } }
        .onChange(of: session.readyToPlay) { _, ready in if ready { session.player?.volume = Float(volume); session.player?.isMuted = muted; if let player = session.player { FloatingPlayer.shared.update(player) } } }
        .onChange(of: session.position) { _, value in
            if !scrubbing { scrub = value }
            if session.duration > 0 && session.duration - value <= 120 { prepareUpcomingEpisode() }
            if abs(value - lastHistorySave) >= 10 { saveHistory(); lastHistorySave = value }
        }
        .onChange(of: subtitleLanguage) { _, _ in subtitleID = "off" }
        .onChange(of: subtitleID) { _, _ in loadSubtitle() }
        .onChange(of: subtitleDelay) { _, value in session.subtitleDelay = value; session.subtitleText = SubtitleParser.active(session.cues, time: session.position, delay: value) }
        .onDisappear { FloatingPlayer.shared.close(); chrome.end(); saveHistory(); if CreditsTiming.reached(position:session.position,duration:session.duration,type:currentSelection.contentType),let next=upcomingSelection { history.queueNext(next) }; subtitleTask?.cancel(); episodeTask?.cancel(); countdownTask?.cancel(); session.retainLast() }
    }
    private var playerHeader: some View {
            HStack(spacing: 20) {
                Button { saveHistory(); session.retainLast(); close() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold)).frame(width: 38, height: 38).background(.regularMaterial, in: Circle())
                }.buttonStyle(.plain).help("Back to sources")
                VStack(alignment: .leading, spacing: 6) {
                    Text(currentSelection.title).font(.title2.weight(.semibold))
                    Text((session.currentStream ?? currentSelection.stream).resolution + " · " + ((session.currentStream ?? currentSelection.stream).name ?? "Selected source")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()


            }
            .opacity(chrome.visible ? 1 : 0).allowsHitTesting(chrome.visible)
    }
    private var nextEpisode: CatalogTitle.Episode? { EpisodePlayback.next(after: currentSelection.contentID, episodes: playerEpisodes) }
    @ViewBuilder private var upNextCard: some View {
        if !autoplayCancelled, !session.failed, (session.finished || (session.duration > 0 && session.duration - session.position <= 60)), let episode = nextEpisode {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    AsyncImage(url: episode.thumbnail ?? currentSelection.poster) { image in image.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.08) }
                        .frame(width: 88, height: 54).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("UP NEXT").font(.system(size: 9, weight: .semibold)).tracking(2).foregroundStyle(DriftTheme.accent)
                        Text(episode.title ?? episode.name ?? "Episode \(episode.episode ?? 0)").font(.system(size: 14, weight: .semibold)).lineLimit(2)
                        Text("Season \(episode.season ?? 0) · Episode \(episode.episode ?? 0)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button { autoplayCancelled = true; countdownTask?.cancel(); countdownTask = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }.buttonStyle(.plain).help("Cancel automatic next episode")
                }
                VStack(alignment: .leading, spacing: 10) {
                    if let episodeError { Text(episodeError).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    else if session.finished { Text(countdown > 0 ? "Next episode starts in \(countdown)s" : "Preparing next episode…").font(.caption).monospacedDigit().foregroundStyle(.secondary) }
                    Button { changeEpisode(episode) } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
                            Text("Play now").font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(Color.black.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(LinearGradient(colors: [DriftTheme.accent.opacity(0.95), DriftTheme.accent.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1))
                        .shadow(color: DriftTheme.accent.opacity(0.15), radius: 8, y: 3)
                    }.buttonStyle(.plain)
                }
            }.padding(16).frame(width: 340).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.10), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
                .padding(.trailing, 20).padding(.bottom, chrome.visible ? 120 : 24)
        }
    }
    private func prepareUpcomingEpisode() {
        guard upcomingSelection == nil, episodeTask == nil, episodeError == nil, !autoplayCancelled, let episode = nextEpisode else { return }
        loadEpisode(episode, playImmediately: false)
    }
    private func beginCountdown() {
        guard !autoplayCancelled, nextEpisode != nil, countdownTask == nil else { return }
        countdown = 10
        countdownTask = Task { @MainActor in
            for remaining in stride(from: 10, through: 1, by: -1) {
                guard !Task.isCancelled, session.finished, !autoplayCancelled else { return }
                countdown = remaining
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled, session.finished, !autoplayCancelled, let episode = nextEpisode else { return }
            countdown = 0; changeEpisode(episode)
        }
    }
    private func changeEpisode(_ episode: CatalogTitle.Episode) {
        countdownTask?.cancel(); countdownTask = nil
        if let next = upcomingSelection, next.contentID == episode.id { playEpisode(next); return }
        episodeTask?.cancel(); episodeTask = nil; episodeError = nil
        loadEpisode(episode, playImmediately: true)
    }
    private func loadEpisode(_ episode: CatalogTitle.Episode, playImmediately: Bool) {
        let previous = currentSelection
        let current = session.currentStream ?? previous.stream
        let providers = addons.addons.filter { $0.manifest.supports("stream", type: previous.contentType, id: episode.id) }
        episodeTask = Task { @MainActor in
            var found: [AddonStream] = []
            for provider in providers {
                if let results = try? await AddonClient().streams(provider, type: previous.contentType, id: episode.id) { found += results.map(\.stream) }
                if Task.isCancelled { return }
            }
            let choices = EpisodePlayback.preferred(found, matching: current, throughput: UserDefaults.standard.double(forKey: "torrentThroughput"))
            guard let source = choices.first else { episodeError = "No source found. Try Episodes."; episodeTask = nil; return }
            let name = previous.seriesTitle ?? previous.title.components(separatedBy: " · ").first ?? previous.title
            let next = PlaybackSelection(title: name + " · " + episode.label, stream: source, poster: previous.poster, contentID: episode.id, contentType: previous.contentType, genres: previous.genres, episodes: playerEpisodes, seriesTitle: name, automaticSources: session.automaticMessage.isEmpty ? [] : choices)
            episodeTask = nil
            if playImmediately { playEpisode(next) }
            else { upcomingSelection = next; session.prefetch(source) }
        }
    }
    private func playEpisode(_ next: PlaybackSelection) {
        saveHistory(); subtitleTask?.cancel(); episodeTask?.cancel(); countdownTask?.cancel()
        episodeTask = nil; countdownTask = nil; upcomingSelection = nil; episodeError = nil
        subtitleID = "off"; subtitleOptions = next.stream.subtitles ?? []; subtitleMessage = nil; subtitleDelay = 0
        lastHistorySave = 0; autoplayCancelled = false; countdown = 10
        playingSelection = next; chrome.pinned = false; chrome.activity(); session.start(next)
    }
    private func saveHistory() { var actual = currentSelection; actual.stream = session.currentStream ?? currentSelection.stream; history.record(actual, position: session.position, duration: session.duration); if CreditsTiming.reached(position:session.position,duration:session.duration,type:actual.contentType),let next=upcomingSelection { history.queueNext(next) } }
    private func clock(_ seconds: Double) -> String {
        let value = Int(max(0, seconds.isFinite ? seconds : 0))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60)
    }
    private var controls: some View {
        VStack(spacing: 10) {
            HStack {
                Text(clock(scrub)).monospacedDigit().font(.caption)
                GeometryReader { geometry in
                    let total = max(1, session.duration, session.availableUntil)
                    let width = geometry.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.1)).frame(height: 4)
                        Capsule().fill(.white.opacity(0.3)).frame(width: width * min(1, max(0, session.bufferedUntil - session.bufferedFrom) / total), height: 4).offset(x: width * min(1, session.bufferedFrom / total))
                        Capsule().fill(DriftTheme.accent).frame(width: width * min(1, scrub / total), height: 4)
                        Circle().fill(.white).frame(width: 12, height: 12).offset(x: max(0, width * min(1, scrub / total) - 6))
                    }.frame(height: 20).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in scrubbing = true; scrub = max(0, min(total, value.location.x / max(1, width) * total)); chrome.activity() }.onEnded { _ in session.seek(scrub); scrub = session.position; scrubbing = false })
                        .accessibilityElement().accessibilityLabel("Playback position").accessibilityValue(clock(scrub))
                        .accessibilityAdjustableAction { direction in session.seek(session.position + (direction == .increment ? 10 : -10)) }
                }.frame(height: 20)
                Text(session.duration > 0 ? clock(session.duration) : "—").monospacedDigit().font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 18) {
                if !session.automaticMessage.isEmpty { Button(session.automaticMessage) { session.disableAutomaticSources() }.font(.caption).foregroundStyle(.secondary).help("Turn off automatic source switching") }
                Button { session.seek(session.position - 15) } label: { Image(systemName: "gobackward.15") }
                Button { session.togglePause() } label: { Image(systemName: session.paused ? "play.fill" : "pause.fill") }.accessibilityLabel(session.paused ? "Play" : "Pause")
                Button { session.seek(session.position + 15) } label: { Image(systemName: "goforward.15") }
                Spacer()
                if !playerEpisodes.isEmpty {
                    Button { showEpisodes.toggle() } label: { Image(systemName: "list.bullet.rectangle") }.help("Episodes")
                        .popover(isPresented: $showEpisodes) { EpisodeBrowser(episodes: playerEpisodes, selectedID: currentSelection.contentID ?? "", poster: currentSelection.poster, contentType: currentSelection.contentType) { episode in showEpisodes = false; changeEpisode(episode) }.padding(20).frame(width: 520, height: 440) }
                }
                Button { showVolume.toggle() } label: { Image(systemName: muted || volume == 0 ? "speaker.slash" : "speaker.wave.2") }.help("Volume")
                    .popover(isPresented: $showVolume, arrowEdge: .bottom) {
                        VStack(spacing: 16) {
                            HStack { Text("Volume").font(.headline); Spacer(); Text("\(Int(volume * 100))%").monospacedDigit() }
                            Slider(value: $volume, in: 0...1).accessibilityLabel("Player volume")
                                .onChange(of: volume) { _, value in muted = false; session.player?.isMuted = false; session.player?.volume = Float(value) }
                            Button(muted ? "Unmute" : "Mute") { muted.toggle(); session.player?.isMuted = muted }
                        }.padding(20).frame(width: 240)
                    }
                Button { showSubtitles.toggle(); if showSubtitles && subtitleOptions.isEmpty { searchSubtitles() } } label: { Image(systemName: "captions.bubble") }.help("Subtitles")
                    .popover(isPresented: $showSubtitles, arrowEdge: .bottom) { subtitlePanel.font(.system(size: 12)).controlSize(.small).frame(width: 510).preferredColorScheme(.dark) }
                Button { if let player = session.player { FloatingPlayer.shared.toggle(player) } } label: { Image(systemName: "pip") }.help("Picture in Picture")
                Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Toggle full screen")
            }.font(.system(size: 18, weight: .medium)).frame(height: 24).buttonStyle(.borderless)
        }.padding(.horizontal, 16).padding(.vertical, 13).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
    private var subtitlePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Subtitles").font(.headline)
                Picker("Language", selection: $subtitleLanguage) { Text("English").tag("eng"); Text("Español").tag("spa"); Text("All languages").tag("all") }.frame(width: 180)
                Spacer()
                Button(searchingSubtitles ? "Searching…" : "Search online", systemImage: "magnifyingglass") { searchSubtitles() }.disabled(searchingSubtitles)
            }
            HStack {
                Picker("Track", selection: $subtitleID) {
                    Text("Off").tag("off")
                    ForEach(Array(languageOptions.enumerated()), id: \.element.id) { index, option in Text(option.displayName + " · Track \(index + 1)").tag(option.id) }
                }
                Stepper(value: $subtitleDelay, in: -60...60, step: 0.5) { Text(String(format: "Delay: %+.1f s", subtitleDelay)).font(.caption).monospacedDigit() }.frame(width: 180)
                Button("Reset") { subtitleDelay = 0 }.buttonStyle(.borderless)
            }
            if let subtitleMessage { Text(subtitleMessage).font(.caption).foregroundStyle(.secondary) }
            Text("Subtitles follow the playback clock. Positive delay makes captions appear later; release timing may need adjustment.").font(.caption).foregroundStyle(.tertiary)
        }.padding(16).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
    }
    private func searchSubtitles() {
        guard let id = currentSelection.contentID else { subtitleMessage = "No title ID is available for this source."; return }
        subtitleTask?.cancel(); searchingSubtitles = true; subtitleMessage = nil
        let installed = addons.addons.filter { $0.manifest.supports("subtitles", type: currentSelection.contentType, id: id) }
        subtitleTask = Task {
            var providers = installed; var found = currentSelection.stream.subtitles ?? []; var failures = 0
            if providers.isEmpty {
                do { providers = [try await AddonClient().install("https://opensubtitles-v3.strem.io/manifest.json")] }
                catch { failures += 1 }
            }
            for provider in providers {
                do { found += try await AddonClient().subtitles(provider, type: currentSelection.contentType, id: id).map { option in var track = option; track.id = provider.manifest.id + ":" + track.id; return track } }
                catch { failures += 1 }
            }
            guard !Task.isCancelled else { return }
            var seen = Set<String>(); subtitleOptions = found.filter { seen.insert($0.id).inserted }
            searchingSubtitles = false
            subtitleMessage = found.isEmpty ? (failures > 0 ? "Subtitle search failed. Try again or connect a subtitle add-on." : "No subtitles found for this title.") : "Found \(subtitleOptions.count) tracks. Choose a matching release."
        }
    }
    private func loadSubtitle() {
        subtitleTask?.cancel(); searchingSubtitles = false; session.cues = []; session.subtitleText = ""
        guard let option = subtitleOptions.first(where: { $0.id == subtitleID }) else { subtitleMessage = nil; return }
        subtitleMessage = "Loading subtitles…"
        subtitleTask = Task {
            do {
                let cues = try await AddonClient().subtitleFile(option)
                guard !Task.isCancelled else { return }
                session.cues = cues; subtitleMessage = "Subtitles loaded."
            } catch { if !Task.isCancelled { subtitleMessage = "Could not load this track. SRT and WebVTT are supported; try another release." } }
        }
    }

}
