import SwiftUI
import AVFoundation
// NativeMedia serializes conversion on a worker; cancellation is atomic.
extension NativeMedia: @unchecked Sendable {}
@MainActor final class IPadPlayback:ObservableObject {
    @Published var player:AVPlayer?
    @Published var message="Preparing your video…"
    @Published var failed=false
    @Published var progress=0.0
    @Published var position=0.0
    @Published var duration=0.0
    @Published private(set) var bufferedRanges:[ClosedRange<Double>]=[]
    @Published private(set) var isPlaying=false
    private var sourceStarted=Date()
    private var recordedStartup=false
    @Published var completed=false
    @Published var seekError:String?
    @Published private(set) var nextEpisode:IPadWatchContext?
    @Published private(set) var nextThumbnail:URL?
    @Published private(set) var nextCountdown:Int?
    @Published private(set) var nextBusy=false
    @Published private(set) var nextError:String?
    @Published private(set) var showNext=false
    private var nextStream:AddonStream?
    private var nextDismissed=false
    private var foreground=true
    private var nextTask:Task<Void,Never>?
    private var countdownTask:Task<Void,Never>?
    private var preloadedNext=false
    private var fixture:URL?
    private let countdownSeconds:Int
    var currentContext:IPadWatchContext? { context }
    func diagnosticSnapshot()->String { engine.snapshot() }
    @Published var subtitleOptions:[AVMediaSelectionOption]=[]
    @Published var subtitleSelection="automatic"
    @Published var onlineSubtitles:[SubtitleOption]=[]
    @Published var subtitleBusy=false
    @Published var subtitleError:String?
    @Published var subtitleDelay=0.0
    private var desiredPlay=true
    private var resumeSeeking=false
    private var timingTask:Task<Void,Never>?
    private var subtitleRequest=UUID()
    private var playbackURL:URL?
    private var onlineCues:[SubtitleCue]?
    private var onlineOption:SubtitleOption?
    private var generation=UUID()
    private var restoreTask:Task<Void,Never>?
    private var subtitleGroup:AVMediaSelectionGroup?
    private var context:IPadWatchContext?
    private var stream:AddonStream?
    private var resumePosition=0.0
    private var baseTime=0.0
    private var timeObserver:Any?
    private var endObserver:NSObjectProtocol?
    private var lastSave=Date.distantPast
    private let history:IPadHistory
    private let preferences:UserDefaults
    private let cacheStore:IPadCacheStore
    private var cacheLease:IPadCacheLease?
    init(history:IPadHistory = .shared,preferences:UserDefaults = .standard,cacheStore:IPadCacheStore = .shared,countdownSeconds:Int=10,engine:TorrentProof=TorrentProof()) { self.history=history;self.preferences=preferences;self.cacheStore=cacheStore;self.countdownSeconds=countdownSeconds;self.engine=engine }
    private let engine:TorrentProof
    private var loader:TorrentVideoLoader?
    private var task:Task<Void,Never>?
    private var cache:URL?
    private var observer:NSKeyValueObservation?
    private var media:NativeMedia?
    private var mediaFinished=false
    func start(_ stream:AddonStream,context:IPadWatchContext?=nil,fixture:URL?=nil,reusingTorrent:Bool=false,resumeAt:Double?=nil,autoplay:Bool=true) {
        stop(reusingTorrent:reusingTorrent);self.fixture=fixture;generation=UUID();onlineSubtitles=[];subtitleError=nil;onlineCues=nil;onlineOption=nil;self.context=context;self.stream=stream;failed=false;progress=0;position=0;duration=0;completed=false;bufferedRanges=[];isPlaying=false;baseTime=0;lastSave = .distantPast
        sourceStarted=Date();recordedStartup=false
        resumePosition=resumeAt ?? context.flatMap { history.record($0)?.position } ?? 0
        message=resumePosition>0 ? "Resuming your video…" : "Preparing your video…"
        subtitleDelay=preferences.double(forKey:"binge.ipad.subtitleDelay")
        subtitleSelection=preferences.string(forKey:"binge.ipad.subtitleSelection") ?? "automatic"
        if fixture == nil,context?.type=="series" { nextTask=Task { @MainActor [weak self] in await self?.discoverNextEpisode() } }
        guard let source=stream.playableSource,let url=URL(string:source) else { fail("This source is not playable.");return }
        if url.scheme != "magnet" { play(url,shouldPlay:autoplay);return }
        if let bytes=SourcePolicy.bytes(stream),bytes>2*1024*1024*1024 {
            fail("This source is listed above this build’s 2 GB limit. Choose a smaller source or resolution.");return
        }
        if stream.detail.lowercased().contains("av1") { fail("AV1 sources are not supported by this iPad build yet. Choose H.264 or HEVC.");return }
        let lease=cacheStore.acquire(stream);cacheLease=lease
        let cache=lease.folder;self.cache=cache
        do { try FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true) }
        catch { fail(error.localizedDescription);return }
        if lease.previous?.workerFinished != false,
           let data=try? Data(contentsOf:cache.appendingPathComponent("prepared.json")),
           let prepared=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
           let total=prepared["duration"] as? Double,let offset=prepared["sourceOffset"] as? Double,
           !needsNativeMP4(cache,stream:stream),
           (prepared["timingVersion"] as? Int ?? 0)>=2,
           total>0,offset>=0,resumePosition>=offset,resumePosition<=total+1,
           (prepared["fileIndex"] as? Int ?? (lease.previous?.key==lease.key ? stream.fileIdx ?? -1 : -2)) == (stream.fileIdx ?? -1),
           ((try? String(contentsOf:cache.appendingPathComponent("segments/media.m3u8"),encoding:.utf8)) ?? "").contains("#EXT-X-ENDLIST") {
            baseTime=offset;duration=total
            task=Task { @MainActor [self] in
                let reader=TorrentVideoLoader(engine:engine,directory:cache.appendingPathComponent("segments"));loader=reader
                do { let local=try await reader.start();guard !Task.isCancelled else { reader.cancel();return };play(local,shouldPlay:autoplay) }
                catch { fail(error.localizedDescription) }
            }
            return
        }
        var error:NSString?
        let started:Bool
        if reusingTorrent {
            let snapshot=(try? JSONSerialization.jsonObject(with:Data(engine.snapshot().utf8))) as? [String:Any]
            if let index=stream.fileIdx ?? snapshot?["selectedFile"] as? Int { started=engine.selectFile(Int32(index)) } else { started=false }
        }
        else if let fixture {
            started=engine.start(withFixture:fixture.path,cache:cache.path,error:&error)
            if started,let index=stream.fileIdx,index != 1 { _ = engine.selectFile(Int32(index)) }
        }
        else { started=engine.startMagnet(source,cache:cache.path,fileIndex:Int32(stream.fileIdx ?? -1),error:&error) }
        guard started else { fail(error as String? ?? "Torrent could not start.");return }
        task=Task { @MainActor [self] in
            while lease.previous?.workerFinished == false && !Task.isCancelled { try? await Task.sleep(for:.milliseconds(50)) }
            guard !Task.isCancelled else { return }
            if lease.previous?.key != lease.key { try? FileManager.default.removeItem(at:cache.appendingPathComponent("prepared.json")) }
            let discoveryDeadline=Date().addingTimeInterval(90)
            var nextRefresh=Date().addingTimeInterval(15)
            while !Task.isCancelled {
                let text=engine.snapshot()
                if let state=(try? JSONSerialization.jsonObject(with:Data(text.utf8))) as? [String:Any] {
                    if Date()>nextRefresh && (state["peers"] as? Int ?? 0)==0 { engine.refreshDiscovery();nextRefresh=Date().addingTimeInterval(15) }
                    if let error=state["error"] as? String,!error.isEmpty { fail(error);return }
                    if state["metadata"] as? Bool == true,let path=engine.selectedFilePath() {
                        let size=engine.videoSize()
                        guard size>0 && size<=2*1024*1024*1024 else { fail("Choose a source smaller than 2 GB for this iPad.");return }
                        let capacity=try? cache.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
                        if let capacity,capacity<size*2+250*1024*1024 { fail("Not enough free space for this source. Choose a smaller file.");return }
                        let output=cache.appendingPathComponent("segments")
                        try? FileManager.default.removeItem(at:output)
                        do { try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true) }
                        catch { fail(error.localizedDescription);return }
                        engine.prepareStreaming()
                        let converter=NativeMedia();media=converter;mediaFinished=false;lease.workerFinished=false
                        let store=cacheStore
                        message="Downloading startup buffer…";progress=0
                        converter.stream(engine:engine,directory:output.path,startAt:max(0,resumePosition-10)) { [weak self] result in
                            Task { @MainActor in
                                store.workerEnded(lease)
                                let converted=(try? JSONSerialization.jsonObject(with:Data(result.utf8))) as? [String:Any]
                                if !lease.discard,var prepared=converted,prepared["success"] as? Bool == true {
                                    prepared["fileIndex"]=stream.fileIdx ?? -1
                                    if let data=try? JSONSerialization.data(withJSONObject:prepared) { try? data.write(to:cache.appendingPathComponent("prepared.json"),options:.atomic) }
                                }
                                guard let self,self.media === converter else { return }
                                self.mediaFinished=true
                                if converted?["success"] as? Bool != true { self.fail(converted?["error"] as? String ?? "This source could not be prepared.") }
                            }
                        }
                        let playlist=output.appendingPathComponent("media.m3u8")
                        var lastDiagnostic=Date.distantPast
                        while !Task.isCancelled {
                            let state=(try? JSONSerialization.jsonObject(with:Data(engine.snapshot().utf8))) as? [String:Any] ?? [:]
                            if fixture==nil { SourceExperience.shared.observe(rate:Double(state["rate"] as? Int ?? 0)) }
                            if let error=state["error"] as? String,!error.isEmpty { fail(error);return }
                            #if DEBUG
                            if Date().timeIntervalSince(lastDiagnostic)>5 {
                                let diagnostic="Media: \(converter.diagnostic())\nTorrent: \(engine.snapshot())\n"
                                try? diagnostic.write(to:FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("startup-diagnostic.txt"),atomically:true,encoding:.utf8)
                                lastDiagnostic=Date()
                            }
                            #endif
                            let text=(try? String(contentsOf:playlist,encoding:.utf8)) ?? ""
                            let durations=text.components(separatedBy:"\n").filter { $0.hasPrefix("#EXTINF:") }.compactMap { Double($0.dropFirst(8).split(separator:",")[0]) }
                            let seconds=durations.reduce(0,+)
                            let needed=max(12,resumePosition-converter.sourceOffset()+3)
                            progress=min(1,seconds/needed)
                            message=seconds>0 ? "Preparing playback · \(Int(seconds)) seconds ready" : "Downloading startup buffer…"
                            if (seconds>=needed || text.contains("#EXT-X-ENDLIST")) && FileManager.default.fileExists(atPath:output.appendingPathComponent("master.m3u8").path) {
                                baseTime=converter.sourceOffset();duration=converter.duration()
                                let nativeMP4=needsNativeMP4(cache,stream:stream)
                                if nativeMP4 { baseTime=0;media=nil;converter.cancel() }
                                let reader=TorrentVideoLoader(engine:engine,directory:nativeMP4 ? nil : output);loader=reader
                                do { let local=try await reader.start();guard !Task.isCancelled else { reader.cancel();return };play(local,shouldPlay:autoplay) }
                                catch { fail(error.localizedDescription) }
                                return
                            }
                            try? await Task.sleep(for:.milliseconds(200))
                        }
                        return
                    } else {
                        let peers=state["peers"] as? Int ?? 0
                        message=peers>0 ? "Connected · loading video information…" : "Finding an available source…"
                        if Date()>discoveryDeadline { fail("No usable peers responded for this source. Go back and try another source.");return }
                    }
                }
                try? await Task.sleep(for:.milliseconds(300))
            }
            if !Task.isCancelled { fail("This source did not become ready. Try another source.") }
        }
    }
    private func needsNativeMP4(_ folder:URL,stream:AddonStream)->Bool {
        let output=folder.appendingPathComponent("segments")
        guard let data=try? Data(contentsOf:output.appendingPathComponent("video-info.json")),let info=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],["PQ","HLG"].contains(info["videoRange"] as? String ?? "") else { return false }
        let master=(try? String(contentsOf:output.appendingPathComponent("master.m3u8"),encoding:.utf8)) ?? ""
        let file=stream.behaviorHints?.filename ?? ""
        let mp4=info["sourceContainer"] as? String == "mp4" || ["mp4","m4v","mov"].contains((file as NSString).pathExtension.lowercased())
        return mp4 && master.contains("avc1.")
    }
    private func play(_ url:URL,shouldPlay:Bool=true) {
        desiredPlay=shouldPlay;resumeSeeking=resumePosition>baseTime
        if let timeObserver,let player { player.removeTimeObserver(timeObserver) };timeObserver=nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) };endObserver=nil
        observer=nil;player?.pause();subtitleGroup=nil;subtitleOptions=[];playbackURL=url
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let video=AVPlayer(url:url);video.currentItem?.preferredForwardBufferDuration=12
        // HLS already has a prepared startup window; don't wait for a short
        // event stream to reach EOF before permitting playback.
        if url.pathExtension=="m3u8" { video.automaticallyWaitsToMinimizeStalling=false }
        player=video;message=""
        if let item=video.currentItem {
            observer=item.observe(\.status,options:[.initial,.new]) { [weak self] item,_ in
                let status=item.status
                Task { @MainActor [weak self] in
                    guard let self,self.player?.currentItem === item else { return }
                    if status == .failed { self.fail(item.error?.localizedDescription ?? "The native player could not play this source. Try another source.",nativeError:item.error) }
                    else if status == .readyToPlay {
                        let target=max(0,self.resumePosition-self.baseTime)
                        video.automaticallyWaitsToMinimizeStalling=true
                        if target>0 {
                            video.seek(to:CMTime(seconds:target,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero) { success in
                                Task { @MainActor [weak self] in guard let self,self.player?.currentItem === item else { return }
                                    guard success else { self.fail("This source could not resume at the saved position. Try again or choose another source.");return }
                                    self.resumeSeeking=false;self.saveProgress();self.updateNextPrompt()
                                    if shouldPlay { video.play() } }
                            }
                        } else { self.resumeSeeking=false;if shouldPlay { video.play() } }
                        if let group=try? await item.asset.loadMediaSelectionGroup(for:.legible) {
                            guard self.player?.currentItem === item else { return }
                            self.subtitleGroup=group;self.subtitleOptions=group.options
                            self.applySubtitlePreference()
                        }
                        if self.subtitleSelection.hasPrefix("online:"),self.onlineCues == nil,self.loader?.supportsExternalCaptions == true {
                            self.restoreTask?.cancel();self.restoreTask=Task { await self.restoreOnlineCaptions() }
                        }
                    }
                }
            }
        }
        timeObserver=video.addPeriodicTimeObserver(forInterval:CMTime(seconds:1,preferredTimescale:600),queue:.main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self,self.player === video,!self.resumeSeeking,time.seconds.isFinite else { return }
                self.position=max(0,self.baseTime+time.seconds)
                if !self.recordedStartup,self.fixture==nil,time.seconds>0.5,video.timeControlStatus == .playing,let stream=self.stream {
                    self.recordedStartup=true;SourceExperience.shared.record(stream,success:true,startup:Date().timeIntervalSince(self.sourceStarted))
                }
                if self.fixture==nil,self.engine.videoSize()>0 {
                    let snapshot=(try? JSONSerialization.jsonObject(with:Data(self.engine.snapshot().utf8))) as? [String:Any]
                    SourceExperience.shared.observe(rate:Double(snapshot?["rate"] as? Int ?? 0))
                }
                self.refreshTimeline()
                if self.duration<=0,let seconds=video.currentItem?.duration.seconds,seconds.isFinite,seconds>0,self.loader?.supportsExternalCaptions != true { self.duration=seconds }
                if Date().timeIntervalSince(self.lastSave)>=5 { self.saveProgress();self.lastSave=Date() }
                self.updateNextPrompt()
            }
        }
        endObserver=NotificationCenter.default.addObserver(forName:.AVPlayerItemDidPlayToEndTime,object:video.currentItem,queue:.main) { [weak self] _ in
            Task { @MainActor [weak self] in guard let self,self.player === video else { return };self.completed=true;self.saveProgress();if let lease=self.cacheLease { self.cacheStore.markCompleted(lease) };self.beginNextCountdown() }
        }
        // Playback starts explicitly after readiness and resume seek.
    }
    func saveProgress() {
        guard !resumeSeeking,let context,let stream,let player,player.currentItem?.status == .readyToPlay else { return }
        let clock=player.currentTime().seconds
        guard clock.isFinite else { return }
        position=max(0,baseTime+clock)
        history.save(context,stream:stream,position:position,duration:duration,completed:completed)
        if CreditsTiming.reached(position:position,duration:duration,type:context.type),let nextEpisode,let nextStream { history.queueNext(nextEpisode,stream:nextStream) }
    }
    func selectSubtitle(_ index:Int?) {
        subtitleRequest=UUID()
        if let index,subtitleOptions.indices.contains(index) { subtitleSelection=subtitleOptions[index].extendedLanguageTag ?? subtitleOptions[index].displayName }
        else { subtitleSelection="off" }
        preferences.set(subtitleSelection,forKey:"binge.ipad.subtitleSelection");applySubtitlePreference()
    }
    func automaticSubtitles() { subtitleRequest=UUID();subtitleSelection="automatic";preferences.set(subtitleSelection,forKey:"binge.ipad.subtitleSelection");applySubtitlePreference() }
    private func applySubtitlePreference() {
        guard let group=subtitleGroup,let item=player?.currentItem else { return }
        player?.appliesMediaSelectionCriteriaAutomatically=false
        let option:AVMediaSelectionOption?
        if subtitleSelection=="off" { option=nil }
        else if subtitleSelection=="automatic" { option=group.options.first { $0.extendedLanguageTag?.hasPrefix("en")==true } ?? group.options.first }
        else if subtitleSelection.hasPrefix("online:") { option=group.options.first { $0.commonMetadata.contains(where:{$0.stringValue=="Online captions"}) || String(describing:$0.propertyList()).contains("Online captions") } }
        else { option=group.options.first { ($0.extendedLanguageTag ?? $0.displayName)==subtitleSelection } }
        item.select(option,in:group)
    }
    func refreshTimeline() {
        guard let player else { return }
        isPlaying=player.rate>0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        if loader?.supportsExternalCaptions == true,let cache {
            let text=(try? String(contentsOf:cache.appendingPathComponent("segments/media.m3u8"),encoding:.utf8)) ?? ""
            let prepared=text.components(separatedBy:"\n").filter {$0.hasPrefix("#EXTINF:")}.compactMap { Double($0.dropFirst(8).split(separator:",")[0]) }.reduce(0,+)
            let end=duration>0 ? min(duration,baseTime+prepared) : baseTime+prepared
            bufferedRanges=end>baseTime ? [baseTime...end] : []
        } else {
            bufferedRanges=(player.currentItem?.loadedTimeRanges ?? []).compactMap { value in
                let range=value.timeRangeValue,start=range.start.seconds+baseTime,end=range.start.seconds+range.duration.seconds+baseTime
                return start.isFinite && end.isFinite && end>start ? start...end : nil
            }
        }
    }
    func togglePlayback() {
        guard let player else { return }
        if player.rate>0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate { player.pause() } else { player.play() }
        refreshTimeline()
    }
    func seek(to seconds:Double) {
        guard seconds.isFinite,duration>0,let player,let stream else { return }
        seekError=nil
        countdownTask?.cancel();countdownTask=nil;nextCountdown=nil
        let target=max(0,min(duration-0.05,seconds)),playing=player.rate>0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        let local=target-baseTime
        var prepared=duration
        if loader?.supportsExternalCaptions == true,let cache {
            let playlist=(try? String(contentsOf:cache.appendingPathComponent("segments/media.m3u8"),encoding:.utf8)) ?? ""
            prepared=playlist.components(separatedBy:"\n").filter {$0.hasPrefix("#EXTINF:")}.compactMap { Double($0.dropFirst(8).split(separator:",")[0]) }.reduce(0,+)
        }
        if local>=0 && local<prepared {
            saveProgress();resumeSeeking=true
            let item=player.currentItem
            player.seek(to:CMTime(seconds:local,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero) { [weak self] success in
                Task { @MainActor [weak self] in
                    guard let self,self.player?.currentItem === item else { return }
                    self.resumeSeeking=false
                    if success { self.saveProgress();self.updateNextPrompt();if playing { player.play() } else { player.pause() } }
                    else { self.seekError="This source could not reach that time." }
                }
            }
        } else {
            let reusable=engine.videoSize()>0
            start(stream,context:context,fixture:fixture,reusingTorrent:reusable,resumeAt:target,autoplay:playing)
            message="Preparing the selected time…"
        }
    }
    func setForeground(_ active:Bool) { foreground=active }
    func dismissNext() { nextDismissed=true;showNext=false;nextCountdown=nil;countdownTask?.cancel();countdownTask=nil }
    func retry() { guard let stream else { return };start(stream,context:context,fixture:fixture) }
    func offerNext(_ context:IPadWatchContext,stream:AddonStream,thumbnail:URL?=nil) {
        nextEpisode=context;nextStream=stream;nextThumbnail=thumbnail;nextError=nil
        updateNextPrompt();if completed { beginNextCountdown() }
    }
    private func discoverNextEpisode() async {
        guard let context,context.type=="series" else { return }
        let request=generation
        do {
            let client=AddonClient(),catalog=try await AddonStore.shared.readyCatalog(type:context.type)
            let title=try await client.metadata(FoundTitle(title:CatalogTitle(id:context.titleID,type:context.type,name:context.name,poster:context.poster),addon:catalog))
            try Task.checkCancellation();guard generation==request else { return }
            let episodes=(title.videos ?? []).filter { ($0.season ?? 0)>0 }.sorted { (($0.season ?? 0),($0.episode ?? 0))<(($1.season ?? 0),($1.episode ?? 0)) }
            guard let index=episodes.firstIndex(where:{$0.id==context.contentID}),episodes.indices.contains(index+1) else { return }
            let next=episodes[index+1]
            if let date=next.released.flatMap({ISO8601DateFormatter().date(from:$0)}),date>Date() { return }
            nextEpisode=IPadWatchContext(title:title,episode:next);nextThumbnail=next.thumbnail
            updateNextPrompt();if completed { beginNextCountdown() }
        } catch { /* Discovery failure leaves normal playback available. */ }
    }
    private func updateNextPrompt() {
        if completed,duration>0,position<duration-5 {
            completed=false;countdownTask?.cancel();countdownTask=nil;nextCountdown=nil
            if let lease=cacheLease { cacheStore.markCompleted(lease,completed:false) }
        }
        guard nextEpisode != nil,!nextDismissed else { return }
        if completed || (duration>0 && duration-position<=max(60,min(duration*0.05,180))) {
            showNext=true
            if nextStream==nil && !nextBusy && nextError==nil { nextTask?.cancel();nextTask=Task { @MainActor [weak self] in await self?.prepareNextSource() } }
            if let nextStream,!preloadedNext,nextStream.infoHash != nil,nextStream.infoHash==stream?.infoHash,let index=nextStream.fileIdx,index != stream?.fileIdx,let cache {
                let size=engine.fileSize(Int32(index))
                let capacity=try? cache.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
                if size>0,size<=2*1024*1024*1024,let capacity,capacity>size*2+250*1024*1024 { preloadedNext=engine.prefetchFile(Int32(index)) }
            }
        } else { showNext=false }
    }
    private func prepareNextSource() async {
        guard let nextEpisode else { return }
        let request=generation
        nextBusy=true;nextError=nil;defer { if generation==request { nextBusy=false } }
        do {
            let sources=try await AddonStore.shared.readyStreams(type:nextEpisode.type,id:nextEpisode.contentID)
            try Task.checkCancellation();guard generation==request else { return }
            let candidates=IPadSourceOrder.sorted(sources).map(\.stream).filter {
                guard $0.playableSource != nil,SourcePolicy.bytes($0).map({$0<=2*1024*1024*1024}) ?? true else { return false }
                let text=$0.detail.lowercased()
                return !text.contains("av1")
            }
            let current=stream
            nextStream=candidates.first { $0.infoHash != nil && $0.infoHash==current?.infoHash && $0.fileIdx != nil && $0.fileIdx != current?.fileIdx }
                ?? candidates.first { $0.behaviorHints?.bingeGroup != nil && $0.behaviorHints?.bingeGroup==current?.behaviorHints?.bingeGroup && $0.resolution==current?.resolution }
                ?? candidates.first { $0.resolution==current?.resolution && $0.detail.lowercased().contains("aac") }
                ?? candidates.first { $0.resolution==current?.resolution }
                ?? candidates.first
            if nextStream==nil { nextError="No compatible source found for the next episode.";nextCountdown=nil;countdownTask?.cancel() }
            updateNextPrompt()
        } catch { if generation==request && !Task.isCancelled { nextError="Couldn’t load the next episode. Tap Play now to retry.";nextCountdown=nil;countdownTask?.cancel() } }
    }
    private func beginNextCountdown() {
        guard nextEpisode != nil,!nextDismissed,nextError==nil,countdownTask==nil else { return }
        showNext=true;nextCountdown=countdownSeconds
        countdownTask=Task { @MainActor [weak self] in
            while let self,let remaining=self.nextCountdown,remaining>0,!Task.isCancelled {
                try? await Task.sleep(for:.seconds(1));guard !Task.isCancelled else { return }
                if self.foreground { self.nextCountdown=remaining-1 }
            }
            guard let self,!Task.isCancelled else { return }
            self.countdownTask=nil
            await self.playNextNow(automatic:true)
        }
    }
    func playNextNow(automatic:Bool=false) async {
        let request=generation
        if automatic && (!completed || nextDismissed || !foreground) { return }
        countdownTask?.cancel();countdownTask=nil;nextCountdown=nil
        if nextStream==nil,nextBusy { await nextTask?.value }
        if nextStream==nil { await prepareNextSource() }
        guard generation==request,let nextEpisode,let nextStream else { return }
        if automatic && (!completed || nextDismissed || !foreground) { return }
        let same=nextStream.infoHash != nil && nextStream.infoHash==stream?.infoHash && nextStream.fileIdx != nil && nextStream.fileIdx != stream?.fileIdx && engine.videoSize()>0
        start(nextStream,context:nextEpisode,fixture:fixture,reusingTorrent:same)
    }
    func searchOnlineSubtitles() async {
        guard let context else { subtitleError="Title information is needed to search subtitles.";return }
        let request=generation
        subtitleBusy=true;subtitleError=nil;defer { if generation==request { subtitleBusy=false } }
        do {
            let client=AddonClient()
            await AddonStore.shared.ensureDefaults()
            guard let provider=AddonStore.shared.addons.first(where:{$0.manifest.supports("subtitles",type:context.type,id:context.contentID)}) else { subtitleError="Connect a subtitle add-on in Settings.";return }
            let response=try await client.fetch(IPadOnlineSubtitleResponse.self,url:AddonClient.endpoint(provider.manifestURL,components:["subtitles",context.type,context.contentID+".json"]))
            let found=response.subtitles.map(\.option)
            try Task.checkCancellation();guard generation==request else { return }
            var seen=Set<String>()
            onlineSubtitles=((stream?.subtitles ?? [])+found.map { value in var option=value;option.id=provider.manifest.id+":"+option.id;return option }).filter { seen.insert($0.id).inserted }
            if onlineSubtitles.isEmpty { subtitleError="No online subtitles were returned for this title." }
        } catch { if generation==request && !Task.isCancelled { subtitleError=error.localizedDescription } }
    }
    func selectOnlineSubtitle(_ option:SubtitleOption) async {
        guard loader?.supportsExternalCaptions == true else { subtitleError="Online captions currently require a prepared torrent source. Native tracks still work for other sources.";return }
        let request=generation,selection=UUID();subtitleRequest=selection
        subtitleBusy=true;subtitleError=nil;defer { if generation==request { subtitleBusy=false } }
        do {
            let cues=try await AddonClient().subtitleFile(option)
            try Task.checkCancellation();guard generation==request,subtitleRequest==selection,player != nil else { return }
            installOnlineCaptions(cues,option:option)
        } catch { if generation==request && !Task.isCancelled { subtitleError=error.localizedDescription } }
    }
    func installOnlineCaptions(_ cues:[SubtitleCue],option:SubtitleOption) {
        guard loader?.supportsExternalCaptions == true,let player,let url=playbackURL else { return }
        let clock=player.currentTime().seconds
        guard clock.isFinite else { return }
        let ready=player.currentItem?.status == .readyToPlay && !resumeSeeking
        let playing=ready ? (player.rate>0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate) : desiredPlay
        saveProgress();if ready { resumePosition=baseTime+clock }
        onlineCues=cues;onlineOption=option;subtitleSelection="online:"+option.lang
        preferences.set(subtitleSelection,forKey:"binge.ipad.subtitleSelection")
        if let data=try? JSONEncoder().encode(option) { preferences.set(data,forKey:"binge.ipad.onlineSubtitle") }
        loader?.setExternalCaptions(cues,language:option.lang,sourceOffset:baseTime,delay:subtitleDelay)
        var components=URLComponents(url:url,resolvingAgainstBaseURL:false)!
        components.queryItems=[URLQueryItem(name:"captions",value:UUID().uuidString)]
        play(components.url!,shouldPlay:playing)
    }
    func updateSubtitleDelay(_ seconds:Double) {
        subtitleDelay=max(-30,min(30,seconds));preferences.set(subtitleDelay,forKey:"binge.ipad.subtitleDelay")
        timingTask?.cancel()
        if subtitleSelection.hasPrefix("online:"),let cues=onlineCues,let option=onlineOption {
            timingTask=Task { @MainActor [weak self] in try? await Task.sleep(for:.milliseconds(500));guard !Task.isCancelled else { return };self?.installOnlineCaptions(cues,option:option) }
        }
    }
    private func restoreOnlineCaptions() async {
        guard let data=preferences.data(forKey:"binge.ipad.onlineSubtitle"),let saved=try? JSONDecoder().decode(SubtitleOption.self,from:data) else { return }
        // Re-discover URLs because provider download links may expire.
        await searchOnlineSubtitles()
        guard !Task.isCancelled,subtitleSelection.hasPrefix("online:") else { return }
        if let option=onlineSubtitles.first(where:{$0.id==saved.id}) ?? onlineSubtitles.first(where:{$0.lang==saved.lang}) { await selectOnlineSubtitle(option) }
    }
    private func fail(_ text:String,nativeError:Error?=nil) {
        if !recordedStartup,fixture==nil,let stream { SourceExperience.shared.record(stream,success:false);recordedStartup=true }
        #if DEBUG
        let diagnostic="Failure: \(text)\nNative error: \(String(describing:nativeError))\nError log: \(String(describing:player?.currentItem?.errorLog()?.events))\nMedia: \(media?.diagnostic() ?? "direct")\nTorrent: \(engine.snapshot())\n"
        try? diagnostic.write(to:FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("playback-failure.txt"),atomically:true,encoding:.utf8)
        if ProcessInfo.processInfo.arguments.contains("--hail-check"),let cache {
            let folder=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("diagnostic-hls")
            try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            for name in ["init.mp4","master.m3u8","media.m3u8","video-info.json","media0.m4s"] {
                let target=folder.appendingPathComponent(name)
                try? FileManager.default.removeItem(at:target)
                try? FileManager.default.copyItem(at:cache.appendingPathComponent("segments").appendingPathComponent(name),to:target)
            }
        }
        #endif
        stop(discard:!ProcessInfo.processInfo.arguments.contains("--hail-check"));message=text;failed=true
    }
    func stop(discard:Bool=false,reusingTorrent:Bool=false) {
        saveProgress()
        if let context,CreditsTiming.reached(position:position,duration:duration,type:context.type),let nextEpisode,let nextStream { history.queueNext(nextEpisode,stream:nextStream) }
        nextTask?.cancel();nextTask=nil;countdownTask?.cancel();countdownTask=nil
        nextEpisode=nil;nextStream=nil;nextThumbnail=nil;nextCountdown=nil;nextError=nil;nextBusy=false;showNext=false;nextDismissed=false;preloadedNext=false
        timingTask?.cancel();timingTask=nil;subtitleRequest=UUID();restoreTask?.cancel();restoreTask=nil;generation=UUID();subtitleBusy=false;playbackURL=nil
        if let timeObserver,let player { player.removeTimeObserver(timeObserver) };timeObserver=nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) };endObserver=nil
        subtitleOptions=[];subtitleGroup=nil
        let original=engine.selectedFilePath()
        let trimOriginal=cacheLease?.workerFinished == true && cache.map { FileManager.default.fileExists(atPath:$0.appendingPathComponent("prepared.json").path) } == true
        task?.cancel();task=nil;media?.cancel();media=nil;mediaFinished=false;observer=nil;player?.pause();player=nil;loader?.cancel();loader=nil
        if reusingTorrent {
            if completed,let original,let lease=cacheLease { cacheStore.rememberCompletedPayload(original,in:lease) }
        } else { engine.stop();if let lease=cacheLease { cacheStore.pruneCompleted(lease,except:original) } }
        if trimOriginal,!reusingTorrent,!discard,!completed,let original { VideoCacheCleanup.remove(URL(fileURLWithPath:original)) }
        if let lease=cacheLease,!reusingTorrent,(discard || completed || context == nil) { cacheStore.retire(lease) }
        cache=nil;cacheLease=nil
    }
}
struct IPadPlaybackView:View {
    var stream:AddonStream
    var title:String
    var context:IPadWatchContext?=nil
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session=IPadPlayback()
    @State private var subtitleSheet=false
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if session.player != nil { IPadMovieSurface(session:session,title:session.currentContext?.displayName ?? title,onBack:{dismiss()},onSearchSubtitles:{subtitleSheet=true},showLoadingCover:true,loadingPoster:session.currentContext?.poster ?? context?.poster) }
            else {
                if session.failed {
                    VStack(spacing:18) {
                        Image(systemName:"exclamationmark.circle").font(.largeTitle).foregroundStyle(Color(red:0.96,green:0.77,blue:0.36))
                        Text("Couldn’t start this video").font(.title3.bold())
                        Text(session.message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth:400)
                        Button("Try again") { session.retry() }.buttonStyle(.borderedProminent).foregroundStyle(.black)
                    }.padding(32)
                } else {
                    IPadCoverLoading(poster:session.currentContext?.poster ?? context?.poster,title:session.currentContext?.displayName ?? title,progress:session.progress)
                }
            }
        }.overlay(alignment:.topLeading) {
            if session.player == nil {
                HStack(spacing:18) {
                    Button { dismiss() } label: { Image(systemName:"chevron.left").font(.title3).frame(width:44,height:44).background(.black.opacity(0.4),in:Circle()) }.accessibilityLabel("Back")
                    Text(session.currentContext?.displayName ?? title).font(.headline).lineLimit(2)
                    Spacer()
                }.foregroundStyle(.white).padding(20)
            }
        }.overlay(alignment:.bottomTrailing) {
            if session.showNext,let next=session.nextEpisode { IPadUpNextCard(session:session,next:next).padding(.trailing,24).padding(.bottom,90) }
        }.navigationTitle(session.currentContext?.displayName ?? title).navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden,for:.navigationBar,.tabBar)
        .alert("Could not seek",isPresented:Binding(get:{session.seekError != nil},set:{if !$0 { session.seekError=nil }})) { Button("OK") { session.seekError=nil } } message: { Text(session.seekError ?? "") }
        .sheet(isPresented:$subtitleSheet) { IPadSubtitleSheet(session:session) }
        .onAppear { session.start(stream,context:context) }.onDisappear { session.stop() }
        .onChange(of:subtitleSheet) { _,shown in session.setForeground(scenePhase == .active && !shown) }
        .onChange(of:scenePhase) { _,phase in session.setForeground(phase == .active && !subtitleSheet);if phase != .active { session.saveProgress() } }
    }
}

struct IPadSubtitleSheet:View {
    @ObservedObject var session:IPadPlayback
    @State private var language="eng"
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        NavigationStack {
            List {
                Section("Language") {
                    Picker("Language",selection:$language) {
                        Text("All languages").tag("all")
                        ForEach(Array(Set(session.onlineSubtitles.map(\.lang)+["eng"])).sorted(),id:\.self) { code in Text(Locale.current.localizedString(forLanguageCode:code) ?? code).tag(code) }
                    }
                }
                Section("Online subtitles") {
                    if session.subtitleBusy { ProgressView("Loading subtitles…") }
                    if let error=session.subtitleError { Text(error).foregroundStyle(.secondary);Button("Try again") { Task { await session.searchOnlineSubtitles() } } }
                    ForEach(session.onlineSubtitles.filter { language=="all" || $0.lang==language }) { option in
                        Button { Task { await session.selectOnlineSubtitle(option);if session.subtitleError==nil { dismiss() } } } label: { VStack(alignment:.leading,spacing:5) { Text(option.displayName);Text((Locale.current.localizedString(forLanguageCode:option.lang) ?? option.lang)+" · OpenSubtitles").font(.caption).foregroundStyle(.secondary).lineLimit(1) } }.disabled(session.subtitleBusy)
                    }
                }
                Section("Timing") {
                    Stepper("Delay: \(session.subtitleDelay,specifier:"%+.1f") s",value:Binding(get:{session.subtitleDelay},set:{session.updateSubtitleDelay($0)}),in:-30...30,step:0.5)
                    Text("Positive delay shows online captions later. Native embedded tracks use their original timing.").font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("Subtitles").toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { dismiss() } } }
                .task { if session.onlineSubtitles.isEmpty { await session.searchOnlineSubtitles() } }
        }
    }
}

struct IPadOnlineSubtitleResponse:Decodable,Sendable {
    var subtitles:[Track]
    struct Track:Decodable,Sendable {
        var id:String
        var url:URL
        var lang:String
        var label:String?
        var subtitleFileName:String?
        var movieReleaseName:String?
        var option:SubtitleOption { SubtitleOption(id:id,url:url,lang:lang,label:label ?? subtitleFileName ?? movieReleaseName) }
    }
}

struct IPadUpNextCard:View {
    @ObservedObject var session:IPadPlayback
    var next:IPadWatchContext
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack(alignment:.top,spacing:12) {
                AsyncImage(url:session.nextThumbnail ?? next.poster) { image in image.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.08) }.frame(width:88,height:55).clipped().clipShape(RoundedRectangle(cornerRadius:9))
                VStack(alignment:.leading,spacing:5) { Text("UP NEXT").font(.caption2.weight(.semibold)).tracking(2).foregroundStyle(.yellow);Text(next.episodeLabel ?? next.name).font(.subheadline.weight(.semibold)).lineLimit(2) }
                Spacer(minLength:0)
                Button { session.dismissNext() } label: { Image(systemName:"xmark").font(.caption) }.buttonStyle(.plain).accessibilityLabel("Cancel next episode")
            }
            if let error=session.nextError { Text(error).font(.caption).foregroundStyle(.secondary) }
            HStack {
                if let countdown=session.nextCountdown { Text("Next episode starts in \(countdown)s").font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength:8)
                Button { Task { await session.playNextNow() } } label: { if session.nextBusy { ProgressView() } else { Label("Play now",systemImage:"play.fill").font(.subheadline.weight(.semibold)) } }.buttonStyle(.borderedProminent).tint(Color(red:0.96,green:0.77,blue:0.36)).foregroundStyle(.black).buttonBorderShape(.capsule).disabled(session.nextBusy)
            }
        }.padding(16).frame(maxWidth:340).background(.regularMaterial,in:RoundedRectangle(cornerRadius:18)).overlay(RoundedRectangle(cornerRadius:18).stroke(.white.opacity(0.12)))
    }
}

struct IPadSeekSheet:View {
    @ObservedObject var session:IPadPlayback
    @State private var target=0.0
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        NavigationStack {
            VStack(spacing:24) {
                Text("\(time(target)) / \(time(session.duration))").font(.title.monospacedDigit())
                Slider(value:$target,in:0...max(0.1,session.duration)).tint(.yellow)
                HStack { Button("−30 seconds") { target=max(0,target-30) };Spacer();Button("+30 seconds") { target=min(session.duration,target+30) } }
                Button("Jump to this time",systemImage:"play.fill") { session.seek(to:target);dismiss() }.buttonStyle(.borderedProminent).tint(.yellow).foregroundStyle(.black)
                Text("You can choose any point in the episode. An undownloaded section may need a short buffer.").font(.footnote).foregroundStyle(.secondary)
            }.padding(32).navigationTitle("Jump to time").toolbar { ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() } } }.onAppear { target=min(session.duration,session.position) }
        }.presentationDetents([.medium])
    }
    private func time(_ seconds:Double)->String { let value=Int(max(0,seconds));return value>=3600 ? String(format:"%d:%02d:%02d",value/3600,(value/60)%60,value%60) : String(format:"%d:%02d",value/60,value%60) }
}

struct IPadCoverLoading:View {
    var poster:URL?
    var title:String
    var progress:Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glowing=false
    @State private var filled=0.0
    private let accent=Color(red:0.96,green:0.77,blue:0.36)
    var body:some View {
        VStack(spacing:26) {
            ZStack {
                RoundedRectangle(cornerRadius:48).fill(accent).frame(width:180,height:245).blur(radius:44)
                    .opacity(glowing ? 0.22 : 0.10).scaleEffect(glowing ? 1.07 : 0.96)
                    .animation(reduceMotion ? nil : .easeInOut(duration:2.2).repeatForever(autoreverses:true),value:glowing)
                AsyncImage(url:poster) { phase in
                    if case .success(let image)=phase {
                        ZStack(alignment:.bottom) {
                            image.resizable().scaledToFill().frame(width:168,height:252).saturation(0).brightness(-0.15).opacity(0.6)
                            image.resizable().scaledToFill().frame(width:168,height:252)
                                .mask(alignment:.bottom) { Rectangle().frame(height:252*filled) }
                            if filled>0 && filled<1 {
                                Rectangle().fill(accent.opacity(0.7)).frame(height:1).shadow(color:accent,radius:8).offset(y:-252*filled)
                            }
                        }
                    } else {
                        ZStack {
                            LinearGradient(colors:[accent.opacity(0.15),.white.opacity(0.035)],startPoint:.topLeading,endPoint:.bottomTrailing)
                            Image(systemName:"film").font(.system(size:38,weight:.ultraLight)).foregroundStyle(accent)
                            Rectangle().fill(accent.opacity(0.15)).frame(height:252*filled).frame(maxHeight:.infinity,alignment:.bottom)
                        }
                    }
                }.frame(width:168,height:252).clipped().clipShape(RoundedRectangle(cornerRadius:15))
                    .overlay(RoundedRectangle(cornerRadius:15).strokeBorder(.white.opacity(0.12),lineWidth:1))
                    .shadow(color:.black.opacity(0.4),radius:18,y:10)
                    .animation(reduceMotion ? nil : .easeInOut(duration:0.5),value:filled)
            }.frame(height:275)
            HStack(spacing:10) {
                ProgressView().controlSize(.small).tint(accent)
                Text("Getting your video ready…").font(.system(size:17,weight:.medium,design:.rounded))
            }
        }.padding(32)
            .onAppear { filled=normalized(progress);glowing = !reduceMotion }
            .onChange(of:progress) { _,value in filled=max(filled,normalized(value)) }
            .onChange(of:reduceMotion) { _,value in glowing = !value }
            .accessibilityElement(children:.ignore).accessibilityLabel("Getting \(title) ready")
    }
    private func normalized(_ value:Double)->Double { value.isFinite ? min(1,max(0,value)) : 0 }
}
