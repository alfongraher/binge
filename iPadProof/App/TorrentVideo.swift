import AVFoundation
import AVKit
import SwiftUI
import Network

@MainActor final class TorrentVideoLoader {
    var supportsExternalCaptions:Bool { directory != nil }
    let engine: TorrentProof
    private let directory:URL?
    private var listener: NWListener?
    private var connections: [UUID:NWConnection]=[:]
    private var tasks:[UUID:Task<Void,Never>]=[:]
    private var headerTimers:[UUID:Task<Void,Never>]=[:]
    private let token=UUID().uuidString
    private var startup: CheckedContinuation<URL,Error>?
    private var externalCues:[SubtitleCue]?
    private var externalLanguage="en"
    private var externalOffset=0.0
    private var externalDelay=0.0
    func setExternalCaptions(_ cues:[SubtitleCue],language:String,sourceOffset:Double,delay:Double) {
        externalCues=cues;externalLanguage=language.filter { $0.isLetter || $0=="-" };externalOffset=sourceOffset;externalDelay=delay
    }
    init(engine: TorrentProof,directory:URL?=nil) { self.engine=engine;self.directory=directory }
    @MainActor func start() async throws -> URL {
        let parameters=NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
        let listener=try NWListener(using:parameters)
        self.listener=listener
        return try await withCheckedThrowingContinuation { continuation in
            startup=continuation
            listener.stateUpdateHandler={ [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if let startup=self.startup, let port=listener.port {
                            self.startup=nil;startup.resume(returning:URL(string:"http://127.0.0.1:\(port.rawValue)/\(self.token)/\(self.directory == nil ? "video.mp4" : "master.m3u8")")!)
                        }
                    case .failed(let error): self.startup?.resume(throwing:error);self.startup=nil
                    default:break
                    }
                }
            }
            listener.newConnectionHandler={ [weak self] connection in Task { @MainActor in self?.accept(connection) } }
            listener.start(queue:.main)
        }
    }
    @MainActor private func accept(_ connection:NWConnection) {
        guard connections.count<32 else { connection.cancel();return }
        let id=UUID();connections[id]=connection
        headerTimers[id]=Task { @MainActor [weak self] in
            try? await Task.sleep(for:.seconds(10));guard !Task.isCancelled else { return };connection.cancel();self?.headerTimers.removeValue(forKey:id)
        }
        connection.stateUpdateHandler={ [weak self] state in
            Task { @MainActor in
                if case .failed = state { self?.tasks.removeValue(forKey:id)?.cancel();self?.connections.removeValue(forKey:id);self?.headerTimers.removeValue(forKey:id)?.cancel() }
                if case .cancelled = state { self?.tasks.removeValue(forKey:id)?.cancel();self?.connections.removeValue(forKey:id);self?.headerTimers.removeValue(forKey:id)?.cancel() }
            }
        }
        connection.start(queue:.main)
        receive(connection,id:id,buffer:Data())
    }
    @MainActor private func receive(_ connection:NWConnection,id:UUID,buffer:Data) {
        connection.receive(minimumIncompleteLength:1,maximumLength:8192) { [weak self] data,_,complete,error in
            Task { @MainActor in
            guard let self else { return }
            var request=buffer;if let data { request.append(data) }
            if request.count>16384 || error != nil { connection.cancel();return }
            if let text=String(data:request,encoding:.utf8),text.contains("\r\n\r\n") {
                self.headerTimers.removeValue(forKey:id)?.cancel()
                self.tasks[id]=Task { @MainActor in await self.serve(connection,id:id,request:text) }
            } else if !complete { self.receive(connection,id:id,buffer:request) }
            else { connection.cancel() }
            }
        }
    }
    @MainActor private func send(_ data:Data,on connection:NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            connection.send(content:data,completion:.contentProcessed { error in
                if let error { continuation.resume(throwing:error) } else { continuation.resume() }
            })
        }
    }
    @MainActor private func serve(_ connection:NWConnection,id:UUID,request:String) async {
        defer { tasks.removeValue(forKey:id);connections.removeValue(forKey:id);connection.cancel() }
        #if DEBUG
        if directory != nil && ProcessInfo.processInfo.arguments.contains("--stream-mkv") {
            let report=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("hls-http-log.txt")
            let line=(request.components(separatedBy:"\r\n").first ?? "")+"\n"
            if !FileManager.default.fileExists(atPath:report.path) { FileManager.default.createFile(atPath:report.path,contents:nil) }
            if let handle=try? FileHandle(forWritingTo:report) { try? handle.seekToEnd();try? handle.write(contentsOf:Data(line.utf8));try? handle.close() }
        }
        #endif
        let lines=request.components(separatedBy:"\r\n")
        let parts=(lines.first ?? "").split(separator:" ")
        guard parts.count>=2,parts[0]=="GET" || parts[0]=="HEAD" else { return }
        if let directory {
            let prefix="/\(token)/"
            let path=String(parts[1].split(separator:"?",maxSplits:1)[0])
            guard path.hasPrefix(prefix) else { return }
            let name=String(path.dropFirst(prefix.count))
            guard !name.isEmpty,!name.contains("/"),!name.contains(".."),["m3u8","m4s","mp4","vtt"].contains((name as NSString).pathExtension) else { return }
            if externalCues != nil && name=="external.m3u8",let text=externalPlaylist(directory) {
                await servePayload(Data(text.utf8),mime:"application/vnd.apple.mpegurl",connection:connection,head:parts[0]=="HEAD");return
            }
            if externalCues != nil && name.hasPrefix("external"),name.hasSuffix(".vtt"),let index=Int(name.dropFirst(8).dropLast(4)),let text=externalSegment(directory,index:index) {
                await servePayload(Data(text.utf8),mime:"text/vtt",connection:connection,head:parts[0]=="HEAD");return
            }
            await serveFile(directory.appendingPathComponent(name),connection:connection,request:request,head:parts[0]=="HEAD")
            return
        }
        guard parts[1]=="/\(token)/video.mp4" else { return }
        let size=engine.videoSize();guard size>0 else { return }
        var start:Int64=0,end=size-1,partial=false
        if let range=lines.first(where:{$0.lowercased().hasPrefix("range: bytes=")}) {
            let value=range.components(separatedBy:"=").last ?? ""
            let bits=value.split(separator:"-",omittingEmptySubsequences:false)
            guard bits.count==2 else { return }
            if bits[0].isEmpty,let suffix=Int64(bits[1]),suffix>0 { start=max(0,size-suffix) }
            else if let offset=Int64(bits[0]),offset>=0 { start=offset;end=min(size-1,Int64(bits[1]) ?? size-1) }
            else { return }
            partial=true
        }
        guard start>=0,end>=start,start<size else { return }
        var header="HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\nContent-Type: video/mp4\r\nAccept-Ranges: bytes\r\nContent-Length: \(end-start+1)\r\nConnection: close\r\n"
        if partial { header+="Content-Range: bytes \(start)-\(end)/\(size)\r\n" }
        header+="\r\n"
        do {
            try await send(Data(header.utf8),on:connection)
            if parts[0]=="HEAD" { return }
            var offset=start;var waitingSince=Date()
            while offset<=end && !Task.isCancelled {
                let count=Int32(min(128*1024,end-offset+1))
                if let bytes=engine.readVerifiedVideo(at:offset,length:count),!bytes.isEmpty {
                    try await send(bytes,on:connection);offset+=Int64(bytes.count);waitingSince=Date()
                } else {
                    if Date().timeIntervalSince(waitingSince)>60 { return }
                    try await Task.sleep(for:.milliseconds(100))
                }
            }
        } catch { }
    }
    @MainActor private func serveFile(_ file:URL,connection:NWConnection,request:String,head:Bool) async {
        guard let handle=try? FileHandle(forReadingFrom:file),let size=try? handle.seekToEnd(),size>0 else {
            try? await send(Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),on:connection);return
        }
        defer { try? handle.close() }
        var playlist:Data?
        if file.pathExtension=="m3u8" {
            try? handle.seek(toOffset:0)
            guard let bytes=try? handle.readToEnd() else { return }
            if ["master.m3u8","media.m3u8"].contains(file.lastPathComponent),let text=String(data:bytes,encoding:.utf8) {
                // Event playlists grow during preparation; always start at the
                // beginning of the movie, rather than joining their live edge.
                let timed=text.replacingOccurrences(of:"#EXTM3U\n",with:"#EXTM3U\n#EXT-X-START:TIME-OFFSET=0,PRECISE=YES\n")
                playlist=Data((file.lastPathComponent=="master.m3u8" ? externalMaster(decoratedMaster(timed,file.deletingLastPathComponent())) : timed).utf8)
            } else { playlist=bytes }
        }
        let total=Int64(playlist?.count ?? Int(size));var start:Int64=0,end=total-1,partial=false
        if let range=request.components(separatedBy:"\r\n").first(where:{$0.lowercased().hasPrefix("range: bytes=")}) {
            let value=range.components(separatedBy:"=").last ?? ""
            let bits=value.split(separator:"-",omittingEmptySubsequences:false)
            guard bits.count==2 else { return }
            if bits[0].isEmpty,let suffix=Int64(bits[1]),suffix>0 { start=max(0,total-suffix) }
            else if let offset=Int64(bits[0]) { start=offset;end=min(end,Int64(bits[1]) ?? end) }
            else { return }
            partial=true
        }
        guard start>=0,end>=start,start<total else {
            try? await send(Data("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(total)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),on:connection);return
        }
        let mime=file.pathExtension=="m3u8" ? "application/vnd.apple.mpegurl" : file.pathExtension=="vtt" ? "text/vtt" : "video/mp4"
        var header="HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\nContent-Type: \(mime)\r\nCache-Control: no-cache\r\nAccept-Ranges: bytes\r\nContent-Length: \(end-start+1)\r\nConnection: close\r\n"
        if partial { header+="Content-Range: bytes \(start)-\(end)/\(total)\r\n" }
        do {
            try await send(Data((header+"\r\n").utf8),on:connection)
            if head { return }
            if let playlist { try await send(playlist.subdata(in:Int(start)..<Int(end+1)),on:connection);return }
            try handle.seek(toOffset:UInt64(start));var remaining=end-start+1
            while remaining>0 && !Task.isCancelled {
                guard let bytes=try handle.read(upToCount:Int(min(128*1024,remaining))),!bytes.isEmpty else { return }
                try await send(bytes,on:connection);remaining-=Int64(bytes.count)
            }
        } catch { }
    }
    private func decoratedMaster(_ text:String,_ folder:URL)->String {
        guard let data=try? Data(contentsOf:folder.appendingPathComponent("video-info.json")),let info=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else { return text }
        let fps=info["frameRate"] as? Double ?? 0,range=info["videoRange"] as? String ?? ""
        return text.components(separatedBy:"\n").map { line in
            guard line.hasPrefix("#EXT-X-STREAM-INF:") else { return line }
            var variant=line
            if fps.isFinite,fps>0,!variant.contains("FRAME-RATE=") { variant+=String(format:",FRAME-RATE=%.3f",locale:Locale(identifier:"en_US_POSIX"),fps) }
            if ["PQ","HLG"].contains(range),(variant.contains("hvc1.") || variant.contains("dvh1.")),!variant.contains("VIDEO-RANGE=") { variant+=",VIDEO-RANGE="+range }
            return variant
        }.joined(separator:"\n")
    }
    private func externalMaster(_ text:String)->String {
        guard externalCues != nil else { return text }
        var lines=text.components(separatedBy:"\n")
        lines=lines.map { line in
            if line.hasPrefix("#EXT-X-MEDIA:TYPE=SUBTITLES") { return line.replacingOccurrences(of:"DEFAULT=YES",with:"DEFAULT=NO") }
            if line.hasPrefix("#EXT-X-STREAM-INF:"),!line.contains("SUBTITLES=") { return line+",SUBTITLES=\"captions\"" }
            return line
        }
        lines.insert("#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"captions\",NAME=\"Online captions\",DEFAULT=NO,AUTOSELECT=NO,LANGUAGE=\"\(externalLanguage)\",URI=\"external.m3u8\"",at:1)
        return lines.joined(separator:"\n")
    }
    private func externalPlaylist(_ directory:URL)->String? {
        guard let text=try? String(contentsOf:directory.appendingPathComponent("media.m3u8"),encoding:.utf8) else { return nil }
        var index=0
        return text.components(separatedBy:"\n").compactMap { line -> String? in
            if line.hasPrefix("#EXT-X-MAP:") || line=="#EXT-X-INDEPENDENT-SEGMENTS" { return nil }
            if !line.isEmpty && !line.hasPrefix("#") { defer { index+=1 };return "external\(index).vtt" }
            return line
        }.joined(separator:"\n")
    }
    private func externalSegment(_ directory:URL,index:Int)->String? {
        guard index>=0,let cues=externalCues,let text=try? String(contentsOf:directory.appendingPathComponent("media.m3u8"),encoding:.utf8) else { return nil }
        let durations=text.components(separatedBy:"\n").filter {$0.hasPrefix("#EXTINF:")}.compactMap { Double($0.dropFirst(8).split(separator:",")[0]) }
        guard durations.indices.contains(index) else { return nil }
        let start=durations.prefix(index).reduce(0,+),end=start+durations[index]
        return IPadWebVTT.segment(cues,start:start,end:end,sourceOffset:externalOffset,delay:externalDelay)
    }
    private func servePayload(_ body:Data,mime:String,connection:NWConnection,head:Bool) async {
        let header="HTTP/1.1 200 OK\r\nContent-Type: \(mime)\r\nCache-Control: no-cache\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        do { try await send(Data(header.utf8),on:connection);if !head { try await send(body,on:connection) } } catch { }
    }
    @MainActor func cancel() {
        startup?.resume(throwing:CancellationError());startup=nil
        for timer in headerTimers.values { timer.cancel() };headerTimers.removeAll()
        listener?.cancel();listener=nil
        let active=Array(tasks.values);tasks.removeAll();for task in active { task.cancel() }
        let sockets=Array(connections.values);connections.removeAll();for connection in sockets { connection.cancel() }
    }
}
struct ProofVideoView: UIViewControllerRepresentable {
    var player:AVPlayer
    var showsControls=true
    func makeUIViewController(context:Context)->AVPlayerViewController {
        let controller=AVPlayerViewController();controller.player=player;controller.showsPlaybackControls=showsControls;controller.allowsPictureInPicturePlayback=true;controller.canStartPictureInPictureAutomaticallyFromInline=true;return controller
    }
    func updateUIViewController(_ controller:AVPlayerViewController,context:Context) { if controller.player !== player { controller.player=player };if controller.showsPlaybackControls != showsControls { controller.showsPlaybackControls=showsControls } }
}

enum IPadWebVTT {
    static func timestamp(_ seconds:Double)->String {
        let milliseconds=Int((max(0,seconds)*1000).rounded())
        return String(format:"%02d:%02d:%02d.%03d",milliseconds/3600000,(milliseconds/60000)%60,(milliseconds/1000)%60,milliseconds%1000)
    }
    static func segment(_ cues:[SubtitleCue],start:Double,end:Double,sourceOffset:Double,delay:Double)->String {
        var result="WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:0\n\n"
        for cue in cues {
            let from=cue.start-sourceOffset+delay,to=cue.end-sourceOffset+delay
            guard from<end,to>start,to>0 else { continue }
            let text=cue.text.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;")
            result+="\(timestamp(from)) --> \(timestamp(to))\n\(text)\n\n"
        }
        return result
    }
}

// The app owns the full-source timeline; AVFoundation still renders media,
// selected native captions and system Picture in Picture.
@MainActor final class IPadMovieLayerView:UIView {
    override class var layerClass:AnyClass { AVPlayerLayer.self }
    var videoLayer:AVPlayerLayer { layer as! AVPlayerLayer }
}
@MainActor final class IPadPictureInPicture: NSObject,ObservableObject,@preconcurrency AVPictureInPictureControllerDelegate {
    @Published private(set) var possible=false
    @Published private(set) var active=false
    @Published var error:String?
    private var controller:AVPictureInPictureController?
    private var observation:NSKeyValueObservation?
    func attach(_ layer:AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        controller=AVPictureInPictureController(playerLayer:layer)
        controller?.delegate=self;controller?.canStartPictureInPictureAutomaticallyFromInline=true
        observation=controller?.observe(\.isPictureInPicturePossible,options:[.initial,.new]) { [weak self] controller,_ in
            let value=controller.isPictureInPicturePossible
            Task { @MainActor in self?.possible=value }
        }
    }
    func toggle() { if controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() } else { controller?.startPictureInPicture() } }
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController:AVPictureInPictureController) { active=true }
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController:AVPictureInPictureController) { active=false }
    func pictureInPictureController(_ pictureInPictureController:AVPictureInPictureController,failedToStartPictureInPictureWithError error:Error) { self.error=error.localizedDescription }
    func pictureInPictureController(_ pictureInPictureController:AVPictureInPictureController,restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:@escaping (Bool)->Void) { completionHandler(true) }
}
struct IPadMovieLayer:UIViewRepresentable {
    var player:AVPlayer
    var pip:IPadPictureInPicture
    var onReady:(Bool)->Void={_ in}
    func makeCoordinator()->Coordinator { Coordinator(onReady:onReady) }
    func makeUIView(context:Context)->IPadMovieLayerView {
        let view=IPadMovieLayerView();view.backgroundColor = .black;view.videoLayer.videoGravity = .resizeAspect
        view.videoLayer.player=player;pip.attach(view.videoLayer);context.coordinator.attach(view.videoLayer);return view
    }
    func updateUIView(_ view:IPadMovieLayerView,context:Context) {
        context.coordinator.onReady=onReady
        if view.videoLayer.player !== player { view.videoLayer.player=player;context.coordinator.attach(view.videoLayer) }
    }
    static func dismantleUIView(_ view:IPadMovieLayerView,coordinator:Coordinator) { coordinator.invalidate() }
    @MainActor final class Coordinator {
        var onReady:(Bool)->Void
        private var observation:NSKeyValueObservation?
        private var generation=UUID()
        init(onReady:@escaping(Bool)->Void) { self.onReady=onReady }
        func attach(_ layer:AVPlayerLayer) {
            invalidate();let token=generation
            observation=layer.observe(\.isReadyForDisplay,options:[.initial,.new]) { [weak self] layer,_ in
                let ready=layer.isReadyForDisplay
                Task { @MainActor [weak self] in guard let self,self.generation==token else { return };self.onReady(ready) }
            }
        }
        func invalidate() { generation=UUID();observation=nil }
    }
}
struct IPadMovieSurface:View {
    @ObservedObject var session:IPadPlayback
    var title:String?=nil
    var onBack:(()->Void)?=nil
    var onSearchSubtitles:(()->Void)?=nil
    var showLoadingCover=false
    var loadingPoster:URL?=nil
    @State private var readyForDisplay=false
    @StateObject private var pip=IPadPictureInPicture()
    @State private var visible=true
    @State private var scrubbing=false
    @State private var target=0.0
    @State private var hideTask:Task<Void,Never>?
    var body:some View {
        ZStack {
            if let player=session.player { IPadMovieLayer(player:player,pip:pip,onReady:{readyForDisplay=$0}).onTapGesture { visible.toggle();if visible { scheduleHide() } } }
            if showLoadingCover && !readyForDisplay && !pip.active {
                Color.black
                IPadCoverLoading(poster:loadingPoster,title:title ?? "your video",progress:1).allowsHitTesting(false)
            }
            if (visible || (showLoadingCover && !readyForDisplay)) && !pip.active {
                VStack {
                    if let title {
                        HStack(spacing:18) {
                            Button { onBack?() } label: { Image(systemName:"chevron.left").font(.title3).frame(width:44,height:44).background(.black.opacity(0.4),in:Circle()) }.accessibilityLabel("Back")
                            Text(title).font(.headline).lineLimit(2)
                            Spacer()
                        }.foregroundStyle(.white).padding(20).background(LinearGradient(colors:[.black.opacity(0.7),.clear],startPoint:.top,endPoint:.bottom))
                    }
                    Spacer()
                    HStack(spacing:40) {
                        Button { session.seek(to:session.position-15);scheduleHide() } label: { Image(systemName:"gobackward.15") }.accessibilityLabel("Back 15 seconds")
                        Button { session.togglePlayback();scheduleHide() } label: { Image(systemName:session.isPlaying ? "pause.fill" : "play.fill").font(.system(size:38)) }.accessibilityLabel(session.isPlaying ? "Pause" : "Play")
                        Button { session.seek(to:session.position+15);scheduleHide() } label: { Image(systemName:"goforward.15") }.accessibilityLabel("Forward 15 seconds")
                    }.font(.system(size:27)).foregroundStyle(.white).buttonStyle(.plain).shadow(radius:4)
                    Spacer()
                    VStack(spacing:10) {
                        IPadFullTimeline(position:scrubbing ? target : session.position,duration:session.duration,ranges:session.bufferedRanges,onScrub:{ value in scrubbing=true;target=value;hideTask?.cancel() },onCommit:{ value in session.seek(to:value);scrubbing=false;scheduleHide() })
                        HStack {
                            Text("\(clock(scrubbing ? target : session.position)) / \(clock(session.duration))").font(.caption.monospacedDigit())
                            Spacer()
                            Menu {
                                Button("Automatic") { session.automaticSubtitles();scheduleHide() }
                                Button("Off") { session.selectSubtitle(nil);scheduleHide() }
                                if onSearchSubtitles != nil { Button("Search online",systemImage:"magnifyingglass") { hideTask?.cancel();onSearchSubtitles?() } }
                                ForEach(Array(session.subtitleOptions.enumerated()),id:\.offset) { index,option in Button(option.displayName) { session.selectSubtitle(index);scheduleHide() } }
                            } label: { Image(systemName:"captions.bubble").font(.title3) }.accessibilityLabel("Subtitles")
                            Button { pip.toggle();scheduleHide() } label: { Image(systemName:"pip.enter").font(.title3) }.disabled(!pip.possible).accessibilityLabel("Picture in Picture")
                        }.foregroundStyle(.white)
                    }.padding(20).background(LinearGradient(colors:[.clear,.black.opacity(0.8)],startPoint:.top,endPoint:.bottom))
                    .opacity(showLoadingCover && !readyForDisplay ? 0 : 1).allowsHitTesting(!showLoadingCover || readyForDisplay)
                }
            }
        }.onAppear { session.refreshTimeline();scheduleHide() }.onDisappear { hideTask?.cancel() }
        .onChange(of:session.isPlaying) { _,playing in if !playing { visible=true;hideTask?.cancel() } else { scheduleHide() } }
        .alert("Picture in Picture",isPresented:Binding(get:{pip.error != nil},set:{if !$0 { pip.error=nil }})) { Button("OK") { pip.error=nil } } message: { Text(pip.error ?? "") }
    }
    private func scheduleHide() { hideTask?.cancel();hideTask=Task { try? await Task.sleep(for:.seconds(3));if !Task.isCancelled && session.isPlaying && !scrubbing { visible=false } } }
    private func clock(_ value:Double)->String { let seconds=Int(max(0,value.isFinite ? value : 0));return seconds>=3600 ? String(format:"%d:%02d:%02d",seconds/3600,seconds/60%60,seconds%60) : String(format:"%d:%02d",seconds/60,seconds%60) }
}
struct IPadFullTimeline:View {
    var position:Double
    var duration:Double
    var ranges:[ClosedRange<Double>]
    var onScrub:(Double)->Void
    var onCommit:(Double)->Void
    var body:some View {
        GeometryReader { geometry in
            let width=max(1,geometry.size.width),total=max(1,duration)
            ZStack(alignment:.leading) {
                Capsule().fill(.white.opacity(0.22)).frame(height:5)
                ForEach(Array(ranges.enumerated()),id:\.offset) { _,range in
                    Capsule().fill(.white.opacity(0.48)).frame(width:max(0,min(total,range.upperBound)-max(0,range.lowerBound))/total*width,height:5).offset(x:max(0,range.lowerBound)/total*width)
                }
                Capsule().fill(.yellow).frame(width:min(1,max(0,position/total))*width,height:5)
                Circle().fill(.yellow).frame(width:12,height:12).offset(x:max(0,min(width-12,position/total*width-6)))
            }.frame(height:30).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance:0).onChanged { onScrub(max(0,min(1,$0.location.x/width))*max(0,duration)) }.onEnded { onCommit(max(0,min(1,$0.location.x/width))*max(0,duration)) })
                .accessibilityElement().accessibilityLabel("Playback position").accessibilityValue("\(Int(position)) of \(Int(duration)) seconds")
                .accessibilityAdjustableAction { direction in onCommit(max(0,min(duration,position+(direction == .increment ? 15 : -15)))) }
        }.frame(height:30)
    }
}
