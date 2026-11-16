import AppKit
import SwiftUI

/// Steamy's start screen: everything you can install, your bottles, and Steam tools.
struct HomeView: View {
    @ObservedObject var model: InstallerModel
    @ObservedObject var store: BottleStore
    let openBottle: (Bottle) -> Void
    let confirmStop: () -> Void

    @State private var search = ""

    private struct CatalogItem: Identifiable {
        let name: String
        let detail: String
        let icon: String
        let tint: Color
        var id: String { name }
    }

    private func matches(_ text: String) -> Bool {
        search.isEmpty || text.localizedCaseInsensitiveContains(search)
    }

    private let columns = [GridItem(.adaptive(minimum: 290, maximum: 380), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Home").font(.app(.largeTitle).bold())
                    Text("Install and run Windows games and apps on your Mac.")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search stores, launchers and your bottles", text: $search)
                        .textFieldStyle(.plain)
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

                if model.state != .ready && model.state != .checking {
                    steamSetupCard
                }

                section("Game Stores") {
                    if matches("Steam Valve") { steamCard }
                    ForEach(BottleStore.launchers.filter { matches($0.name + " " + $0.detail) }) { launcher in
                        let bottle = store.bottles.first { $0.name == launcher.name }
                        // Installed only once the launcher shows up in the bottle's Start Menu; an
                        // empty bottle (failed or cancelled install) offers Install again.
                        let installed = bottle.map { !(store.programs[$0.id] ?? []).isEmpty } ?? false
                        CatalogCard(title: launcher.name, detail: launcher.detail, icon: launcher.icon, tint: launcher.brand,
                                    logo: launcher.logo,
                                    actionTitle: installed ? "Open" : "Install",
                                    busy: store.activity != nil && !installed) {
                            if installed, let bottle { openBottle(bottle) } else { store.installLauncher(launcher) }
                        }
                    }
                }

                let bottles = store.bottles.filter { matches($0.name) }
                if !bottles.isEmpty {
                    section("Your Bottles") {
                        ForEach(bottles) { bottle in
                            CatalogCard(title: bottle.name,
                                        detail: "\(store.programs[bottle.id]?.count ?? 0) apps · \(store.graphics(bottle).rawValue) graphics",
                                        icon: "shippingbox.fill", tint: .gray, actionTitle: "Open") { openBottle(bottle) }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string("disclaimer.compatibility"))
                    Text("Unofficial. Not affiliated with Valve, Apple, CodeWeavers or Sikarugir.")
                }
                .font(.app(.caption))
                .foregroundStyle(.tertiary)
            }
            .padding(28)
        }
        .onAppear { store.bottles.forEach { if store.programs[$0.id] == nil { store.scanPrograms($0) } } }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.app(.title3).bold())
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) { content() }
        }
    }

    // MARK: Steam

    private var steamCard: some View {
        CatalogCard(
            title: "Steam",
            detail: model.state == .ready
                ? (model.isSteamRunning ? "Running" : "Installed and ready")
                : "Valve's store and your Steam library",
            icon: "cloud.fill", tint: Color(hex: 0x1B2838), logo: "steam",
            actionTitle: model.state == .ready ? (model.isSteamRunning ? "Show" : "Open") : "Set Up Steam",
            busy: model.isBusy
        ) {
            if model.state == .ready { model.openSteam() } else { model.primaryAction() }
        }
    }

    private var steamSetupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusCard(model: model)
            if model.state == .installing {
                ProgressView(value: model.progress, total: 100)
                    .tint(model.needsUserAction ? .orange : .steamyAccent)
                if !model.transferText.isEmpty {
                    Text(model.transferText).font(.app(.caption)).foregroundStyle(.secondary)
                }
            } else {
                Button(action: model.primaryAction) {
                    Text(model.primaryTitle).frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.steamyAccent).foregroundStyle(Color.onSteamyAccent)
                .controlSize(.large)
                .disabled(model.isBusy)
            }
        }
    }

}

struct CatalogCard: View {
    let title: String
    let detail: String
    let icon: String
    let tint: Color
    var logo: String?
    let actionTitle: String
    var busy = false
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let logo, let image = BrandLogo.image(logo) {
                    Image(nsImage: image).renderingMode(.template).resizable().scaledToFit().padding(10)
                } else {
                    Image(systemName: icon).font(.app(.title2))
                }
            }
            .foregroundStyle(logo == nil ? Color.steamyAccent : .white)
            .frame(width: 46, height: 46)
            .background(logo == nil ? AnyShapeStyle(Color.steamyAccent.opacity(0.16)) : AnyShapeStyle(tint.gradient),
                        in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold).lineLimit(1).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.app(.caption)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            Button(actionTitle, action: action)
                .disabled(busy)
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Store brand marks bundled from Simple Icons (Resources/Logos, CC0 SVG paths).
/// Trademarks belong to their owners and are used only to identify each store.
enum BrandLogo {
    private static var cache: [String: NSImage] = [:]
    static func image(_ name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "Logos"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        cache[name] = image
        return image
    }
}

extension Color {
    /// Accent: neutral grey in Dark Mode, green in Light Mode (readable on white).
    static let steamyAccent = Color(nsColor: NSColor(name: "steamyAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.62, alpha: 1)
            : NSColor(srgbRed: 0, green: 0.62, blue: 0.33, alpha: 1)
    })
    /// Text/icon color on a solid accent background.
    static let onSteamyAccent = Color(nsColor: NSColor(name: "onSteamyAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .black
    })

    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension ShapeStyle where Self == Color {
    static var steamyAccent: Color { Color.steamyAccent }
}

// MARK: - App settings

enum AppAppearance: String, CaseIterable, Identifiable {
    case system = "System", light = "Light", dark = "Dark"
    var id: String { rawValue }

    @MainActor func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum TextSize: Double, CaseIterable, Identifiable {
    case small = 0.9, standard = 1.0, large = 1.15, extraLarge = 1.3
    var id: Double { rawValue }
    var title: String {
        switch self {
        case .small: "Small"
        case .standard: "Default"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        }
    }
}

extension Font {
    /// macOS ignores Dynamic Type, so Steamy scales its own text styles from Settings.
    static func app(_ style: Font.TextStyle) -> Font {
        let stored = UserDefaults.standard.double(forKey: "textScale")
        let scale = stored == 0 ? 1 : stored
        let base: CGFloat = switch style {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline, .body: 13
        case .callout: 12
        case .subheadline: 11
        default: 10
        }
        return .system(size: base * scale, weight: style == .headline ? .semibold : .regular)
    }
}

/// Wraps the main window: applies appearance and text size from Settings.
struct RootView: View {
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage("textScale") private var textScale = 1.0

    var body: some View {
        ContentView()
            .font(.app(.body))
            .tint(.steamyAccent)
            .id(textScale)  // ponytail: rebuilds the window to pick up new font sizes; fine for a rare setting
            .onAppear { (AppAppearance(rawValue: appearance) ?? .system).apply() }
            .onChange(of: appearance) { _, value in (AppAppearance(rawValue: value) ?? .system).apply() }
    }
}

struct SettingsView: View {
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage("textScale") private var textScale = 1.0
    @AppStorage("showAdvancedOptions") private var advanced = false
    @AppStorage(Tutorial.doneKey) private var tutorialDone = false
    @AppStorage("gameMode") private var gameMode = true
    @AppStorage("cap60Hz") private var cap60Hz = false
    @AppStorage("bottleStorage") private var storage = BottleStore.externalVolumes.first?.path ?? "local"

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppAppearance.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            Picker("Text Size", selection: $textScale) {
                ForEach(TextSize.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Picker("Store new bottles on", selection: $storage) {
                Text("This Mac").tag("local")
                ForEach(BottleStore.externalVolumes, id: \.path) { Text($0.lastPathComponent).tag($0.path) }
            }
            Toggle("Game Mode: lower background apps' priority while playing", isOn: $gameMode)
                .help("Browsers, Discord, Spotify and similar apps get background priority during a game, so the game gets more CPU. Restored when the game ends.")
            Toggle("Limit display to 60 Hz while playing", isOn: $cap60Hz)
                .help("Keeps fanless Macs cooler, also for DirectX 12 games. The display goes back to normal when the game ends or WYNIX quits.")
            Toggle("Show advanced bottle options by default", isOn: $advanced)
            Button("Show the WYNIX tour again") { tutorialDone = false }
            Link("Support WYNIX (optional donation)", destination: URL(string: "https://wynix.vercel.app/#donate")!)
            Link("Terms, privacy and licenses", destination: URL(string: "https://wynix.vercel.app/legal.html")!)

            Section("Help") {
                HelpItem("Home", "Game stores and your bottles. Press Set Up Steam once, then Open it and sign in with your normal account.")
                HelpItem("Games", "Every Steam game you installed. Press Play. Right click a game to make a Dock shortcut or hide it.")
                HelpItem("Bottles", "A bottle is a small Windows setup that lives inside WYNIX. Each one keeps its own programs and settings, so a broken game can't mess up the rest.")
                HelpItem("Install from File", "Runs any Windows installer (.exe or .msi), games or not. The program shows up in the bottle and in ~/Applications like a Mac app.")
                HelpItem("New Bottle", "Makes a separate setup. Use it when one game needs different graphics settings than the others.")
                HelpItem("Optimize", "Applies the best settings to your bottles in one click: graphics layer, frame cap and Mac shortcuts.")
                HelpItem("Boost", "Run the game at 1600×900 and MetalFX sharpens it to your screen at a steady 60 FPS. DirectX 11 games only.")
                HelpItem("Graphics layer", "D3DMetal for DirectX 12, DXMT for DirectX 11, DXVK for launchers. Auto picks for you; change it in a bottle's advanced options if a game looks wrong.")
                HelpItem("Privacy", "When WYNIX checks for updates it sends a random install ID and the app version. Nothing else: no name, no email, no games list. It only lets us count how many people use WYNIX.")
                HelpItem("Something not working?", "Open the bottle and press Something Not Working. It closes everything in that bottle and restarts it. Games with kernel anti-cheat (Valorant, Fortnite, many shooters) won't run.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 640)
    }
}

// MARK: - Game Mode

/// While a game runs, pushes heavy background apps (browsers, chat, music) to macOS's background
/// priority band so the game gets the CPU. Fully reversible: priorities are restored when the
/// game session ends or Steamy quits. Uses `taskpolicy -b/-B` (no admin rights needed).
@MainActor
final class GameModeBooster {
    static let shared = GameModeBooster()

    /// Bundle IDs of apps that commonly eat CPU/GPU in the background.
    static let heavyApps: Set<String> = [
        "com.google.Chrome", "com.brave.Browser", "company.thebrowser.Browser", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.operasoftware.Opera", "com.hnc.Discord", "com.spotify.client",
        "com.tinyspeck.slackmacgap", "com.microsoft.teams2", "net.whatsapp.WhatsApp",
        "com.anthropic.claudefordesktop", "com.openai.chat", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"
    ]

    private static let savedKey = "gameModeLowered"
    /// The one queue for all taskpolicy work. `queueLowered` is touched only on it.
    nonisolated private static let work = DispatchQueue(label: "wynix.gamemode", qos: .utility)
    nonisolated(unsafe) private static var queueLowered: [pid_t] = []
    nonisolated(unsafe) private static var live = 0
    nonisolated private static let liveLock = NSLock()
    nonisolated private static var liveGeneration: Int { liveLock.lock(); defer { liveLock.unlock() }; return live }
    nonisolated private static func setLive(_ g: Int) { liveLock.lock(); live = g; liveLock.unlock() }
    private var session = false
    private var generation = 0
    private var originalModes: [(CGDirectDisplayID, CGDisplayMode)] = []
    private var thermalObserver: NSObjectProtocol?
    var isEngaged: Bool { session }

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "gameMode") as? Bool ?? true
    }

    /// At launch: undo priorities left behind by a crash, only for pids that are still the same process.
    func restoreAfterCrash() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.savedKey) ?? []
        for pid in GameModeSafety.stillSame(saved, startTime: GameModeSafety.startTime) { _ = Self.taskpolicy("-B", pid) }
        UserDefaults.standard.removeObject(forKey: Self.savedKey)
    }

    /// `onHot` gets a plain message when the Mac reaches serious/critical thermal state during the session.
    func engage(onHot: @escaping (String) -> Void) {
        guard !session else { return }
        session = true
        let startState = ProcessInfo.processInfo.thermalState
        if startState == .serious || startState == .critical {
            onHot("Your Mac is getting hot. Lower the game's resolution or turn on Boost to cool it down.")
        }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
            let state = ProcessInfo.processInfo.thermalState
            if state == .serious || state == .critical {
                onHot("Your Mac is getting hot. Lower the game's resolution or turn on Boost to cool it down.")
            }
        }
        if UserDefaults.standard.bool(forKey: "cap60Hz") { capDisplays() }
        guard Self.enabled else { return }
        let roots = NSWorkspace.shared.runningApplications
            .filter { Self.heavyApps.contains($0.bundleIdentifier ?? "") }
            .compactMap { $0.bundleURL?.path }
        guard !roots.isEmpty else { return }
        // Every process of those apps, helpers and renderers included. All taskpolicy work (lower, persist,
        // restore) runs on the one serial `work` queue, so release(sync:) waits for an in-flight lowering.
        let generation = generation
        Self.setLive(generation)
        Self.work.async {
            let ps = Process()
            let pipe = Pipe()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-axo", "pid=,comm="]
            ps.standardOutput = pipe
            try? ps.run()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            ps.waitUntilExit()
            for line in output.split(separator: "\n") {
                guard Self.liveGeneration == generation else { return }  // released or superseded: stop lowering
                let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
                guard parts.count == 2, let pid = pid_t(parts[0]),
                      roots.contains(where: { String(parts[1]).hasPrefix($0 + "/") }) else { continue }
                if Self.taskpolicy("-b", pid) {
                    Self.queueLowered.append(pid)
                    // Persist as each pid is lowered, with start times, so a crash can't leave it in the background band.
                    UserDefaults.standard.set(Self.queueLowered.compactMap { p in GameModeSafety.startTime(p).map { "\(p):\($0)" } }, forKey: Self.savedKey)
                }
            }
        }
    }

    /// Restores everything on the work queue. `sync` (applicationWillTerminate) waits for any in-flight lowering first.
    func release(sync: Bool = false) {
        session = false
        generation += 1
        Self.setLive(generation)  // tells an in-flight engage block to stop
        if let o = thermalObserver { NotificationCenter.default.removeObserver(o); thermalObserver = nil }
        let undo = {
            for pid in Self.queueLowered { _ = Self.taskpolicy("-B", pid) }
            Self.queueLowered.removeAll()
            UserDefaults.standard.removeObject(forKey: Self.savedKey)
        }
        if sync { Self.work.sync(execute: undo) } else { Self.work.async(execute: undo) }
        restoreDisplays()
    }

    /// App-only display change: macOS puts the original mode back if WYNIX quits or crashes.
    private func capDisplays() {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        for id in ids.prefix(Int(count)) {
            guard let cur = CGDisplayCopyDisplayMode(id),
                  let all = CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode] else { continue }
            let modes = all.filter { $0.width == cur.width && $0.height == cur.height }
            guard let i = GameModeSafety.mode60Index(
                current: (cur.pixelWidth, cur.pixelHeight, cur.refreshRate),
                modes: modes.map { ($0.pixelWidth, $0.pixelHeight, $0.refreshRate) }) else { continue }
            if CGConfigureDisplayWithDisplayMode(config, id, modes[i], nil) == .success { originalModes.append((id, cur)) }
        }
        if originalModes.isEmpty { CGCancelDisplayConfiguration(config); return }
        if CGCompleteDisplayConfiguration(config, .forAppOnly) != .success { originalModes.removeAll() }
    }

    private func restoreDisplays() {
        guard !originalModes.isEmpty else { return }
        var config: CGDisplayConfigRef?
        if CGBeginDisplayConfiguration(&config) == .success {
            for (id, mode) in originalModes { CGConfigureDisplayWithDisplayMode(config, id, mode, nil) }
            CGCompleteDisplayConfiguration(config, .forAppOnly)
        }
        originalModes.removeAll()
    }

    @discardableResult
    nonisolated private static func taskpolicy(_ flag: String, _ pid: pid_t) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/taskpolicy")
        task.arguments = [flag, "-p", String(pid)]
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
}

/// One expandable entry in Settings > Help.
struct HelpItem: View {
    let title: String
    let text: String
    init(_ title: String, _ text: String) { self.title = title; self.text = text }

    var body: some View {
        DisclosureGroup(title) {
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
        }
    }
}
