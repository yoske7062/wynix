import AppKit
import Combine
import Foundation
import IOKit.ps
import SwiftUI

enum L10n {
    static func string(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: Locale.current, arguments: arguments)
    }

    static var languageCode: String {
        Bundle.main.preferredLocalizations.first == "ko" ? "ko" : "en"
    }
}

struct SteamGame: Identifiable, Equatable {
    let id: String
    let name: String
    let installDirectory: String
    let iconPath: String?
}

@MainActor
final class InstallerModel: ObservableObject {
    enum State {
        case checking, notInstalled, partial, installing, ready, failed
    }

    @Published var state: State = .checking
    @Published var phase = L10n.string("phase.checking")
    @Published var message = L10n.string("message.checkingInstallation")
    @Published var log = ""
    @Published var showLog = false
    @Published var progress = 0.0
    @Published var transferText = ""
    @Published var needsUserAction = false
    @Published var operationInProgress = false
    @Published var isSteamRunning = false
    @Published var games: [SteamGame] = []
    @Published var localizedGameNames: [String: String] = [:]
    /// Per Steam App ID: "framegen", "dlss" or "none" (from the NVIDIA runtime files the game ships).
    @Published var dlssSupport: [String: String] = [:]
    @Published var shortcutMessage = ""
    @Published private(set) var runtimeStatusTitle: String?

    private var process: Process?
    private var pendingPlay: SteamGame?
    private var pendingPlayExtras: (renderer: String, status: String?) = ("", nil)
    private var runtimeProcess: Process?
    private var pendingOutput = ""
    private var statusTimer: AnyCancellable?
    private var requestedLocalizedNames: Set<String> = []
    private var pendingGames: [SteamGame]?

    var isBusy: Bool { state == .checking || state == .installing || operationInProgress }

    var primaryTitle: String {
        if state == .ready && isSteamRunning { return L10n.string("steam.running") }
        switch state {
        case .ready: return L10n.string("steam.open")
        case .partial: return L10n.string("setup.resume")
        case .failed: return L10n.string("common.retry")
        default: return L10n.string("setup.prepare")
        }
    }

    var statusTitle: String {
        if state == .ready, let runtimeStatusTitle { return runtimeStatusTitle }
        if state == .ready && isSteamRunning { return L10n.string("steam.running") }
        switch state {
        case .checking: return L10n.string("status.checking")
        case .notInstalled: return L10n.string("status.readyToInstall")
        case .partial: return L10n.string("status.canResume")
        case .installing: return phase
        case .ready: return L10n.string("status.steamReady")
        case .failed: return L10n.string("status.setupFailed")
        }
    }

    init() {
        refresh()
        statusTimer = Timer.publish(every: 10, on: .main, in: .common)  // each check spawns bash + ps + lsof; keep it light
            .autoconnect()
            .sink { [weak self] _ in self?.refreshRuntimeStatus() }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.prewarmIfWanted() }
        }
    }

    /// Window opened or activated, Steam installed (state .ready) and idle: start Steam silently.
    func prewarmIfWanted() {
        guard Prewarm.enabled, state == .ready, !operationInProgress, !isSteamRunning,
              runtimeProcess == nil, Prewarm.powerAllows else { return }
        Prewarm.run("prewarm")
    }

    func primaryAction() {
        if state == .ready {
            openSteam()
        } else {
            run(mode: "setup")
        }
    }

    func refresh() { run(mode: "check") }

    func openSteam() {
        // Starting or foregrounding Steam is a runtime operation. Keep the
        // installed-game library visible instead of showing installation UI.
        run(mode: "launch", changesMainState: false)
    }

    func openInstallFolder() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Sikarugir")
        NSWorkspace.shared.open(url)
    }

    func repairSteamUI() {
        run(mode: "repair", changesMainState: false)
    }

    func stopSteam() {
        run(mode: "stop", changesMainState: false)
    }

    private func refreshRuntimeStatus() {
        guard state == .ready, !operationInProgress, runtimeProcess == nil,
              let script = Bundle.main.path(forResource: "setup", ofType: "sh") else { return }

        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [script, "runtime-status"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        task.environment = Self.taskEnvironment()
        task.terminationHandler = { [weak self] _ in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                self.runtimeProcess = nil
                let running: Bool
                if output.contains("@@RUNTIME|running") {
                    running = true
                } else if output.contains("@@RUNTIME|stopped") {
                    running = false
                } else {
                    return
                }
                guard running != self.isSteamRunning else { return }
                // Game session over (Steam closed after the game): give background apps their CPU back.
                if !running { GameModeBooster.shared.release() }
                self.isSteamRunning = running
                self.message = running
                    ? L10n.string("message.steamRunning")
                    : L10n.string("message.steamStopped")
            }
        }
        runtimeProcess = task
        do {
            try task.run()
        } catch {
            runtimeProcess = nil
        }
    }

    func loadGames() {
        guard process == nil else { return }
        pendingGames = []
        shortcutMessage = ""
        run(mode: "list-games", changesMainState: false)
    }

    /// Starts Steam if needed, then launches the game through `steam -applaunch`.
    /// `renderer` (d3dmetal|dxmt) is what the game needs; setup.sh restarts Steam if it booted with the other one.
    func play(_ game: SteamGame, renderer: String = "", status: String? = nil) {
        if process != nil {
            pendingPlay = game  // one slot, latest wins; runs when the current task ends
            pendingPlayExtras = (renderer, status)
            message = L10n.format("play.queued", game.name)
            return
        }
        message = status ?? L10n.format("play.starting", game.name)
        run(mode: "play", arguments: [game.id] + (renderer.isEmpty ? [] : [renderer]), changesMainState: false)
    }

    func createShortcut(for game: SteamGame) {
        guard process == nil else { shortcutMessage = L10n.string("shortcut.busy"); return }
        shortcutMessage = L10n.format("shortcut.creating", game.name)
        run(mode: "create-shortcut", arguments: [game.id], changesMainState: false)
    }

    private func run(mode: String, arguments: [String] = [], changesMainState: Bool = true) {
        guard process == nil else { return }
        guard let script = Bundle.main.path(forResource: "setup", ofType: "sh") else {
            if mode == "list-games" { pendingGames = nil }
            if changesMainState { state = .failed }
            message = L10n.string("error.internalScriptMissing")
            return
        }

        if mode == "check" {
            state = .checking
        } else if changesMainState {
            state = .installing
        }
        runtimeStatusTitle = runtimeTitle(for: mode)
        operationInProgress = true
        if mode == "setup" {
            log = ""
            progress = 0
            transferText = ""
        }
        needsUserAction = false

        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [script, mode] + arguments
        task.standardOutput = pipe
        task.standardError = pipe
        task.environment = Self.taskEnvironment()

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.consumeChunk(text) }
        }

        task.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            let remainingData = pipe.fileHandleForReading.readDataToEndOfFile()
            let remainingText = String(data: remainingData, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                if !remainingText.isEmpty {
                    self?.consumeChunk(remainingText)
                }
                if self?.pendingOutput.isEmpty == false {
                    self?.consumeLine(self?.pendingOutput ?? "")
                    self?.pendingOutput = ""
                }
                self?.process = nil
                self?.operationInProgress = false
                self?.runtimeStatusTitle = nil
                if mode == "check" { self?.prewarmIfWanted() }
                if mode == "list-games" {
                    if finished.terminationStatus == 0, let loadedGames = self?.pendingGames {
                        self?.games = loadedGames
                    }
                    self?.pendingGames = nil
                }
                if finished.terminationStatus != 0 {
                    if changesMainState { self?.state = .failed }
                    if self?.message.isEmpty == true { self?.message = L10n.string("error.seeLog") }
                } else if mode == "setup" {
                    self?.state = .ready
                    self?.phase = L10n.string("phase.complete")
                }
                if let next = self?.pendingPlay {
                    self?.pendingPlay = nil
                    let failure = finished.terminationStatus != 0 ? self?.message : nil
                    let extras = self?.pendingPlayExtras ?? ("", nil)
                    self?.play(next, renderer: extras.0, status: extras.1)  // runs even after a failed or timed-out task
                    if let failure, !failure.isEmpty, let m = self?.message { self?.message = failure + "\n" + m }
                }
            }
        }

        process = task
        do {
            try task.run()
            // watchdog: a hung setup.sh must never keep `process` set (and Play queued) forever
            let limit: TimeInterval = ["list-games", "create-shortcut", "check"].contains(mode) ? 90
                : ["play", "launch"].contains(mode) ? 180 : 3600  // play/launch may stop_wrapper (up to ~25 s) then cold start
            DispatchQueue.main.asyncAfter(deadline: .now() + limit) { [weak self, weak task] in
                guard let self, let task, self.process === task, task.isRunning else { return }
                self.message = L10n.string("error.taskTimedOut")
                kill(-task.processIdentifier, SIGTERM)  // no-op unless it leads a group
                task.terminate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if task.isRunning { kill(task.processIdentifier, SIGKILL) } }
            }
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            process = nil
            operationInProgress = false
            runtimeStatusTitle = nil
            if mode == "list-games" { pendingGames = nil }
            if changesMainState { state = .failed }
            message = error.localizedDescription
        }
    }

    nonisolated static func taskEnvironment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        return [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "USER": NSUserName(),
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": inherited["TMPDIR"] ?? "/tmp",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "MACSTEAM_UI_LANGUAGE": L10n.languageCode
        ]
    }

    private func consumeChunk(_ text: String) {
        log += text
        pendingOutput += text
        while let newline = pendingOutput.firstIndex(of: "\n") {
            let line = String(pendingOutput[..<newline])
            pendingOutput.removeSubrange(...newline)
            consumeLine(line)
        }
    }

    private func consumeLine(_ value: String) {
        if value.hasPrefix("@@PHASE|") {
            let rawPhase = String(value.dropFirst(8))
            phase = friendlyPhase(rawPhase)
            if rawPhase != "steam" { needsUserAction = false }
        } else if value.hasPrefix("@@NOTICE|renderer_kept|") {
            let id = String(value.dropFirst(23))
            message = L10n.format("play.rendererKept", games.first { $0.id == id }?.name ?? id)
        } else if value.hasPrefix("@@MESSAGE|") {
            message = String(value.dropFirst(10))
        } else if value.hasPrefix("@@ERROR|") {
            message = String(value.dropFirst(8))
        } else if value.hasPrefix("@@PROGRESS|") {
            let parts = value.split(separator: "|", omittingEmptySubsequences: false)
            if runtimeStatusTitle == nil, parts.count >= 2, let value = Double(parts[1]) {
                progress = min(max(value, 0), 100)
            }
        } else if value.hasPrefix("@@DOWNLOAD|") {
            let parts = value.split(separator: "|", omittingEmptySubsequences: false)
            if parts.count >= 4,
               let current = Int64(parts[2]),
               let total = Int64(parts[3]) {
                transferText = formatTransfer(label: String(parts[1]), current: current, total: total)
            }
        } else if value.hasPrefix("@@GAME64|") {
            let parts = value.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false)
            if parts.count == 5,
               let name = decodeProtocolField(parts[2]),
               let installDirectory = decodeProtocolField(parts[3]),
               let rawIconPath = decodeProtocolField(parts[4]) {
                let game = SteamGame(
                    id: String(parts[1]),
                    name: name,
                    installDirectory: installDirectory,
                    iconPath: rawIconPath.isEmpty ? nil : rawIconPath
                )
                if pendingGames != nil, pendingGames?.contains(game) == false {
                    pendingGames?.append(game)
                    fetchLocalizedName(for: game)
                } else if pendingGames == nil, !games.contains(game) {
                    games.append(game)
                    fetchLocalizedName(for: game)
                }
            }
        } else if value.hasPrefix("@@DLSS|") {
            let parts = value.split(separator: "|")
            if parts.count == 3 { dlssSupport[String(parts[1])] = String(parts[2]) }
        } else if value.hasPrefix("@@SHORTCUT|") {
            shortcutMessage = L10n.string("shortcut.created")
        } else if value == "@@STATE|ready" {
            state = .ready
            isSteamRunning = false
            progress = 100
            needsUserAction = false
            message = L10n.string("message.steamReady")
        } else if value == "@@STATE|running" {
            state = .ready
            isSteamRunning = true
            progress = 100
            message = L10n.string("message.steamAlreadyRunning")
        } else if value == "@@STATE|partial" {
            state = .partial
            message = L10n.string("message.resumeSetup")
        } else if value == "@@STATE|not_installed" {
            state = .notInstalled
            progress = 0
            message = L10n.string("message.prepareSetup")
        } else if value == "@@ACTION|steam_installer" {
            needsUserAction = true
            message = L10n.string("message.steamInstallerAction")
        }
    }

    private func decodeProtocolField(_ value: Substring) -> String? {
        guard let data = Data(base64Encoded: String(value)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func formatTransfer(label: String, current: Int64, total: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let currentText = formatter.string(fromByteCount: current)
        guard total > 0 else { return "\(label) · \(currentText)" }
        return "\(label) · \(currentText) / \(formatter.string(fromByteCount: total))"
    }

    private func fetchLocalizedName(for game: SteamGame) {
        guard game.id.allSatisfy(\.isNumber), !requestedLocalizedNames.contains(game.id) else { return }
        requestedLocalizedNames.insert(game.id)

        guard L10n.languageCode == "ko" else { return }
        let cacheKey = "localizedGameName.ko.\(game.id)"
        if let cached = UserDefaults.standard.string(forKey: cacheKey), !cached.isEmpty {
            if cached.caseInsensitiveCompare(game.name) != .orderedSame {
                localizedGameNames[game.id] = cached
            }
            return
        }

        guard let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(game.id)&l=koreana&cc=KR") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
            guard let data,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let app = root[game.id] as? [String: Any],
                  app["success"] as? Bool == true,
                  let details = app["data"] as? [String: Any],
                  let localizedName = details["name"] as? String,
                  !localizedName.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                UserDefaults.standard.set(localizedName, forKey: cacheKey)
                if localizedName.caseInsensitiveCompare(game.name) != .orderedSame {
                    self.localizedGameNames[game.id] = localizedName
                }
            }
        }.resume()
    }

    private func friendlyPhase(_ raw: String) -> String {
        [
            "checking": L10n.string("phase.macCheck"),
            "rosetta": L10n.string("phase.rosetta"),
            "downloading": L10n.string("phase.downloading"),
            "wrapper": L10n.string("phase.wrapper"),
            "windows": L10n.string("phase.windows"),
            "steam": L10n.string("phase.steam"),
            "configuring": L10n.string("phase.configuring"),
            "repairing": L10n.string("phase.repairing"),
            "launching": L10n.string("phase.launching"),
            "stopping": L10n.string("phase.stopping"),
            "ready": L10n.string("phase.complete")
        ][raw] ?? L10n.string("phase.installing")
    }

    private func runtimeTitle(for mode: String) -> String? {
        [
            "launch": L10n.string("phase.launching"),
            "stop": L10n.string("phase.stopping"),
            "repair": L10n.string("phase.repairing")
        ][mode]
    }
}

enum AppSection: Hashable {
    case games
    case management
    case bottle(String)
}

struct ContentView: View {
    @StateObject private var model = InstallerModel()
    @StateObject private var store = BottleStore()
    @State private var selection: AppSection? = .management
    @State private var showStopConfirmation = false
    @State private var showNewBottle = false
    @State private var showInstall = false
    @State private var showOptimize = false
    @State private var droppedInstaller: URL?
    @AppStorage(Tutorial.doneKey) private var tutorialDone = false

    private var selectedBottleID: String? {
        if case .bottle(let id) = selection { return id }
        return nil
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Library") {
                    Label("Home", systemImage: "house.fill").tag(AppSection.management)
                    Label(L10n.string("section.games"), systemImage: "gamecontroller.fill").tag(AppSection.games)
                }
                Section("Bottles") {
                    ForEach(store.bottles) { bottle in
                        BottleSidebarRow(store: store, bottle: bottle) { selection = .management }
                            .tag(AppSection.bottle(bottle.id))
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                SpinningW()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.top, 2).padding(.bottom, 6)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    if let activity = store.activity {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(activity).font(.app(.caption)).lineLimit(2)
                        }
                    }
                    UpdateButton()
                    Button { showOptimize = true } label: {
                        Label("Optimize", systemImage: "bolt.fill").font(.app(.title3)).foregroundStyle(.steamyAccent)
                    }
                    Button { showInstall = true } label: {
                        Label("Install from File", systemImage: "plus.app.fill").font(.app(.title3))
                    }
                    Button { showNewBottle = true } label: {
                        Label("New Bottle", systemImage: "shippingbox")
                    }
                    SettingsLink {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .navigationTitle("WYNIX")
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
        } detail: {
            switch selection ?? .games {
            case .games:
                GameLibraryView(model: model, store: store) {
                    selection = .management
                }
            case .management:
                HomeView(model: model, store: store,
                         openBottle: { selection = .bottle($0.id) },
                         confirmStop: { showStopConfirmation = true })
            case .bottle(let id):
                if let bottle = store.bottles.first(where: { $0.id == id }) {
                    BottleView(store: store, bottle: bottle) { selection = .games }
                        .id(bottle.id)
                } else {
                    ContentUnavailableView("Bottle Not Found", systemImage: "shippingbox")
                }
            }
        }
        .frame(minWidth: 1080, minHeight: 680)
        .onAppear { Updater.shared.start() }
        // Drag a .exe/.msi anywhere onto the window to open Install Software with it.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            WindowsInstallerDrop.load(providers) { url in
                droppedInstaller = url
                showInstall = true
            }
        }
        .onChange(of: showInstall) { _, open in if !open { droppedInstaller = nil } }
        .overlay {
            if !tutorialDone {
                TutorialOverlay(steps: Tutorial.steps(steamBottle: store.bottles.first?.id),
                                selection: $selection) { withAnimation { tutorialDone = true } }
            }
        }
        .onChange(of: selection) { _, section in
            if section == .games, model.state == .ready { model.loadGames() }
        }
        .onChange(of: model.state) { _, state in
            if state == .ready { store.reload() }
            if state == .ready, selection == .games {
                model.loadGames()
            } else if state == .notInstalled || state == .partial || state == .failed, selectedBottleID == nil {
                selection = .management
            }
        }
        .sheet(isPresented: $showNewBottle) {
            NewBottleSheet(store: store) { selection = .bottle($0.id) }
        }
        .sheet(isPresented: $showOptimize) { OptimizeSheet(store: store) }
        .sheet(isPresented: $showInstall) {
            InstallSheet(store: store, bottleID: selectedBottleID, file: droppedInstaller)
        }
        .alert(L10n.string("alert.error.title"), isPresented: Binding(
            get: { store.alertMessage != nil },
            set: { if !$0 { store.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.alertMessage ?? "")
        }
        .alert("Possible piracy software", isPresented: Binding(
            get: { store.riskPrompt != nil },
            set: { if !$0 { store.riskPrompt = nil } }
        )) {
            Button("Cancel", role: .cancel) {}
            Button("Continue at My Own Risk", role: .destructive) { store.riskPrompt?.proceed() }
        } message: {
            Text("\"\(store.riskPrompt?.name ?? "")\" looks like a piracy tool (matched \"\(store.riskPrompt?.marker ?? "")\"). Using it to get games you have not bought is prohibited, violates the Steam Subscriber Agreement and can get your Steam account banned. This project does not support it. Are you sure you want to continue at your own risk?")
        }
        .alert(L10n.string("alert.stop.title"), isPresented: $showStopConfirmation) {
            Button(L10n.string("common.cancel"), role: .cancel) {}
            Button(L10n.string("alert.stop.confirm"), role: .destructive, action: model.stopSteam)
        } message: {
            Text(L10n.string("alert.stop.message"))
        }
    }
}

/// Steam library art card (600x900 cover from Steam's CDN, falls back to header art, then the icon).
/// Sidebar wordmark, same as the website: metallic pink W that flips around + "YNIX" in white,
/// wide black type (system font, expanded width).
struct SpinningW: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle = 0.0
    @State private var sweep = -1.0

    private let font = Font.system(size: 24, weight: .black).width(.expanded)

    private var w: some View {
        Text("W").font(font)
            .foregroundStyle(LinearGradient(
                colors: [Color(hex: 0xC94470), Color(hex: 0xE05A83), Color(hex: 0xFFD3E0), Color(hex: 0xE05A83), Color(hex: 0xC94470)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                GeometryReader { g in
                    LinearGradient(colors: [.clear, Color(hex: 0xFFE4EC).opacity(0.95), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.6)
                        .offset(x: sweep * g.size.width)
                }
                .mask(Text("W").font(font))
            }
            .shadow(color: Color(hex: 0xE05A83).opacity(0.5), radius: 8)
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
    }

    var body: some View {
        HStack(spacing: 0) {
            w
            Text("YNIX").font(font).foregroundStyle(.primary)
        }
        .tracking(-0.6)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { angle = 360 }
            withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) { sweep = 1.1 }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("WYNIX")
    }
}

struct GameCoverCard: View {
    let game: SteamGame
    let name: String
    let dlss: String?
    let starting: Bool
    let disabled: Bool
    let play: () -> Void
    @State private var hovering = false

    private func art(_ file: String) -> URL? {
        URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(game.id)/\(file)")
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            AsyncImage(url: art("library_600x900.jpg")) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else if phase.error != nil {
                    AsyncImage(url: art("header.jpg")) { p in
                        if let img = p.image {
                            ZStack { Color(white: 0.12); img.resizable().scaledToFit() }
                        } else { fallback }
                    }
                } else {
                    Color(white: 0.16)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .clipped()
            .scaleEffect(hovering ? 1.04 : 1)

            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)

            Button(action: play) {
                Group {
                    if starting {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Starting…") }
                    } else {
                        Text("Play")
                    }
                }
                .font(.app(.title3).weight(.medium))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity).padding(.vertical, 9)
                .background(.white, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .accessibilityLabel(starting ? "Starting \(name)" : "Play \(name)")
            .padding(12)
        }
        .aspectRatio(2/3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .topTrailing) { DLSSBadge(level: dlss).padding(8) }
        .help(name)
        .onHover { h in withAnimation(.easeOut(duration: 0.4)) { hovering = h } }
    }

    private var fallback: some View {
        VStack(spacing: 10) {
            GameIconView(game: game)
            Text(name).font(.app(.headline)).multilineTextAlignment(.center).padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.14))
    }
}

struct GameLibraryView: View {
    @ObservedObject var model: InstallerModel
    @ObservedObject var store: BottleStore
    let openManagement: () -> Void
    /// Comma-separated Steam App IDs hidden from the list, like Steam's "Hide this game".
    @AppStorage("hiddenGames") private var hiddenRaw = ""
    @State private var showHidden = false
    @State private var startingID: String?
    @State private var confirmQuitSteam = false
    @State private var pendingPlay: SteamGame?
    @State private var pendingAPI: GameAPI = .unknown
    @State private var benchGame: (name: String, since: Date)?

    private var steamBottle: Bottle? { store.bottles.first { $0.isSteam } }

    /// Detects the game's DirectX version (off the main thread) and, unless the bottle already has that profile, asks before applying it.
    private func play(_ game: SteamGame) {
        guard let bottle = steamBottle else { startPlay(game); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let folder = GameAPI.steamFolder(in: bottle, installDirectory: game.installDirectory)
            let api = folder.map { GameAPI.detect(folder: $0) } ?? .unknown
            DispatchQueue.main.async {
                // Without an installable upscaler, dx12/unknown only need plain optimization, or the dialog would loop.
                let canUpscale = store.upscalerURL(bottle) != nil
                // "Play without changes" only holds while the recommendation is the same one that was skipped.
                let skipped = store.plistDictionary(bottle)["WynixGameProfile_\(game.id)"] as? String == "skip:\(api == .dx11 ? "dx11" : "dx12")"
                let ready = skipped || store.isOptimized(bottle) && (api == .dx11 ? store.boost(bottle) : (!canUpscale || store.upscaleDX12(bottle)))
                if ready { startPlay(game) } else { pendingAPI = api; pendingPlay = game }
            }
        }
    }

    private func applyAndPlay(_ game: SteamGame, _ api: GameAPI) {
        guard let bottle = steamBottle else { return startPlay(game) }
        let go = {
            // dx12 and unknown both take the D3DMetal path (it also runs DX11).
            if api == .dx11 { store.setBoost(bottle, true, notify: false) }
            else if store.upscalerURL(bottle) != nil { store.setUpscaleDX12(bottle, true, notify: false) }
            else if !UserDefaults.standard.bool(forKey: "upscaleNoteShown") {
                UserDefaults.standard.set(true, forKey: "upscaleNoteShown")
                store.alertMessage = "Boost (MetalFX upscaling) can't be used for this bottle: its folder path contains a space. Plain optimization was applied."
            }
            store.setPlist(bottle, ["WynixGameProfile_\(game.id)": "auto-applied"])
            startPlay(game, status: L10n.format(api == .dx11 ? "play.detected.dx11" : "play.detected.dx12", game.name))
        }
        if store.isOptimized(bottle) { go() } else { store.optimizeForGaming(bottle, completion: go) }
    }

    private func startPlay(_ game: SteamGame, status: String? = nil) {
        // Renderer follows the bottle as it is now (Boost already written for this game if applied).
        if !model.isSteamRunning, let bottle = steamBottle { store.applyD3DMetalPreference(bottle) }
        let renderer = steamBottle.map { store.boost($0) ? "dxmt" : "d3dmetal" } ?? ""
        model.play(game, renderer: renderer, status: status)
        GameModeBooster.shared.engage { [model] in model.message = $0 }
        if let b = steamBottle, store.benchmarking(b) { benchGame = (game.name, Date()) }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { startingID = game.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            if startingID == game.id { withAnimation { startingID = nil } }
        }
    }

    private var hidden: Set<String> { Set(hiddenRaw.split(separator: ",").map(String.init)) }
    private func setHidden(_ id: String, _ hide: Bool) {
        var ids = hidden
        if hide { ids.insert(id) } else { ids.remove(id) }
        hiddenRaw = ids.sorted().joined(separator: ",")
    }
    private var visibleGames: [SteamGame] {
        model.games.filter { showHidden || !hidden.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("games.title"))
                        .font(.app(.largeTitle).bold())
                    Text(L10n.string("games.subtitle"))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.state == .ready {
                    Button {
                        model.openSteam()
                    } label: {
                        Label(
                            model.isSteamRunning
                                ? L10n.string("games.showSteam")
                                : L10n.string("games.startSteam"),
                            systemImage: model.isSteamRunning ? "macwindow" : "play.fill"
                        )
                    }
                    .disabled(model.operationInProgress)

                    if let steam = steamBottle {
                        Toggle(isOn: Binding(get: { store.boost(steam) }, set: { store.setBoost(steam, $0) })) {
                            Label("DXMT", systemImage: "bolt.badge.clock")
                        }
                        .toggleStyle(.button)
                        .help("DirectX 11 compatibility mode (DXMT): only for DirectX 11 games that look wrong or run worse on the default. Restart Steam to apply.")
                    }

                    if model.isSteamRunning {
                        Button { confirmQuitSteam = true } label: {
                            Label("Quit Steam", systemImage: "power")
                        }
                        .help("Closes Windows Steam completely, including the icon in the menu bar")
                    }

                    Button {
                        model.loadGames()
                    } label: {
                        Label(L10n.string("common.refresh"), systemImage: "arrow.clockwise")
                    }
                    .disabled(model.operationInProgress)

                    let hiddenCount = model.games.filter { hidden.contains($0.id) }.count
                    if hiddenCount > 0 {
                        Button { showHidden.toggle() } label: {
                            Label(showHidden ? "Hide Hidden" : "Hidden (\(hiddenCount))",
                                  systemImage: showHidden ? "eye.slash" : "eye")
                        }
                        .help("Show or hide the games you hid")
                    }
                }
            }
            .padding(.bottom, steamBottle.map { store.boost($0) } == true ? 8 : 22)

            if let steam = steamBottle, store.boost(steam) {
                Label("Boost is on: in each game's video settings choose 1600×900 (fullscreen). DirectX 11 games only; restart Steam if it was open.",
                      systemImage: "bolt.badge.clock")
                    .font(.app(.callout))
                    .foregroundStyle(.steamyAccent)
                    .padding(.bottom, 14)
            }

            if model.state == .checking {
                Spacer()
                ProgressView(L10n.string("games.loading"))
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if model.state != .ready {
                Spacer()
                ContentUnavailableView {
                    Label(L10n.string("games.setupRequired"), systemImage: "externaldrive.badge.plus")
                } description: {
                    Text(L10n.string("games.setupRequired.detail"))
                } actions: {
                    Button(L10n.string("games.openManagement"), action: openManagement)
                        .buttonStyle(.borderedProminent)
                }
                Spacer()
            } else if model.operationInProgress && model.games.isEmpty {
                Spacer()
                ProgressView(L10n.string("games.finding"))
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if model.games.isEmpty {
                Spacer()
                ContentUnavailableView(
                    L10n.string("games.empty"),
                    systemImage: "gamecontroller",
                    description: Text(L10n.string("games.empty.detail"))
                )
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 18)], spacing: 18) {
                        ForEach(visibleGames) { game in
                            let isHidden = hidden.contains(game.id)
                            GameCoverCard(game: game,
                                          name: model.localizedGameNames[game.id] ?? game.name,
                                          dlss: model.dlssSupport[game.id],
                                          starting: startingID == game.id,
                                          disabled: model.operationInProgress) { play(game) }
                                .opacity(isHidden ? 0.5 : 1)
                                .contextMenu {
                                    Button("Play") { play(game) }
                                    Button(L10n.string("games.createShortcut")) { model.createShortcut(for: game) }
                                    Button(isHidden ? "Unhide Game" : "Hide Game") { setHidden(game.id, !isHidden) }
                                }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if !model.shortcutMessage.isEmpty {
                Label(model.shortcutMessage, systemImage: "checkmark.circle.fill")
                    .font(.app(.callout))
                    .foregroundStyle(.green)
                    .padding(.top, 12)
            }
        }
        .padding(28)
        .onChange(of: model.isSteamRunning) { _, running in  // game session over: show the benchmark
            guard !running, let g = benchGame, let b = steamBottle else { return }
            benchGame = nil
            store.reportBenchmark(b, game: g.name, since: g.since)
        }
        .onAppear {
            if model.state == .ready { model.loadGames() }
        }
        .alert(pendingPlay.map { L10n.format("play.profile.title", $0.name) } ?? "", isPresented: Binding(
            get: { pendingPlay != nil }, set: { if !$0 { pendingPlay = nil } }
        )) {
            Button(L10n.string("play.profile.apply")) { if let game = pendingPlay { applyAndPlay(game, pendingAPI) } }
                .keyboardShortcut(.defaultAction)
            Button(L10n.string("play.profile.skip")) {
                if let game = pendingPlay, let bottle = steamBottle {
                    store.setPlist(bottle, ["WynixGameProfile_\(game.id)": "skip:\(pendingAPI == .dx11 ? "dx11" : "dx12")"])
                    startPlay(game)
                }
            }
            Button(L10n.string("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.format("play.profile.body", L10n.string(pendingAPI == .dx11 ? "play.profile.dx11" : "play.profile.dx12"))
                 + (pendingAPI == .dx11 ? "" : "\n" + L10n.string("play.profile.tip")))
        }
        .alert(L10n.string("alert.stop.title"), isPresented: $confirmQuitSteam) {
            Button(L10n.string("common.cancel"), role: .cancel) {}
            Button(L10n.string("alert.stop.confirm"), role: .destructive, action: model.stopSteam)
        } message: {
            Text(L10n.string("alert.stop.message"))
        }
    }
}

/// Tells the player whether a game can use DLSS (mapped to Apple's MetalFX by D3DMetal).
struct DLSSBadge: View {
    let level: String?

    var body: some View {
        switch level {
        case "framegen":
            badge("DLSS + Frame Gen", icon: "sparkles", color: .green,
                  help: "Supports DLSS and Frame Generation. Turn both on in the game's graphics settings for the most FPS (Optimize enables DLSS in WYNIX).")
        case "dlss":
            badge("DLSS", icon: "sparkles", color: .green,
                  help: "Supports DLSS upscaling. Turn it on in the game's graphics settings for more FPS (Optimize enables DLSS in WYNIX).")
        case "none":
            badge("No DLSS", icon: "minus.circle", color: .secondary,
                  help: "This game has no DLSS. For more FPS lower its resolution in the game's settings (1080p or 1600×900 on your 1440p screen).")
        default:
            EmptyView()
        }
    }

    private func badge(_ text: String, icon: String, color: Color, help: String) -> some View {
        Label(text, systemImage: icon)
            .font(.app(.caption2).weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
            .help(help)
    }
}

struct GameIconView: View {
    let game: SteamGame

    var body: some View {
        Group {
            if let path = game.iconPath, let image = ImageCache.image(path: path) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "gamecontroller.fill")
                    .font(.app(.title2))
                    .foregroundStyle(.blue)
                    .accessibilityLabel("Game icon")
            }
        }
        .frame(width: 40, height: 40)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

struct StatusCard: View {
    @ObservedObject var model: InstallerModel

    var body: some View {
        HStack(spacing: 15) {
            Image(systemName: model.state == .ready ? "checkmark.circle.fill" : "externaldrive.fill")
                .font(.system(size: 30))
                .foregroundStyle(model.state == .ready ? .green : .blue)
                .accessibilityLabel(model.state == .ready ? "Ready" : "Not ready")
                .frame(width: 58, height: 58)
                .background(
                    (model.state == .ready ? Color.green : Color.blue).opacity(0.11),
                    in: RoundedRectangle(cornerRadius: 14)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(model.statusTitle).font(.app(.headline))
                Text(model.message)
                    .font(.app(.callout))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if model.state == .checking || model.runtimeStatusTitle != nil { ProgressView() }
        }
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ManagementRow: View {
    let title: String
    let detail: String
    let icon: String
    let actionTitle: String
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail)
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(actionTitle, action: action)
                .disabled(isDisabled)
        }
        .padding(.vertical, 10)
    }
}

/// Starts Steam silently when WYNIX opens so Play only hands over the game (setup.sh `prewarm`),
/// and closes that Steam again if no game starts or WYNIX quits or stays hidden (`prewarm-stop`).
enum Prewarm {
    static let key = "WynixPrewarm"
    static let hiddenLimit: TimeInterval = 300
    nonisolated(unsafe) private static var hiddenTask: DispatchWorkItem?

    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// Battery under 20% (unplugged) or Low Power Mode: stay quiet.
    static var powerAllows: Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return false }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return true }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                  let pct = d[kIOPSCurrentCapacityKey] as? Int else { continue }
            if pct < 20 { return false }
        }
        return true
    }

    /// `wait` blocks until the script ends (quit path); otherwise it runs detached.
    static func run(_ mode: String, wait: Bool = false) {
        guard let script = Bundle.main.path(forResource: "setup", ofType: "sh") else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [script, mode]
        task.environment = InstallerModel.taskEnvironment()
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return }
        if wait { task.waitUntilExit() }
    }

    static func stopIfStarted(wait: Bool) {
        let marker = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/MacSteamSetup/steam-prewarm").path
        if FileManager.default.fileExists(atPath: marker) { run("prewarm-stop", wait: wait) }
    }

    static func appHidden() {
        hiddenTask?.cancel()
        let item = DispatchWorkItem { stopIfStarted(wait: false) }
        hiddenTask = item
        DispatchQueue.main.asyncAfter(deadline: .now() + hiddenLimit, execute: item)
    }

    static func appUnhidden() { hiddenTask?.cancel(); hiddenTask = nil }
}

/// On quit, offer to close Steam and Windows programs so nothing keeps running in the background.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { _ in Prewarm.appHidden() }
        nc.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: .main) { _ in Prewarm.appUnhidden() }
        MainActor.assumeIsolated { GameModeBooster.shared.restoreAfterCrash() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { GameModeBooster.shared.release(sync: true) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Prewarm.stopIfStarted(wait: true)  // only a Steam that pre-warm started; the prompt below covers the rest
        guard BottleStore.windowsProgramsRunning else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Close Steam and Windows apps too?"
        alert.informativeText = "Steam or other Windows programs are still running in the background. Close everything, or keep them running after WYNIX quits?"
        alert.addButton(withTitle: "Close Everything")
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            BottleStore.closeAllWindowsPrograms()
            return .terminateNow
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct MacSteamSetupApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup { RootView() }
            .windowResizability(.contentMinSize)
        Settings { SettingsView() }
    }
}
