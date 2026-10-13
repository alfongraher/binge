import SwiftUI
import AVKit

@MainActor
final class PlaybackSession: ObservableObject {
    static let shared = PlaybackSession()
    private var lastControlWrite = Date.distantPast
    private var retained = false
    private var sourceKey: String?
    @Published var finished = false
    private var endObserver: NSObjectProtocol?
    @Published var player: AVPlayer?
    @Published var message = "Preparing playback…"
    @Published var failed = false
    @Published var readyToPlay = false
    @Published var bufferProgress: Double?
    @Published var peers = 0
    @Published var rate = 0
    @Published var position = 0.0
    @Published var duration = 0.0
    @Published var availableUntil = 0.0
    @Published var bufferedUntil = 0.0
    @Published var bufferedFrom = 0.0
    @Published var paused = false
    @Published var subtitleText = ""
    var cues: [SubtitleCue] = []
    var subtitleDelay = 0.0
    private var timeObserver: Any?
    private var torrentMode = false
    private var pendingResume = 0.0
    private var mediaOffset = 0.0
    private var worker: Process?
    private var scratch: URL?
    private var poll: Task<Void, Never>?
    private var observer: NSKeyValueObservation?
    private var health: Task<Void, Never>?
    private var lastRecovery = Date.distantPast
    private var lastClockMovement = Date()
    private var previousClock = -1.0
    private var recovering = false
    private var warmOnly = false
    private var preparedURL: URL?
    private var adaptation: Task<Void, Never>?
    private var candidate: PlaybackSession?
    private var wantsPause = false
    private var seekID = 0
    private var seekTarget = 0.0
    private var workerFileIdx: Int?
    private var prefetchFileIdx: Int?
    private var playbackURL: URL?
    private var replacementVolume: Float?
    private var replacementMuted = false
    @Published var automaticMessage = ""
    var currentStream: AddonStream?


    func start(_ selection: PlaybackSelection, warmOnly: Bool = false) {
        let key = (selection.stream.playableSource ?? "") + ":" + String(selection.stream.fileIdx ?? -1)
        if sourceKey == key, player != nil, !failed, !finished { retained = false; wantsPause = false; paused = false; player?.play(); control(paused: false, force: true); if !selection.automaticSources.isEmpty { monitorSources(selection) }; return }
        if !warmOnly, worker != nil, scratch != nil,
           let hash = selection.stream.infoHash, hash == currentStream?.infoHash,
           let index = selection.stream.fileIdx, index != workerFileIdx {
            adaptation?.cancel(); adaptation = nil; candidate?.stop(); candidate = nil
            retained = false; finished = false; failed = false; wantsPause = false; paused = false
            currentStream = selection.stream; sourceKey = key; duration = 0
            automaticMessage = selection.automaticSources.isEmpty ? "" : "Auto · learning connection"
            requestTorrentEpisode(selection, index: index)
            if !selection.automaticSources.isEmpty { monitorSources(selection) }
            return
        }
        stop(); retained = false; sourceKey = key; finished = false; mediaOffset = 0; pendingResume = selection.stream.playableSource?.hasPrefix("magnet:") == true ? 0 : selection.resumePosition; position = 0; duration = 0; availableUntil = 0; bufferedUntil = 0; bufferedFrom = 0; paused = false; torrentMode = selection.stream.playableSource?.hasPrefix("magnet:") == true; failed = false; bufferProgress = nil; peers = 0; rate = 0; message = "Preparing playback…"
        seekID = 0; seekTarget = 0; replacementVolume = nil
        lastRecovery = .distantPast; lastClockMovement = Date(); previousClock = -1
        self.warmOnly = warmOnly; self.retained = warmOnly; preparedURL = nil; wantsPause = false; currentStream = selection.stream
        automaticMessage = selection.automaticSources.isEmpty ? "" : "Auto · learning connection"
        if !warmOnly && !selection.automaticSources.isEmpty { monitorSources(selection) }
        guard let source = selection.stream.playableSource, let url = URL(string: source) else {
            fail("This source is not supported."); return
        }
        if url.scheme != "magnet" { play(url); return }
        guard let resources = Bundle.main.resourceURL else { fail("The torrent engine is missing. Rebuild Drift."); return }
        let engine = resources.appendingPathComponent("Engine/torrent_stream.py")
        let ffmpeg = resources.appendingPathComponent("Runtime/node_modules/ffmpeg-static/ffmpeg")
        let python = URL(fileURLWithPath: "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3")
        guard FileManager.default.fileExists(atPath: engine.path), FileManager.default.isExecutableFile(atPath: python.path), FileManager.default.isExecutableFile(atPath: ffmpeg.path) else {
            fail("Torrent runtime is missing. Use the packaged Drift.app with Python 3.12 installed."); return
        }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("drift-playback-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            scratch = directory
            let process = Process(); process.executableURL = python; process.arguments = [engine.path, directory.path]
            var environment = ProcessInfo.processInfo.environment
            environment["PYTHONPATH"] = resources.appendingPathComponent("Runtime/python").path
            process.environment = environment
            let input = Pipe(); process.standardInput = input
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            var config: [String: Any] = ["magnet": source, "ffmpeg": ffmpeg.path, "startPosition": selection.resumePosition]
            if let index = selection.stream.fileIdx { config["fileIdx"] = index }
            try process.run(); worker = process
            var data = try JSONSerialization.data(withJSONObject: config); data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data); try input.fileHandleForWriting.close()
            message = "Finding torrent peers…"
            watchWorker(process, directory: directory)
        } catch { fail("Could not start torrent playback."); stop() }
    }
    private func watchWorker(_ process: Process, directory: URL) {
        poll = Task { [weak self] in
                struct Status: Decodable { var state: String; var url: String?; var message: String?; var bufferProgress: Double?; var peers: Int?; var rate: Int?; var duration: Double?; var offset: Double?; var generatedUntil: Double?; var seekID: Int?; var fileIdx: Int? }
                while !Task.isCancelled {
                    guard let self else { return }
                    if let data = try? Data(contentsOf: directory.appendingPathComponent("status.json")),
                       let status = try? JSONDecoder().decode(Status.self, from: data) {
                        if (status.seekID ?? 0) < self.seekID { try? await Task.sleep(for: .milliseconds(500)); continue }
                        if let until = status.generatedUntil { self.bufferedUntil = until }
                        self.workerFileIdx = status.fileIdx ?? self.workerFileIdx
                        self.mediaOffset = status.offset ?? 0; self.bufferedFrom = self.mediaOffset
                        self.bufferProgress = status.bufferProgress.map { min(1, max(0, $0)) }
                        if let duration = status.duration, duration.isFinite { self.duration = duration }
                        self.peers = status.peers ?? 0; self.rate = status.rate ?? 0
                        if status.state == "ready", self.player == nil, let text = status.url, let url = URL(string: text) { self.preparedURL = url; self.message = "Opening your video…"; self.play(url) }
                        else if status.state == "buffering" { self.message = "Buffering your video…" }
                        else if status.state == "error" { self.fail(status.message ?? "Torrent playback failed."); return }
                    }
                    if !process.isRunning { self.fail("The torrent engine stopped unexpectedly."); return }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
    }
    private func monitorSources(_ selection: PlaybackSelection) {
        adaptation = Task { [weak self] in
            var previous = -1.0, stalled = 0, attempted = false
            var throughput = UserDefaults.standard.double(forKey: "torrentThroughput")
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if self.retained || self.finished || self.failed { return }
                if self.rate > 32_768 {
                    throughput = throughput == 0 ? Double(self.rate) : throughput * 0.9 + Double(self.rate) * 0.1
                    UserDefaults.standard.set(throughput, forKey: "torrentThroughput")
                }
                stalled = self.readyToPlay && self.player != nil && !self.wantsPause && abs(self.position - previous) < 0.1 ? stalled + 1 : 0
                previous = self.position
                guard stalled >= 20, !attempted, self.duration > 0, self.position < self.duration - 30 else { continue }
                attempted = true // One replacement attempt per viewing session; never oscillate.
                let alternatives = SourcePolicy.ranked(selection.automaticSources, throughput: throughput, duration: self.duration).filter {
                    $0.playableSource != self.currentStream?.playableSource && SourcePolicy.compatible(selection.stream, $0) &&
                    $0.playableSource?.hasPrefix("magnet:") == true &&
                    SourcePolicy.score($0, throughput: throughput, duration: self.duration) > SourcePolicy.score(selection.stream, throughput: throughput, duration: self.duration)
                }
                guard let stream = alternatives.first else { self.automaticMessage = "Auto · keeping this source"; continue }
                self.automaticMessage = "Auto · preparing a fallback"
                let prepared = PlaybackSession(); self.candidate = prepared
                var next = selection; next.stream = stream; next.resumePosition = self.position; next.automaticSources = []
                prepared.start(next, warmOnly: true)
                for _ in 0..<60 {
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { prepared.stop(); return }
                    if prepared.failed || self.retained || self.wantsPause || self.position > next.resumePosition + 1 { break }
                    if prepared.readyToPlay, let url = prepared.preparedURL {
                        guard SourcePolicy.matchingRuntime(self.duration, prepared.duration) else { break }
                        let volume = self.player?.volume ?? 1, muted = self.player?.isMuted ?? false
                        let cues = self.cues, delay = self.subtitleDelay
                        // Transfer the already buffered worker, rather than downloading it again.
                        prepared.poll?.cancel(); prepared.poll = nil
                        let worker = prepared.worker, scratch = prepared.scratch
                        prepared.worker = nil; prepared.scratch = nil
                        self.adaptation = nil; self.stop()
                        self.worker = worker; self.scratch = scratch; self.sourceKey = (stream.playableSource ?? "") + ":" + String(stream.fileIdx ?? -1)
                        self.currentStream = stream; self.seekID = prepared.seekID; self.seekTarget = prepared.seekTarget; self.mediaOffset = prepared.mediaOffset; self.duration = prepared.duration
                        self.position = next.resumePosition; self.bufferedUntil = prepared.bufferedUntil; self.bufferedFrom = prepared.bufferedFrom; self.torrentMode = true; self.retained = false
                        self.cues = cues; self.subtitleDelay = delay
                        if let worker, let scratch { self.watchWorker(worker, directory: scratch) }
                        self.play(url); self.player?.volume = volume; self.player?.isMuted = muted
                        self.automaticMessage = "Auto · switched to " + stream.resolution
                        return
                    }
                }
                prepared.stop(); self.candidate = nil; self.automaticMessage = "Auto · keeping this source"
            }
        }
    }
    /// Clock-independent heartbeat: a stalled periodic observer must never block engine control.
    private func watchPlayback(_ url: URL) {
        health?.cancel()
        lastClockMovement = Date(); previousClock = -1
        health = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                guard !self.retained, !self.warmOnly, !self.finished, let player = self.player else { continue }
                let clock = player.currentTime().seconds
                if clock.isFinite && abs(clock - self.previousClock) > 0.05 {
                    self.previousClock = clock; self.lastClockMovement = Date(); self.recovering = false
                }
                if self.wantsPause || !self.readyToPlay { self.lastClockMovement = Date() }
                let stalled = Date().timeIntervalSince(self.lastClockMovement)
                self.recovering = !self.wantsPause && self.readyToPlay && stalled >= 8
                self.control(paused: self.wantsPause)
                guard self.recovering, Date().timeIntervalSince(self.lastRecovery) >= 45 else { continue }
                // Try the existing item first. Never force playback past downloaded ranges.
                let nativeBuffer = player.currentItem?.loadedTimeRanges.contains { range in
                    let value = range.timeRangeValue
                    return value.start.seconds <= clock + 0.2 && CMTimeRangeGetEnd(value).seconds > clock + 2
                } ?? false
                if stalled < 20 {
                    if nativeBuffer { player.playImmediately(atRate: 1) }
                } else {
                    self.lastRecovery = Date()
                    let resume = max(self.position, clock.isFinite ? clock + self.mediaOffset : self.position)
                    let volume = player.volume, muted = player.isMuted
                    if self.torrentMode {
                        // A stuck HLS generation needs a fresh converter timeline, not repeated
                        // attachment to the same cached playlist that already stopped advancing.
                        self.requestTorrentSeek(resume, message: "Recovering playback…")
                    } else {
                        self.detachPlayer(); self.pendingResume = resume; self.readyToPlay = false
                        self.play(url); self.player?.volume = volume; self.player?.isMuted = muted
                        self.message = "Recovering playback…"
                    }
                    return
                }
            }
        }
    }
    private func detachPlayer() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }; endObserver = nil
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }; timeObserver = nil
        observer = nil; player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
    }
    private func play(_ url: URL) {
        playbackURL = url
        let item = AVPlayerItem(url: url)
        observer = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            Task { @MainActor [weak self] in
                guard let self, self.player?.currentItem === item else { return }
                if status == .readyToPlay { self.readyToPlay = true }
                if status == .failed {
                    if self.torrentMode && self.worker != nil && self.duration > 0 {
                        if self.wantsPause || self.retained { self.readyToPlay = false; return }
                        if Date().timeIntervalSince(self.lastRecovery) >= 45 {
                            self.lastRecovery = Date()
                            self.requestTorrentSeek(self.position, message: "Recovering playback…")
                            return
                        }
                    }
                    self.fail("The native player could not play this source. Try another source or format.")
                }
            }
        }
        let playback = AVPlayer(playerItem: item)
        player = playback
        timeObserver = playback.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self, weak playback] time in
            Task { @MainActor [weak self, weak playback] in
                guard let self, let playback, self.player === playback, !self.retained, !self.finished else { return }
                self.position = time.seconds.isFinite ? max(0, time.seconds + self.mediaOffset) : self.mediaOffset
                if (!self.torrentMode || self.duration == 0) && item.duration.seconds.isFinite && item.duration.seconds > 0 { self.duration = item.duration.seconds }
                let ranges = item.seekableTimeRanges.map { $0.timeRangeValue }
                self.bufferedUntil = max(self.bufferedUntil, item.loadedTimeRanges.map { CMTimeRangeGetEnd($0.timeRangeValue).seconds + self.mediaOffset }.filter(\.isFinite).max() ?? 0)
                self.availableUntil = ranges.map { CMTimeRangeGetEnd($0).seconds + self.mediaOffset }.filter(\.isFinite).max() ?? (self.torrentMode ? 0 : self.duration)
                if self.pendingResume > 0 && self.availableUntil >= self.pendingResume {
                    let resume = self.pendingResume; self.pendingResume = 0; self.seek(resume)
                }
                self.control(paused: self.wantsPause)
                self.paused = self.wantsPause
                self.subtitleText = SubtitleParser.active(self.cues, time: self.position, delay: self.subtitleDelay)
            }
        }
        // Torrent output already has a 30-second startup buffer. Avoid AVPlayer's
        // requiring more buffer than the explicit startup window provides.
        playback.automaticallyWaitsToMinimizeStalling = true
        item.preferredForwardBufferDuration = torrentMode ? 12 : 45
        if let replacementVolume { playback.volume = replacementVolume; playback.isMuted = replacementMuted }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.player?.currentItem === item else { return }
                if self.torrentMode && self.position < self.duration - 3 {
                    self.requestTorrentSeek(self.position, message: "Recovering playback…")
                } else {
                    self.position = self.duration; self.finished = true
                    self.player?.pause(); self.wantsPause = true; self.paused = true; self.subtitleText = ""
                    self.health?.cancel(); self.health = nil; self.adaptation?.cancel(); self.adaptation = nil
                    self.candidate?.stop(); self.candidate = nil; self.control(paused: true, force: true)
                }
            }
        }
        if !retained && !wantsPause { playback.play() }; watchPlayback(url)
    }
    func prefetch(_ stream: AddonStream) {
        guard stream.infoHash != nil, stream.infoHash == currentStream?.infoHash,
              let index = stream.fileIdx, index != workerFileIdx else { return }
        prefetchFileIdx = index; control(paused: wantsPause, force: true)
    }
    private func requestTorrentEpisode(_ selection: PlaybackSelection, index: Int) {
        replacementVolume = player?.volume ?? 1; replacementMuted = player?.isMuted ?? false
        health?.cancel(); health = nil; detachPlayer(); readyToPlay = false
        seekID += 1; seekTarget = selection.resumePosition
        position = seekTarget; mediaOffset = seekTarget; bufferedFrom = seekTarget; bufferedUntil = seekTarget; availableUntil = seekTarget
        pendingResume = 0; prefetchFileIdx = nil; preparedURL = nil; bufferProgress = 0
        lastRecovery = .distantPast; cues = []; subtitleText = ""; subtitleDelay = 0
        message = "Opening the next episode…"; control(paused: false, force: true)
    }
    private func requestTorrentSeek(_ seconds: Double, message: String) {
        guard scratch != nil, duration > 0 else { return }
        replacementVolume = player?.volume ?? replacementVolume ?? 1
        replacementMuted = player?.isMuted ?? replacementMuted
        health?.cancel(); health = nil; detachPlayer(); readyToPlay = false
        seekID += 1; seekTarget = min(max(0, seconds), max(0, duration - 1))
        position = seekTarget; bufferedFrom = seekTarget; bufferedUntil = seekTarget; availableUntil = seekTarget
        pendingResume = 0; preparedURL = nil; bufferProgress = 0; self.message = message
        control(paused: wantsPause, force: true)
    }
    func seek(_ seconds: Double) {
        guard seconds.isFinite, duration > 0 else { return }
        if finished { finished = false; if let playbackURL { watchPlayback(playbackURL) } }
        let value = min(max(0, seconds), max(0, duration - 0.5))
        let start = (player?.currentItem?.seekableTimeRanges.first?.timeRangeValue.start.seconds ?? 0) + mediaOffset
        if torrentMode && (player == nil || value < start || value > availableUntil - 0.2) {
            requestTorrentSeek(value, message: "Buffering the part you chose…")
            return
        }
        player?.seek(to: CMTime(seconds: value - mediaOffset, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 0.15, preferredTimescale: 600))
        position = value; lastClockMovement = Date()
        subtitleText = SubtitleParser.active(cues, time: value, delay: subtitleDelay)
    }
    func disableAutomaticSources() { adaptation?.cancel(); adaptation = nil; candidate?.stop(); candidate = nil; automaticMessage = "" }
    private var pauseStarted: Date?
    func togglePause() {
        if finished { wantsPause = false; paused = false; seek(0); player?.play(); control(paused: false, force: true); return }
        wantsPause.toggle(); paused = wantsPause
        if wantsPause { pauseStarted = Date(); player?.pause() }
        else {
            let elapsed = pauseStarted.map { Date().timeIntervalSince($0) } ?? 0
            pauseStarted = nil; lastClockMovement = Date()
            // A suspended EVENT playlist may have expired in AVFoundation during a long pause.
            // Reopen at the saved clock using the existing torrent and downloaded pieces.
            if torrentMode && (elapsed > 15 || player?.currentItem?.status == .failed) {
                requestTorrentSeek(position, message: "Resuming your video…")
            } else { player?.play() }
        }
        control(paused: wantsPause, force: true)
    }

    private func fail(_ text: String) { stop(); failed = true; message = text }
    private func control(paused: Bool, force: Bool = false) {
        guard force || Date().timeIntervalSince(lastControlWrite) >= 2 else { return }
        lastControlWrite = Date()
        guard let scratch else { return }
        var values: [String: Any] = ["paused": paused, "recovering": recovering, "seekID": seekID, "seekPosition": seekTarget, "position": max(0, position - mediaOffset)]
        if let index = currentStream?.fileIdx { values["fileIdx"] = index }
        if let prefetchFileIdx { values["prefetchFileIdx"] = prefetchFileIdx }
        if let data = try? JSONSerialization.data(withJSONObject: values) { try? data.write(to: scratch.appendingPathComponent("control.json"), options: .atomic) }
    }
    func retainLast() { adaptation?.cancel(); adaptation = nil; candidate?.stop(); candidate = nil; if finished { stop(); return }; retained = true; player?.pause(); cues = []; subtitleText = ""; subtitleDelay = 0; control(paused: true, force: true) }
    func stop() {
        adaptation?.cancel(); adaptation = nil; candidate?.stop(); candidate = nil
        health?.cancel(); health = nil; recovering = false
        sourceKey = nil; workerFileIdx = nil; prefetchFileIdx = nil; playbackURL = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }; endObserver = nil
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil; cues = []; subtitleText = ""
        poll?.cancel(); poll = nil; observer = nil; readyToPlay = false; player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        if let process = worker, process.isRunning {
            process.terminate()
            let directory = scratch
            Task.detached {
                process.waitUntilExit()
                if let directory { try? FileManager.default.removeItem(at: directory) }
            }
        } else if let scratch { try? FileManager.default.removeItem(at: scratch) }
        worker = nil; scratch = nil
    }
}

