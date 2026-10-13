import AppKit
import AVKit
import SwiftUI

@MainActor
final class FloatingPlayer: NSObject, NSWindowDelegate {
    static let shared = FloatingPlayer()
    private var panel: NSPanel?
    func toggle(_ player: AVPlayer) {
        if panel != nil { close(); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 270), styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "binge · Picture in Picture"
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.contentAspectRatio = NSSize(width: 16, height: 9); panel.minSize = NSSize(width: 280, height: 158)
        panel.contentView = NSHostingView(rootView: FloatingPlayerContent(session: .shared, back: { [weak self] in
            self?.close(); NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { !($0 is NSPanel) }?.makeKeyAndOrderFront(nil)
        }, close: { [weak self] in self?.close() }))
        panel.delegate = self
        if let screen = NSScreen.main { let frame = screen.visibleFrame; panel.setFrameOrigin(NSPoint(x: frame.maxX - 500, y: frame.minY + 20)) }
        self.panel = panel; panel.orderFrontRegardless()
    }
    func update(_ player: AVPlayer) { /* Content observes the shared playback session. */ }
    func close() { panel?.close(); panel = nil }
    func windowWillClose(_ notification: Notification) { panel = nil }
}

private struct FloatingPlayerContent: View {
    @ObservedObject var session: PlaybackSession
    var back: () -> Void
    var close: () -> Void
    @ViewState<Bool> private var hovering = false
    @ViewState<Bool> private var timelineHover = false
    @ViewState<Double> private var scrub = 0
    @ViewState<Bool> private var scrubbing = false
    var body: some View {
        ZStack {
            Color.black
            if let player = session.player { NativePlayerView(player: player, showsControls: false) }
            MiniPlayerDragSurface()
            if hovering {
                LinearGradient(colors: [.black.opacity(0.5), .clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom).allowsHitTesting(false)
                VStack {
                    HStack {
                        Button(action: back) { Label("Back to app", systemImage: "arrow.up.left").font(.system(size: 11, weight: .semibold)).padding(8).background(.ultraThinMaterial, in: Capsule()) }
                        Spacer()
                        Button(action: close) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).padding(8).background(.ultraThinMaterial, in: Circle()) }.help("Close mini-player")
                    }
                    Spacer()
                    HStack(spacing: 28) {
                        Button { session.seek(session.position - 15) } label: { Image(systemName: "gobackward.15").font(.system(size: 24)) }
                        Button { session.togglePause() } label: { Image(systemName: session.paused ? "play.fill" : "pause.fill").font(.system(size: 34)) }
                        Button { session.seek(session.position + 15) } label: { Image(systemName: "goforward.15").font(.system(size: 24)) }
                    }
                    Spacer()
                    Color.clear.frame(height: 20)
                }.padding(14).buttonStyle(.plain).foregroundStyle(.white)
            }
            VStack {
                Spacer()
                GeometryReader { geo in
                    let fraction = session.duration > 0 ? min(1, max(0, (scrubbing ? scrub : session.position) / session.duration)) : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.25))
                        Capsule().fill(DriftTheme.accent).frame(width: geo.size.width * fraction)
                    }.frame(height: timelineHover || scrubbing ? 7 : 3)
                        .frame(maxHeight: .infinity)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { value in scrubbing = true; scrub = min(1, max(0, value.location.x / max(1, geo.size.width))) * session.duration }
                            .onEnded { _ in session.seek(scrub); scrubbing = false })
                        .onHover { timelineHover = $0 }
                        .animation(.easeOut(duration: 0.12), value: timelineHover)
                        .accessibilityLabel("Playback position")
                        .accessibilityValue("\(Int(fraction * 100)) percent")
                        .accessibilityAdjustableAction { direction in session.seek(session.position + (direction == .increment ? 10 : -10)) }
                }.frame(height: 22)
            }.padding(.horizontal, 14).padding(.bottom, 5)

        }.clipShape(RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12), lineWidth: 1)).tint(DriftTheme.accent).preferredColorScheme(.dark).onHover { hovering = $0 }
        .onAppear { scrub = session.position }
        .onChange(of: session.position) { _, value in if !scrubbing { scrub = value } }
    }
}

// AVPlayerView consumes mouse events, so background window dragging needs an
// explicit native surface below the playback buttons and seek gesture.
private struct MiniPlayerDragSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
