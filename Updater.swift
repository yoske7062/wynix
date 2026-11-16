import SwiftUI
import AppKit

/// Checks wynix.vercel.app/version.json on launch (and every 6 h) and shows a
/// "Update available" button in the sidebar. The download opens in the browser;
/// the user drags the new WYNIX into Applications like the first time.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let feed = URL(string: "https://wynix.vercel.app/version.json")!

    struct Release: Decodable {
        let version: String
        let build: Int
        let url: URL
        let notes: String?
    }

    @Published private(set) var available: Release?
    private var timer: Timer?

    var currentBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    func start() {
        check()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in Updater.shared.check() }
        }
    }

    func check() {
        var request = URLRequest(url: Self.feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("WYNIX/\(currentBuild)", forHTTPHeaderField: "User-Agent")
        Task {
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let release = try? JSONDecoder().decode(Release.self, from: data) else { return }
            available = release.build > currentBuild ? release : nil
        }
    }

    func download() {
        guard let release = available else { return }
        NSWorkspace.shared.open(release.url)
    }
}

/// Sidebar button shown only when a newer build is published.
struct UpdateButton: View {
    @ObservedObject var updater = Updater.shared

    var body: some View {
        if let release = updater.available {
            Button { updater.download() } label: {
                Label("Update to \(release.version)", systemImage: "arrow.down.circle.fill")
                    .font(.app(.title3))
            }
            .help(release.notes ?? "A new version of WYNIX is available. Download it and replace the app in Applications.")
        }
    }
}
