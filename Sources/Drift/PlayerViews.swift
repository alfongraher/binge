import SwiftUI

struct CoverLoadingView: View {
    var poster: URL?
    var title: String
    var message: String
    var progress: Double?
    var peers: Int
    var rate: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState<Bool> private var glowing = false
    private var fraction: Double { min(1, max(0, progress ?? 0)) }
    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 50).fill(DriftTheme.accent)
                    .frame(width: 190, height: 260).blur(radius: 45)
                    .opacity(glowing ? 0.22 : 0.10).scaleEffect(glowing ? 1.08 : 0.94)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 2.2).repeatForever(autoreverses: true), value: glowing)
                    .onAppear { glowing = !reduceMotion }
                    .onChange(of: reduceMotion) { _, value in glowing = !value }
                AsyncImage(url: poster) { image in
                    ZStack(alignment: .bottom) {
                        image.resizable().scaledToFill().saturation(0).brightness(-0.12).opacity(0.6)
                        image.resizable().scaledToFill()
                            .mask(alignment: .bottom) { Rectangle().frame(height: 252 * fraction) }
                        if fraction > 0 && fraction < 1 {
                            Rectangle().fill(DriftTheme.accent.opacity(0.7)).frame(height: 1).shadow(color: DriftTheme.accent, radius: 8).offset(y: -252 * fraction)
                        }
                    }
                } placeholder: {
                    ZStack {
                        LinearGradient(colors: [DriftTheme.accent.opacity(0.18), .white.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "film").font(.system(size: 40, weight: .ultraLight)).foregroundStyle(DriftTheme.accent)
                    }
                }
                .frame(width: 168, height: 252).clipped().clipShape(RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 18, y: 10)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: fraction)
            }.frame(height: 270)
            HStack(spacing:10) {
                ProgressView().controlSize(.small)
                Text("Getting your video ready…").font(.system(size:17,weight:.medium,design:.rounded))
            }

        }.accessibilityElement(children: .combine)
            .accessibilityLabel("Getting \(title) ready")
            
    }
}
