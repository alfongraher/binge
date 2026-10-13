import SwiftUI
import AVKit
import UniformTypeIdentifiers

// Explicit alias selects the property wrapper on SDKs that also expose a State macro.
typealias ViewState<Value> = SwiftUI.State<Value>

@main
struct DriftApp: App {
    @StateObject private var library = LibraryStore()
    var body: some Scene {
        WindowGroup("binge") {
            DriftShell().environmentObject(library)
                .frame(minWidth: 1000, minHeight: 650)

        }
    }
}

struct AddSourceView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @ViewState<String> private var title = ""
    @ViewState<String> private var source = ""
    @ViewState<String> private var kind = "Movie"

    private var normalizedSource: String { source.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: normalizedSource) else { return false }
        if url.scheme == "magnet" {
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .contains(where: { $0.name == "xt" && ($0.value?.hasPrefix("urn:btih:") == true || $0.value?.hasPrefix("urn:btmh:") == true) }) == true
        }
        return ["http", "https"].contains(url.scheme ?? "") && url.host != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add to your library").font(.title2.bold())
            TextField("Title", text: $title)
            TextField("Media URL or magnet link", text: $source)
            Picker("Type", selection: $kind) {
                Text("Movie").tag("Movie")
                Text("TV episode").tag("TV episode")
            }
            Text("Media URLs play with the native player. Magnet links use the torrent player.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    library.add(title: title.trimmingCharacters(in: .whitespacesAndNewlines), source: normalizedSource, kind: kind)
                    dismiss()
                }.disabled(!valid).keyboardShortcut(.defaultAction)
            }
        }.textFieldStyle(.roundedBorder).padding(28).frame(width: 480)
    }
}
