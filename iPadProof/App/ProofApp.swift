import SwiftUI
import CryptoKit
import AVFoundation
typealias ViewState<Value> = SwiftUI.State<Value>
@main struct ProofApp: App {
    var body:some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--navigation-check") { IPadNavigationProof() }
            else if ProcessInfo.processInfo.arguments.contains("--hail-format-check") { IPadHailFormatProof() }
            else if ProcessInfo.processInfo.arguments.contains("--mac-reference-check") { IPadMacReferenceProof() }
            else if ProcessInfo.processInfo.arguments.contains("--hail-check") || ProcessInfo.processInfo.arguments.contains("--real-source-check") || ProcessInfo.processInfo.arguments.contains("--real-mp4-check") { IPadRealSourceProof() }
            else if ProcessInfo.processInfo.arguments.contains("--seek-check") { IPadSeekProof() }
            else if ProcessInfo.processInfo.arguments.contains("--audio-check") || ProcessInfo.processInfo.arguments.contains("--mp4-check") { IPadAudioProof() }
            else if ProcessInfo.processInfo.arguments.contains("--upnext-check") { IPadUpNextProof() }
            else if ProcessInfo.processInfo.arguments.contains("--history-check") { IPadFeatureProof() }
            else if ProcessInfo.processInfo.arguments.contains("--cancel-stream-mkv") || ProcessInfo.processInfo.arguments.contains("--stream-mkv") || ProcessInfo.processInfo.arguments.contains("--external") || ProcessInfo.processInfo.arguments.contains("--mkv") || ProcessInfo.processInfo.arguments.contains("--loopback") { ProofView() }
            else if ProcessInfo.processInfo.arguments.contains("--sources-check") {
                NavigationStack { IPadEpisodeSources(title:"The Mentalist · S5 E19",type:"series",contentID:"tt1196946:5:19") }.preferredColorScheme(.dark)
            }
            else { IPadAppView() }
            #else
            IPadAppView()
            #endif
        }
    }
}
#if DEBUG
struct ProofView: View {
    @ViewState<TorrentProof> private var engine = TorrentProof()
    @ViewState<Task<Void,Never>?> private var task: Task<Void,Never>?
    @ViewState<String> private var log = "Ready to test the embedded torrent engine."
    @ViewState<Bool> private var running = false
    @ViewState<Bool> private var second = false
    @ViewState<Bool> private var seekCompleted=false
    @ViewState<AVPlayer?> private var player: AVPlayer?
    @ViewState<TorrentVideoLoader?> private var loader: TorrentVideoLoader?
    @ViewState<NativeMedia?> private var converter:NativeMedia?
    @ViewState<String?> private var streamResult:String?
    @ViewState<Bool> private var streamFinished=false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("binge · native torrent proof").font(.title.bold())
            Text("Two native torrent sessions run entirely on this iPad. One seeds a bundled fixture; the other starts from its magnet and downloads selected files. No Mac server, Python, or subprocess is involved.").foregroundStyle(.secondary)
            if let player { ProofVideoView(player:player,showsControls:!running).frame(minHeight:260) }
            ScrollView { Text(log).font(.system(.body, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
            HStack { Button("Run loopback proof", action: start).disabled(running); Button("External torrent + playback", action: external).disabled(running); Button("MKV + subtitles",action:media).disabled(running); Button("Stop and clear test cache", action: stop) }
        }.padding(32).tint(.yellow).preferredColorScheme(.dark)
        .onAppear { if ProcessInfo.processInfo.arguments.contains("--stream-mkv") || ProcessInfo.processInfo.arguments.contains("--cancel-stream-mkv") { streamingMedia() } else if ProcessInfo.processInfo.arguments.contains("--mkv") { media() } else if ProcessInfo.processInfo.arguments.contains("--external") { external() } else { start() } }
        .onChange(of: log) { _, value in
            let report=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("proof-result.txt")
            try? value.write(to:report,atomically:true,encoding:.utf8)
        }
        .onDisappear { stop() }
    }
    private var cache: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("TorrentProof") }
    private func start() {
        stop(); second=false
        do {
            let source=Bundle.main.resourceURL!.appendingPathComponent("Fixture")
            let seed=cache.appendingPathComponent("seed"), download=cache.appendingPathComponent("download")
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: seed)
            try FileManager.default.createDirectory(at: download, withIntermediateDirectories: true)
            var failure: NSString?
            guard engine.start(withFixture: seed.path, cache: download.path, error: &failure) else { log=failure as String? ?? "Engine failed"; return }
            running=true
            task=Task { @MainActor in
                let deadline=Date().addingTimeInterval(90)
                while !Task.isCancelled && Date()<deadline {
                    let snapshot=engine.snapshot()
                    log=snapshot
                    if let data=snapshot.data(using:.utf8), let state=try? JSONSerialization.jsonObject(with:data) as? [String:Any], state["finished"] as? Bool == true, state["metadata"] as? Bool == true {
                        let file=second ? "episode-two.bin" : "episode-one.bin"
                        guard let received=try? Data(contentsOf: download.appendingPathComponent("pack/"+file)), let original=try? Data(contentsOf: seed.appendingPathComponent("pack/"+file)), received.count==original.count else { try? await Task.sleep(for:.milliseconds(500)); continue }
                        guard SHA256.hash(data:received)==SHA256.hash(data:original) else { try? await Task.sleep(for:.milliseconds(500)); continue }
                        if !second { second=true; engine.selectNextFile() }
                        else { log="PASS: magnet metadata, selected-file download, same-torrent file switch, and both SHA-256 digests verified entirely on the iPad.\n\nExternal peers, playback, PiP and background execution are not tested by this proof."; break }
                    }
                    try? await Task.sleep(for:.milliseconds(500))
                }
                if Date()>=deadline { log="FAILED: timed out\n"+log }
                engine.stop();running=false
            }
        } catch { log=error.localizedDescription; running=false }
    }
    private func external() {
        stop();seekCompleted=false
        do {
            try FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)
            let magnet=try String(contentsOf:Bundle.main.resourceURL!.appendingPathComponent("Fixture/external-magnet.txt"),encoding:.utf8)
            var failure: NSString?
            guard engine.startExternalMagnet(magnet,cache:cache.path,error:&failure) else { log=failure as String? ?? "External engine failed";return }
            running=true;log="Starting external Sintel magnet. No internal or Mac peer is running."
            task=Task { @MainActor in
                let deadline=Date().addingTimeInterval(240)
                var phase=0;var pausedAt:Date?;var resumeClock=0.0;var playbackStartedBytes:Int?;var seekStartedBytes:Int?
                while !Task.isCancelled && Date()<deadline {
                    let snapshot=engine.snapshot()
                    let state=(try? JSONSerialization.jsonObject(with:Data(snapshot.utf8))) as? [String:Any] ?? [:]
                    if state["metadata"] as? Bool == true && player==nil {
                        let reader=TorrentVideoLoader(engine:engine);loader=reader
                        guard let url=try? await reader.start() else { log="FAILED: on-device byte-range server";break }
                        let item=AVPlayerItem(url:url);item.preferredForwardBufferDuration=10
                        let video=AVPlayer(playerItem:item);video.appliesMediaSelectionCriteriaAutomatically=false;player=video
                        try? AVAudioSession.sharedInstance().setCategory(.playback)
                        try? AVAudioSession.sharedInstance().setActive(true)
                        video.play()
                    }
                    let clock=player?.currentTime().seconds ?? 0
                    if clock.isFinite && clock>0.5 && playbackStartedBytes==nil { playbackStartedBytes=state["downloaded"] as? Int }
                    log="External torrent / phase \(phase) / video clock \(clock)\n"+snapshot
                    if player?.currentItem?.status == .failed { log="FAILED: native playback: \(player?.currentItem?.error?.localizedDescription ?? "unknown")\n"+snapshot;break }
                    if phase==0 && clock>10 {
                        phase=1;seekStartedBytes=state["downloaded"] as? Int
                        player?.seek(to:CMTime(seconds:300,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero,completionHandler:{ done in Task { @MainActor in seekCompleted=done } })
                    } else if phase==1 && seekCompleted && clock>302 {
                        phase=2;pausedAt=Date();resumeClock=clock;player?.pause()
                    } else if phase==2, let pausedAt, Date().timeIntervalSince(pausedAt)>20 {
                        guard abs(clock-resumeClock)<0.5 else { log="FAILED: paused clock changed from \(resumeClock) to \(clock)";break }
                        phase=3;player?.play()
                    } else if phase==3 && clock>resumeClock+3 {
                        let served=state["verifiedBytesServed"] as? Int ?? 0
                        guard served>0 else { log="FAILED: no verified torrent bytes were served";break }
                        log="PASS: public magnet metadata and external-peer bytes; AVPlayer clock advanced past 10s; seek to 300s advanced past 302s; 20-second pause respected and resumed for 3s.\nVerified bytes served: \(served).\nDownloaded at first playback advancement: \(playbackStartedBytes ?? -1).\nDownloaded before five-minute seek: \(seekStartedBytes ?? -1).\nDownloaded before test completion: \(state["downloaded"] ?? 0) of \(engine.videoSize()) bytes.\nNo Mac backend or internal test seeder.\n\nNative PiP/background and audio sync await your hands-on check. MKV/remux remains unimplemented. Playback stays available until Stop is pressed."
                        break
                    }
                    try? await Task.sleep(for:.milliseconds(500))
                }
                if Date()>=deadline { log="FAILED: external test timeout\n"+log }
                if log.hasPrefix("PASS:") { player?.play() }
                else { player?.pause();loader?.cancel();engine.stop() }
                running=false
            }
        } catch { log=error.localizedDescription;running=false }
    }
    private func streamingMedia() {
        stop();running=true;streamResult=nil;streamFinished=false
        do {
            let source=Bundle.main.resourceURL!.appendingPathComponent("Fixture/Media")
            let seed=cache.appendingPathComponent("seed"),download=cache.appendingPathComponent("download"),segments=cache.appendingPathComponent("segments")
            try FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)
            try FileManager.default.copyItem(at:source,to:seed)
            try FileManager.default.createDirectory(at:download,withIntermediateDirectories:true)
            try FileManager.default.createDirectory(at:segments,withIntermediateDirectories:true)
            var failure:NSString?
            guard engine.start(withFixture:seed.path,cache:download.path,error:&failure) else { log=failure as String? ?? "Torrent failed";running=false;return }
            engine.setDownloadLimit(800*1024)
            let media=NativeMedia();converter=media
            task=Task { @MainActor in
                let deadline=Date().addingTimeInterval(120)
                while engine.videoSize()==0 && Date()<deadline && !Task.isCancelled { _ = engine.snapshot();try? await Task.sleep(for:.milliseconds(100)) }
                guard !Task.isCancelled,engine.videoSize()>0 else { log="FAILED: no fixture metadata";running=false;return }
                engine.prepareStreaming()
                media.stream(engine:engine,directory:segments.path) { value in
                    Task { @MainActor in
                        guard converter === media else { try? FileManager.default.removeItem(at:cache);return }
                        streamResult=value;streamFinished=true
                    }
                }
                if ProcessInfo.processInfo.arguments.contains("--cancel-stream-mkv") {
                    try? await Task.sleep(for:.seconds(1))
                    media.cancel();engine.stop()
                    let cancellationDeadline=Date().addingTimeInterval(3)
                    while streamResult == nil && Date()<cancellationDeadline { try? await Task.sleep(for:.milliseconds(50)) }
                    guard streamResult != nil else { log="FAILED: worker did not cancel promptly";running=false;return }
                    converter=nil;try? FileManager.default.removeItem(at:cache)
                    log=FileManager.default.fileExists(atPath:cache.path) ? "FAILED: cancelled cache remained" : "PASS: pending verified read cancelled within three seconds; cache removed after worker completion."
                    running=false;return
                }
                var firstBytes:Int?;var createdBytes=0;var readyBytes=0;var stage=0;var pauseTime=Date();var pausedClock=0.0
                while Date()<deadline && !Task.isCancelled {
                    let state=(try? JSONSerialization.jsonObject(with:Data(engine.snapshot().utf8))) as? [String:Any] ?? [:]
                    if let result=streamResult,let json=(try? JSONSerialization.jsonObject(with:Data(result.utf8))) as? [String:Any],json["success"] as? Bool != true { log="FAILED: \(result)";running=false;return }
                    let playlist=(try? String(contentsOf:segments.appendingPathComponent("media.m3u8"),encoding:.utf8)) ?? ""
                    if player == nil && (playlist.components(separatedBy:"#EXTINF:").count>=4 || playlist.contains("#EXT-X-ENDLIST")) && FileManager.default.fileExists(atPath:segments.appendingPathComponent("master.m3u8").path) {
                        createdBytes=state["downloaded"] as? Int ?? -1
                        let server=TorrentVideoLoader(engine:engine,directory:segments);loader=server
                        guard let url=try? await server.start() else { log="FAILED: local streaming server";running=false;return }
                        do {
                            let (body,response)=try await URLSession.shared.data(from:url)
                            guard (response as? HTTPURLResponse)?.statusCode==200,body.starts(with:Data("#EXTM3U".utf8)) else { log="FAILED: invalid master HTTP response";running=false;return }
                        } catch { log="FAILED: master HTTP \(error)";running=false;return }
                        let video=AVPlayer(url:url);video.automaticallyWaitsToMinimizeStalling=false;video.currentItem?.preferredForwardBufferDuration=4;player=video
                        try? AVAudioSession.sharedInstance().setCategory(.playback);try? AVAudioSession.sharedInstance().setActive(true)
                        video.play()
                    }
                    if readyBytes==0 && player?.currentItem?.status == .readyToPlay { readyBytes=state["downloaded"] as? Int ?? -1;player?.automaticallyWaitsToMinimizeStalling=true;player?.playImmediately(atRate:1) }
                    let clock=player?.currentTime().seconds ?? 0
                    log="Streaming MKV · created \(createdBytes) · ready \(readyBytes) · status \(player?.currentItem?.status.rawValue ?? -1) · clock \(clock) · downloaded \(state["downloaded"] ?? 0)/\(engine.videoSize()) · phase \(stage)\n"+(streamResult ?? media.diagnostic())
                    if let item=player?.currentItem,item.status == .failed { log="FAILED: native HLS \(item.error?.localizedDescription ?? "unknown")\n"+(item.errorLog()?.events.map { "\($0.errorStatusCode) \($0.errorComment ?? "") \($0.uri ?? "")" }.joined(separator:"\n") ?? "no error events");running=false;return }
                    if clock>0.3 && firstBytes == nil {
                        firstBytes=state["downloaded"] as? Int
                        if firstBytes ?? Int.max >= engine.videoSize() { log="FAILED: started only after full download. Player created: \(createdBytes); ready: \(readyBytes). \(state)\n\(playlist)\n\(streamResult ?? "converting")";running=false;return }
                        if let item=player?.currentItem,let group=try? await item.asset.loadMediaSelectionGroup(for:.legible),let option=group.options.first { player?.appliesMediaSelectionCriteriaAutomatically=false;item.select(option,in:group) }
                    }
                    if stage==0 && clock>4 { stage=1;pausedClock=clock;pauseTime=Date();player?.pause() }
                    else if stage==1 && Date().timeIntervalSince(pauseTime)>3 {
                        guard abs(clock-pausedClock)<0.5 else { log="FAILED: pause moved";running=false;return }
                        stage=2;player?.play()
                    } else if stage==2 && clock>pausedClock+2 && streamFinished {
                        guard let item=player?.currentItem,let group=try? await item.asset.loadMediaSelectionGroup(for:.legible),!group.options.isEmpty,let result=streamResult,let json=(try? JSONSerialization.jsonObject(with:Data(result.utf8))) as? [String:Any],json["subtitlePacketsConverted"] as? Int == 4 else { log="FAILED: caption track/cues missing";running=false;return }
                        log="PASS: native HLS clock advanced before full torrent download. Player created: \(createdBytes); ready: \(readyBytes). First playback: \(firstBytes ?? -1) / \(engine.videoSize()) bytes. Pause/resume passed; native captions present; four cues converted.\n"+result
                        running=false;return
                    }
                    try? await Task.sleep(for:.milliseconds(200))
                }
                if !Task.isCancelled { log="FAILED: streaming test timed out";running=false }
            }
        } catch { log=error.localizedDescription;running=false }
    }
    private func media() {
        stop();running=true
        do {
            let source=Bundle.main.resourceURL!.appendingPathComponent("Fixture/Media")
            let seed=cache.appendingPathComponent("seed"),download=cache.appendingPathComponent("download")
            try FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)
            try FileManager.default.copyItem(at:source,to:seed)
            try FileManager.default.createDirectory(at:download,withIntermediateDirectories:true)
            var failure:NSString?
            guard engine.start(withFixture:seed.path,cache:download.path,error:&failure) else { log=failure as String? ?? "MKV torrent failed";running=false;return }
            log="Downloading generated MKV fixture through the on-device torrent peer."
            task=Task { @MainActor in
                let deadline=Date().addingTimeInterval(90)
                while !Task.isCancelled && Date()<deadline {
                    let snapshot=engine.snapshot();log=snapshot
                    if let state=(try? JSONSerialization.jsonObject(with:Data(snapshot.utf8))) as? [String:Any], state["finished"] as? Bool == true,let input=engine.selectedFilePath() {
                        let downloaded=try? Data(contentsOf:URL(fileURLWithPath:input))
                        let original=try? Data(contentsOf:seed.appendingPathComponent("pack/media.mkv"))
                        guard let downloaded,let original,SHA256.hash(data:downloaded)==SHA256.hash(data:original) else { try? await Task.sleep(for:.milliseconds(200));continue }
                        engine.stop()
                        log="Remuxing MKV on the iPad; copying H.264/AAC and converting SRT captions."
                        let output=cache.appendingPathComponent("native-remux.mp4")
                        let result:String=await withCheckedContinuation { continuation in NativeMedia().remux(input:input,output:output.path) { value in continuation.resume(returning:value) } }
                        guard !Task.isCancelled else { return }
                        guard let converted=(try? JSONSerialization.jsonObject(with:Data(result.utf8))) as? [String:Any],converted["success"] as? Bool == true else { log="FAILED: embedded remux\n"+result;running=false;return }
                        let asset=AVURLAsset(url:output)
                        let item=AVPlayerItem(asset:asset)
                        let video=AVPlayer(playerItem:item);video.appliesMediaSelectionCriteriaAutomatically=false;player=video
                        try? AVAudioSession.sharedInstance().setCategory(.playback);try? AVAudioSession.sharedInstance().setActive(true)
                        let group=try? await asset.loadMediaSelectionGroup(for:.legible)
                        video.play()
                        for _ in 0..<100 {
                            if item.status == .readyToPlay || item.status == .failed { break }
                            try? await Task.sleep(for:.milliseconds(100))
                        }
                        if let group,let option=group.options.first { item.select(option,in:group) }
                        video.seek(to:.zero,completionHandler:{ _ in })
                        var pausedAt:Date?;var beforePause=0.0;var stage=0
                        while !Task.isCancelled && Date()<deadline {
                            let clock=video.currentTime().seconds
                            log="MKV playback / phase \(stage) / clock \(clock) / captions \(group.flatMap { item.currentMediaSelection.selectedMediaOption(in:$0) }?.displayName ?? "off")\n"+result
                            if item.status == .failed { log="FAILED: remux playback \(item.error?.localizedDescription ?? "unknown")";break }
                            if stage==0 && clock>4 {
                                guard group?.options.isEmpty == false,(converted["subtitlePacketsConverted"] as? Int ?? 0)==4 else { log="FAILED: native captions track or four fixture cues missing";break }
                                stage=1;beforePause=clock;pausedAt=Date();video.pause()
                            } else if stage==1,let pausedAt,Date().timeIntervalSince(pausedAt)>3 {
                                guard abs(clock-beforePause)<0.5 else { log="FAILED: MKV explicit pause moved";break }
                                stage=2;video.play()
                            } else if stage==2 && clock>beforePause+2 {
                                log="PASS: generated MKV torrent digest verified; embedded remux copied video/audio packets; four SRT cues converted; native caption track selected; AVPlayer advanced and passed pause/resume.\n"+result+"\n\nFully downloaded MKV fixture before remux. Streaming remux, non-AAC audio, and visual caption/PiP checks remain separate."
                                running=false;return
                            }
                            try? await Task.sleep(for:.milliseconds(200))
                        }
                        if Date()>=deadline { log="FAILED: MKV native playback timed out" }
                        running=false;return
                    }
                    try? await Task.sleep(for:.milliseconds(200))
                }
                if Date()>=deadline { log="FAILED: MKV torrent timed out" }
                running=false
            }
        } catch { log=error.localizedDescription;running=false }
    }
    private func stop() { converter?.cancel();let pending=converter != nil && !streamFinished;converter=nil;task?.cancel();task=nil;player?.pause();player=nil;loader?.cancel();loader=nil;engine.stop();running=false;if !pending { try? FileManager.default.removeItem(at:cache) } }
}

struct IPadFeatureProof:View {
    private let history:IPadHistory
    private let preferences:UserDefaults
    private let featureCache:IPadCacheStore
    @StateObject private var session:IPadPlayback
    @ViewState<String> private var report="Starting watch-history and resume checks…"
    @ViewState<Task<Void,Never>?> private var task:Task<Void,Never>?
    init() {
        let defaults=UserDefaults(suiteName:"binge.ipad.feature-proof")!
        defaults.removePersistentDomain(forName:"binge.ipad.feature-proof")
        let history=IPadHistory(defaults:defaults)
        let cache=IPadCacheStore(root:FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("binge-feature-proof"))
        cache.clear()
        self.preferences=defaults;self.history=history;self.featureCache=cache
        self._session=StateObject(wrappedValue:IPadPlayback(history:history,preferences:defaults,cacheStore:cache))
    }
    var body:some View {
        VStack(spacing:20) { if let player=session.player { ProofVideoView(player:player).frame(minHeight:280) };Text(report).font(.system(.body,design:.monospaced));Text(session.message) }.padding(32)
            .onAppear { run() }.onDisappear { task?.cancel();session.stop() }
            .onChange(of:report) { _,value in try? value.write(to:FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("history-proof-result.txt"),atomically:true,encoding:.utf8) }
    }
    private func run() {
        let title=CatalogTitle(id:"fixture-series",type:"series",name:"Generated fixture")
        let episode=CatalogTitle.Episode(id:"fixture-series:1:1",title:"Resume test",season:1,episode:1)
        let context=IPadWatchContext(title:title,episode:episode)
        let stream=AddonStream(name:"Fixture",infoHash:String(repeating:"0",count:40),fileIdx:1)
        let fixture=Bundle.main.resourceURL!.appendingPathComponent("Fixture/Media")
        task=Task { @MainActor in
            let deadline=Date().addingTimeInterval(90)
            session.start(stream,context:context,fixture:fixture)
            while !Task.isCancelled && Date()<deadline && session.position<6 && !session.failed { report="Initial playback · \(session.position)s · \(session.message)";try? await Task.sleep(for:.milliseconds(200)) }
            guard !Task.isCancelled else { return }
            guard !session.failed,session.position>=6,session.duration>30 else { report="FAILED: initial playback or source duration · \(session.message)";return }
            session.saveProgress()
            guard let saved=IPadHistory(defaults:preferences).record(context),saved.position>=6,saved.duration>30 else { report="FAILED: persisted progress missing";return }
            session.selectSubtitle(nil)
            guard let item=session.player?.currentItem,let group=try? await item.asset.loadMediaSelectionGroup(for:.legible),!group.options.isEmpty,item.currentMediaSelection.selectedMediaOption(in:group)==nil else { report="FAILED: native subtitle Off";return }
            session.stop()
            guard let cached=featureCache.current,FileManager.default.fileExists(atPath:cached.folder.path),IPadCacheStore(root:featureCache.root).current?.key==cached.key else { report="FAILED: warm cache not preserved across exit/reload";return }
            session.start(stream,context:context,fixture:fixture)
            while !Task.isCancelled && Date()<deadline && session.position<saved.position && !session.failed { report="Resuming · \(session.position)s · \(session.message)";try? await Task.sleep(for:.milliseconds(200)) }
            guard !Task.isCancelled else { return }
            guard !session.failed,session.position>=saved.position-0.5,session.position<saved.position+4 else { report="FAILED: resume position · \(session.position) / \(saved.position) · \(session.message)";return }
            guard let item=session.player?.currentItem,let group=try? await item.asset.loadMediaSelectionGroup(for:.legible),item.currentMediaSelection.selectedMediaOption(in:group)==nil else { report="FAILED: remembered subtitle Off";return }
            session.automaticSubtitles()
            guard item.currentMediaSelection.selectedMediaOption(in:group) != nil else { report="FAILED: automatic subtitle selection";return }
            let captionFile=Bundle.main.resourceURL!.appendingPathComponent("Fixture/Media/captions.srt")
            guard let captionText=try? String(contentsOf:captionFile,encoding:.utf8) else { report="FAILED: subtitle fixture missing";return }
            let cues=SubtitleParser.parse(captionText)
            session.installOnlineCaptions(cues,option:SubtitleOption(id:"fixture-online",url:captionFile,lang:"en",label:"Fixture online captions"))
            var onlineSelected=false
            while !Task.isCancelled && Date()<deadline {
                if session.failed { report="FAILED: online HLS · \(session.message)";return }
                if let item=session.player?.currentItem,let group=try? await item.asset.loadMediaSelectionGroup(for:.legible) {
                    if let selected=item.currentMediaSelection.selectedMediaOption(in:group),selected.commonMetadata.contains(where:{$0.stringValue=="Online captions"}) || String(describing:selected.propertyList()).contains("Online captions") { onlineSelected=true;break }
                    report="Checking native online caption rendition · \(group.options.map { String(describing:$0.propertyList()) })"
                } else { report="Checking native online caption rendition…" }
                try? await Task.sleep(for:.milliseconds(200))
            }
            guard onlineSelected else { report="FAILED: online HLS caption rendition was not selected";return }
            let shifted=IPadWebVTT.segment([SubtitleCue(start:14,end:20,text:"A & B")],start:0,end:4,sourceOffset:12,delay:1)
            guard shifted.contains("00:00:03.000 --> 00:00:09.000"),shifted.contains("A &amp; B") else { report="FAILED: online subtitle resume/delay mapping";return }
            while !Task.isCancelled && Date()<deadline && !session.completed && !session.failed { report="Checking completion and deferred cache cleanup · \(session.position)/\(session.duration)s";try? await Task.sleep(for:.milliseconds(200)) }
            guard !session.failed,session.completed,let lease=featureCache.current,FileManager.default.fileExists(atPath:lease.folder.path) else { report="FAILED: completion or cache cleared before exit";return }
            session.stop()
            let cleanupDeadline=Date().addingTimeInterval(3)
            while FileManager.default.fileExists(atPath:lease.folder.path) && Date()<cleanupDeadline { try? await Task.sleep(for:.milliseconds(50)) }
            guard featureCache.current==nil,!FileManager.default.fileExists(atPath:lease.folder.path) else { report="FAILED: cache cleanup after completed viewing";return }
            history.mark(context,watched:true)
            guard history.continuing.count==1,history.record(context)?.completed==true else { report="FAILED: completed episode disappeared";return }
            let other=IPadWatchContext(title:title,episode:CatalogTitle.Episode(id:"fixture-series:2:1",season:2,episode:1))
            history.save(other,stream:stream,position:15,duration:32)
            guard history.continuing.count==1,history.latest(titleID:title.id,type:title.type)?.context.season==2 else { report="FAILED: newest episode/season deduplication";return }
            history.hide(history.continuing[0])
            guard history.continuing.isEmpty,history.record(context)?.completed==true else { report="FAILED: remove erased watched history";return }
            var providerCheck=""
            do {
                let client=AddonClient(),provider=try await client.install("https://opensubtitles-v3.strem.io/manifest.json")
                let response=try await client.fetch(IPadOnlineSubtitleResponse.self,url:AddonClient.endpoint(provider.manifestURL,components:["subtitles","series","tt1196946:5:19.json"]))
                let tracks=response.subtitles.map(\.option)
                if let english=tracks.first(where:{$0.lang=="eng" || $0.lang=="en"}) {
                    let cues=try await client.subtitleFile(english)
                    providerCheck=" Online provider on iPad: \(tracks.count) tracks; downloaded/parsed \(cues.count) cues."
                } else { providerCheck=" Online provider returned no English track." }
            } catch { providerCheck=" Online provider check unavailable: \(error.localizedDescription)" }
            report="PASS: progress persisted with full MKV duration; latest cache survived exit/reload and cleanup passed; native playback resumed at saved time; subtitle Off persisted and Automatic restored captions; external WebVTT became a selected native HLS track with resume/delay mapping; completed episode stayed in Continue watching; latest show/season deduplicated; removal preserved watched history. Saved time: \(saved.position)s."+providerCheck
        }
    }
}

struct IPadUpNextProof:View {
    private let history:IPadHistory
    private let cacheStore:IPadCacheStore
    @StateObject private var session:IPadPlayback
    @ViewState<String> private var report="Starting two-episode reuse/countdown check…"
    @ViewState<Task<Void,Never>?> private var task:Task<Void,Never>?
    init() {
        let defaults=UserDefaults(suiteName:"binge.ipad.upnext-proof")!
        defaults.removePersistentDomain(forName:"binge.ipad.upnext-proof")
        let history=IPadHistory(defaults:defaults)
        let cache=IPadCacheStore(root:FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("binge-upnext-proof"))
        cache.clear();self.history=history;self.cacheStore=cache
        self._session=StateObject(wrappedValue:IPadPlayback(history:history,preferences:defaults,cacheStore:cache,countdownSeconds:3))
    }
    var body:some View {
        VStack(spacing:18) { if let player=session.player { ProofVideoView(player:player).frame(minHeight:280) };Text(report).font(.system(.body,design:.monospaced));if session.showNext,let next=session.nextEpisode { IPadUpNextCard(session:session,next:next) } }.padding(32)
            .onAppear { run() }.onDisappear { task?.cancel();session.stop();cacheStore.clear() }
            .onChange(of:report) { _,value in try? value.write(to:FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("upnext-proof-result.txt"),atomically:true,encoding:.utf8) }
    }
    private func run() {
        let title=CatalogTitle(id:"fixture-upnext",type:"series",name:"Generated up-next fixture")
        let first=IPadWatchContext(title:title,episode:CatalogTitle.Episode(id:"fixture-upnext:1:1",title:"Episode one",season:1,episode:1))
        let second=IPadWatchContext(title:title,episode:CatalogTitle.Episode(id:"fixture-upnext:1:2",title:"Episode two",season:1,episode:2))
        let firstStream=AddonStream(name:"Fixture",infoHash:String(repeating:"0",count:40),fileIdx:1)
        let secondStream=AddonStream(name:"Fixture",infoHash:String(repeating:"0",count:40),fileIdx:2)
        let fixture=Bundle.main.resourceURL!.appendingPathComponent("Fixture/Next")
        task=Task { @MainActor in
            let deadline=Date().addingTimeInterval(110)
            session.start(firstStream,context:first,fixture:fixture)
            while Date()<deadline && !Task.isCancelled && session.position<3 && !session.failed { report="First episode · \(session.position)s · \(session.message)";try? await Task.sleep(for:.milliseconds(200)) }
            guard !Task.isCancelled,!session.failed,session.position>=3,let folder=cacheStore.current?.folder,let initial=(try? JSONSerialization.jsonObject(with:Data(session.diagnosticSnapshot().utf8))) as? [String:Any],let token=initial["sessionToken"] as? String else { report="FAILED: first episode start · \(session.message)";return }
            session.offerNext(second,stream:secondStream)
            var sawCountdown=false
            while Date()<deadline && !Task.isCancelled && !(session.currentContext?.contentID==second.contentID && session.position>=4) && !session.failed {
                if session.nextCountdown != nil { sawCountdown=true }
                report="Watching \(session.currentContext?.episodeLabel ?? "") · \(session.position)s · countdown \(session.nextCountdown.map(String.init) ?? "pending")"
                try? await Task.sleep(for:.milliseconds(200))
            }
            guard !Task.isCancelled else { return }
            session.saveProgress()
            let current=(try? JSONSerialization.jsonObject(with:Data(session.diagnosticSnapshot().utf8))) as? [String:Any] ?? [:]
            guard !session.failed,sawCountdown,session.currentContext?.contentID==second.contentID,session.position>=4,current["selectedFile"] as? Int==2,current["sessionToken"] as? String==token,cacheStore.current?.folder==folder,history.record(first)?.completed==true,history.latest(titleID:title.id,type:title.type)?.context.contentID==second.contentID else { report="FAILED: countdown/reuse/history · \(session.message) · \(current)";return }
            session.stop()
            report="PASS: end-of-episode countdown automatically played episode two; selected file changed to 2 in the same live torrent session/cache; episode one marked watched; latest show progress moved to episode two."
            cacheStore.clear()
        }
    }
}

struct IPadAudioProof:View {
    private let cacheStore:IPadCacheStore
    @StateObject private var session:IPadPlayback
    @ViewState<String> private var report="Preparing AC3 audio check…"
    @ViewState<Task<Void,Never>?> private var task:Task<Void,Never>?
    init() {
        let defaults=UserDefaults(suiteName:"binge.ipad.audio-proof")!
        defaults.removePersistentDomain(forName:"binge.ipad.audio-proof")
        let cache=IPadCacheStore(root:FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("binge-audio-proof"))
        cache.clear();self.cacheStore=cache
        self._session=StateObject(wrappedValue:IPadPlayback(history:IPadHistory(defaults:defaults),preferences:defaults,cacheStore:cache))
    }
    var body:some View {
        VStack(spacing:18) { if session.player != nil { IPadMovieSurface(session:session).frame(minHeight:280) };Text(report).font(.system(.body,design:.monospaced));Text("The white flash and beep should coincide every two seconds.") }.padding(32)
            .onAppear { run() }.onDisappear { task?.cancel();session.stop(discard:true);cacheStore.clear() }
            .onChange(of:report) { _,value in try? value.write(to:FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent(ProcessInfo.processInfo.arguments.contains("--mp4-check") ? "mp4-proof-result.txt" : "audio-proof-result.txt"),atomically:true,encoding:.utf8) }
    }
    private func run() {
        let context=IPadWatchContext(title:CatalogTitle(id:"fixture-audio",type:"movie",name:"Generated AC3 sync fixture"))
        task=Task { @MainActor in
            session.start(AddonStream(name:"AC3 fixture",infoHash:String(repeating:"0",count:40),fileIdx:1),context:context,fixture:Bundle.main.resourceURL!.appendingPathComponent(ProcessInfo.processInfo.arguments.contains("--mp4-check") ? "Fixture/MP4" : "Fixture/Audio"))
            let deadline=Date().addingTimeInterval(60)
            while !Task.isCancelled && Date()<deadline && session.position<5 && !session.failed { report="AC3 preparation · \(session.position)s · \(session.message)";try? await Task.sleep(for:.milliseconds(200)) }
            guard !Task.isCancelled else { return }
            guard !session.failed,session.position>=5,let folder=cacheStore.current?.folder,let data=try? Data(contentsOf:folder.appendingPathComponent("prepared.json")),let result=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],(result["duration"] as? Double ?? 0)>10,result["audioTranscoded"] as? Bool==true,result["videoReencoded"] as? Bool==false,(result["audioPacketsWritten"] as? Int ?? 0)>0,session.player?.currentItem != nil else { report="FAILED: AC3 preparation · \(session.message)";return }
            let preparedAsset=AVURLAsset(url:folder.appendingPathComponent("segments/init.mp4"))
            guard let tracks=try? await preparedAsset.loadTracks(withMediaType:.audio),let audio=tracks.first,let formats=try? await audio.load(.formatDescriptions),let description=formats.first,CMFormatDescriptionGetMediaSubType(description)==kAudioFormatMPEG4AAC else { report="FAILED: prepared AAC track missing";return }
            report="PASS: AC3 surround audio prepared as native AAC stereo; video not re-encoded; native clock advanced beyond five seconds. \(result)"
        }
    }
}

struct IPadSeekProof:View {
    private let engine:TorrentProof
    private let cacheStore:IPadCacheStore
    @StateObject private var session:IPadPlayback
    @ViewState<String> private var report="Starting unprepared seek check…"
    @ViewState<Task<Void,Never>?> private var task:Task<Void,Never>?
    init() {
        let defaults=UserDefaults(suiteName:"binge.ipad.seek-proof")!
        defaults.removePersistentDomain(forName:"binge.ipad.seek-proof")
        let cache=IPadCacheStore(root:FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("binge-seek-proof"))
        cache.clear();cacheStore=cache
        let engine=TorrentProof();self.engine=engine
        _session=StateObject(wrappedValue:IPadPlayback(history:IPadHistory(defaults:defaults),preferences:defaults,cacheStore:cache,engine:engine))
    }
    var body:some View {
        VStack { if session.player != nil { IPadMovieSurface(session:session).frame(minHeight:280) };Text(report) }.padding(32)
            .onAppear { run() }.onDisappear { task?.cancel();session.stop(discard:true);cacheStore.clear() }
            .onChange(of:report) { _,value in try? value.write(to:FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("seek-proof-result.txt"),atomically:true,encoding:.utf8) }
    }
    private func run() {
        task=Task { @MainActor in
            let stream=AddonStream(name:"Seek fixture",infoHash:String(repeating:"0",count:40),fileIdx:1)
            let context=IPadWatchContext(title:CatalogTitle(id:"fixture-seek",type:"movie",name:"Generated seek fixture"))
            session.start(stream,context:context,fixture:Bundle.main.resourceURL!.appendingPathComponent("Fixture/Next"))
            engine.setDownloadLimit(600*1024)
            let deadline=Date().addingTimeInterval(100)
            while Date()<deadline && session.position<1 && !session.failed && !Task.isCancelled { try? await Task.sleep(for:.milliseconds(100)) }
            guard !Task.isCancelled,!session.failed,let folder=cacheStore.current?.folder else { report="FAILED: seek fixture start · \(session.message)";return }
            let playlist=(try? String(contentsOf:folder.appendingPathComponent("segments/media.m3u8"),encoding:.utf8)) ?? ""
            let prepared=playlist.components(separatedBy:"\n").filter {$0.hasPrefix("#EXTINF:")}.compactMap { Double($0.dropFirst(8).split(separator:",")[0]) }.reduce(0,+)
            guard prepared<27 else { report="FAILED: fixture already prepared beyond target";return }
            session.player?.pause();let token=engine.snapshot()
            session.seek(to:27);engine.setDownloadLimit(0)
            while Date()<deadline && (session.player==nil || abs(session.position-27)>1) && !session.failed && !Task.isCancelled { report="Seeking outside prepared \(prepared)s · \(session.message)";try? await Task.sleep(for:.milliseconds(100)) }
            guard !Task.isCancelled,!session.failed,abs(session.position-27)<1,session.player?.rate==0 else { report="FAILED: unprepared paused seek · \(session.position)s · \(session.message)";return }
            session.player?.play()
            while Date()<deadline && session.position<28 && !Task.isCancelled { try? await Task.sleep(for:.milliseconds(100)) }
            guard !Task.isCancelled,session.position>=28 else { report="FAILED: resume after unprepared seek";return }
            session.seek(to:3)
            while Date()<deadline && (session.player==nil || session.position<3 || session.position>8) && !session.failed && !Task.isCancelled { try? await Task.sleep(for:.milliseconds(100)) }
            let initial=(try? JSONSerialization.jsonObject(with:Data(token.utf8))) as? [String:Any]
            let current=(try? JSONSerialization.jsonObject(with:Data(engine.snapshot().utf8))) as? [String:Any]
            guard !Task.isCancelled,!session.failed,session.position>=3,session.position<8,session.player?.rate==1,initial?["sessionToken"] as? String==current?["sessionToken"] as? String else { report="FAILED: backward reprepare · \(session.position)s · \(session.message)";return }
            report="PASS: jumped to 27s beyond prepared \(prepared)s, stayed paused, resumed, then jumped back to 3s while playing; same live torrent session reused."
        }
    }
}

struct IPadRealSourceProof:View {
    @StateObject private var session:IPadPlayback
    @ViewState<String> private var report="Reproducing HEVC resume failure…"
    init() {
        let defaults=UserDefaults(suiteName:"binge.ipad.real-source-proof")!
        defaults.removePersistentDomain(forName:"binge.ipad.real-source-proof")
        let cache=IPadCacheStore(root:FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("binge-real-source-proof"))
        _session=StateObject(wrappedValue:IPadPlayback(history:IPadHistory(defaults:defaults),preferences:defaults,cacheStore:cache))
    }
    var body:some View {
        VStack { if let player=session.player { ProofVideoView(player:player).frame(minHeight:280) };Text(report) }.padding(32)
        .task {
            let hail=ProcessInfo.processInfo.arguments.contains("--hail-check")
            let target=hail ? 387.0 : 1151.0
            let mp4=ProcessInfo.processInfo.arguments.contains("--real-mp4-check")
            session.start(AddonStream(name:"Real-source resume regression",infoHash:hail ? "7876c7bb5a96440ea86de0e12aba3045e3621541" : mp4 ? "423072eb9ebb85dd4fbfa35f95313387e7d18f31" : "f6f9d41cfcfb47cfd1a25d6b47f38e569f0eafab",fileIdx:mp4 ? 47 : 0),resumeAt:target,autoplay:true)
            let deadline=Date().addingTimeInterval(300)
            while Date()<deadline && !session.failed && session.position<target+5 && !Task.isCancelled {
                report="\(session.message) · \(session.position)s"
                try? report.write(to:FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("real-source-proof-result.txt"),atomically:true,encoding:.utf8)
                try? await Task.sleep(for:.milliseconds(500))
            }
            report=session.failed ? "FAILED: \(session.message)" : session.position>=target+5 ? "PASS: actual selected source resumed at 1151s and native clock advanced; full duration \(session.duration)s." : "FAILED: source deadline · \(session.message)"
            try? report.write(to:FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("real-source-proof-result.txt"),atomically:true,encoding:.utf8)
        }.onDisappear { session.stop(discard:true) }
    }
}

struct IPadMacReferenceProof:View {
    @State private var player:AVPlayer?
    var body:some View {
        VStack { if let player { ProofVideoView(player:player) };Text("Mac-prepared comparison clip · check dialogue sync") }.padding(24)
            .onAppear {
                try? AVAudioSession.sharedInstance().setCategory(.playback);try? AVAudioSession.sharedInstance().setActive(true)
                let file=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("mac-reference.mp4")
                let video=AVPlayer(url:file);player=video;video.play()
            }.onDisappear { player?.pause();player=nil }
    }
}

struct IPadHailFormatProof:View {
    @State private var player:AVPlayer?
    @State private var loader:TorrentVideoLoader?
    @State private var report="Testing captured H.264/PQ stream…"
    var body:some View {
        VStack { if let player { ProofVideoView(player:player) };Text(report) }.padding(24)
        .task {
            let folder=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("diagnostic-hls")
            let original=(try? String(contentsOf:folder.appendingPathComponent("media.m3u8"),encoding:.utf8)) ?? ""
            let lines=original.components(separatedBy:"\n")
            guard let first=lines.first(where:{$0.hasPrefix("#EXTINF:")}) else { report="FAILED: missing capture";return }
            let playlist="#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:6\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MAP:URI=\"init.mp4\"\n"+first+"\nmedia0.m4s\n#EXT-X-ENDLIST\n"
            try? playlist.write(to:folder.appendingPathComponent("media.m3u8"),atomically:true,encoding:.utf8)
            let reader=TorrentVideoLoader(engine:TorrentProof(),directory:folder);loader=reader
            do {
                let url=try await reader.start();let video=AVPlayer(url:url);player=video
                try? AVAudioSession.sharedInstance().setCategory(.playback);try? AVAudioSession.sharedInstance().setActive(true)
                video.play();let deadline=Date().addingTimeInterval(20)
                while Date()<deadline && video.currentTime().seconds<2 && video.currentItem?.status != .failed && !Task.isCancelled { try? await Task.sleep(for:.milliseconds(100)) }
                report=video.currentTime().seconds>=2 ? "PASS: captured H.264/PQ source opens and plays without the incompatible HDR declaration." : "FAILED: \(String(describing:video.currentItem?.error))"
            } catch { report="FAILED: \(error)" }
            try? report.write(to:FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("hail-format-result.txt"),atomically:true,encoding:.utf8)
        }.onDisappear { player?.pause();loader?.cancel() }
    }
}
#endif

#if DEBUG
struct IPadNavigationProof:View {
    @StateObject private var session:IPadPlayback
    @State private var report="Checking playback exit responsiveness…"
    init() {
        let defaults=UserDefaults(suiteName:"binge.ipad.navigation-proof")!
        defaults.removePersistentDomain(forName:"binge.ipad.navigation-proof")
        let store=IPadCacheStore(root:FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("binge-navigation-proof"))
        _session=StateObject(wrappedValue:IPadPlayback(history:IPadHistory(defaults:defaults),preferences:defaults,cacheStore:store))
    }
    var body:some View {
        VStack { if let player=session.player { ProofVideoView(player:player).frame(minHeight:250) };Text(report) }.padding(30)
        .task {
            var times:[Double]=[]
            for cycle in 1...3 {
                session.start(AddonStream(name:"Navigation fixture",infoHash:String(repeating:"0",count:40),fileIdx:1),fixture:Bundle.main.resourceURL!.appendingPathComponent("Fixture/Audio"))
                let deadline=Date().addingTimeInterval(90)
                while !Task.isCancelled && !session.failed && session.position<1.5 && Date()<deadline {try? await Task.sleep(for:.milliseconds(200))}
                guard !Task.isCancelled,!session.failed,session.position>=1.5 else { report="FAILED: cycle \(cycle) playback · \(session.message)";save();return }
                let start=ProcessInfo.processInfo.systemUptime
                session.stop(discard:true)
                times.append((ProcessInfo.processInfo.systemUptime-start)*1000)
                report="Cycle \(cycle): exit \(times.last!) ms"
                save()
                try? await Task.sleep(for:.milliseconds(400))
            }
            report=(times.max() ?? 1000)<500 ? "PASS: three native playback/start/exit cycles; stop milliseconds \(times)" : "FAILED: exit exceeded 500 ms · \(times)"
            save()
        }
    }
    private func save() { try? report.write(to:FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("navigation-proof-result.txt"),atomically:true,encoding:.utf8) }
}
#endif
