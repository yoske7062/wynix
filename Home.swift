import AppKit
import SwiftUI

/// WYNIX's start screen: a calm greeting with the next thing to do, then your games, stores and spaces.
struct HomeView: View {
    @ObservedObject var model: InstallerModel
    @ObservedObject var store: BottleStore
    let openBottle: (Bottle) -> Void
    let confirmStop: () -> Void
    var openGames: () -> Void = {}
    var installApp: () -> Void = {}
    var optimize: () -> Void = {}

    @State private var search = ""
    @StateObject private var emulatorStore = EmulatorStore()
    /// Same list the Games tab hides (comma-separated Steam App IDs).
    @AppStorage("hiddenGames") private var hiddenRaw = ""
    @AppStorage(Tutorial.doneKey) private var tutorialDone = false

    private func matches(_ text: String) -> Bool {
        search.isEmpty || text.localizedCaseInsensitiveContains(search)
    }

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 14, alignment: .top)]

    private var games: [SteamGame] {
        let hidden = Set(hiddenRaw.split(separator: ",").map(String.init))
        return model.games.filter { !hidden.contains($0.id) }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "Good morning"
        case 12..<19: "Good afternoon"
        default: "Good evening"
        }
    }

    private var firstName: String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
    }

    /// One line: what to do next.
    private var prompt: String {
        switch model.state {
        case .ready: games.isEmpty ? "Install a game in Steam and it shows up here." : "What are we playing today?"
        case .installing: "Installing Steam. This takes a few minutes."
        case .checking: "Getting things ready…"
        default: "Let's start by installing Steam."
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 48) {
                    HStack {
                        Spacer()
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                            TextField("Search stores and apps", text: $search).textFieldStyle(.plain)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .frame(width: 260)
                        .clearGlass(in: Capsule())
                    }
                    .padding(.bottom, -40)
                    if search.isEmpty { hero { withAnimation(.easeOut(duration: 0.35)) { proxy.scrollTo("stores", anchor: .top) } } }
                    if model.state == .ready && !games.isEmpty && search.isEmpty { continuePlaying }

                    section("Stores") {
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
                    .id("stores")

                    let emulators = Emulator.all.filter { matches($0.name + " " + $0.detail + " emulator") }
                    if !emulators.isEmpty {
                        section("Emulators") {
                            ForEach(emulators) { emu in
                                let version = emulatorStore.installed[emu.id]
                                CatalogCard(title: emu.name,
                                            detail: emulatorStore.busy == emu.id ? "Downloading and installing…" : (emu.supported ? emu.detail : "Needs macOS \(emu.minimumMacOS) or later"),
                                            icon: "gamecontroller.fill", tint: .gray, logo: emu.id == "switch" ? "ryujinx" : "shadps4",
                                            actionTitle: version == nil ? "Install" : (emulatorStore.needsUpdate(emu) ? "Update" : "Open"),
                                            busy: emulatorStore.busy != nil || !emu.supported) {
                                    if version == nil || emulatorStore.needsUpdate(emu) { emulatorStore.install(emu) } else { emulatorStore.open(emu) }
                                }
                                .contextMenu {
                                    if version != nil, emulatorStore.busy == nil {
                                        Button("Open") { emulatorStore.open(emu) }
                                        Button("Reinstall \(emu.version)") { emulatorStore.install(emu) }
                                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([emu.appURL]) }
                                        Button("Uninstall (keeps saves and settings)", role: .destructive) { emulatorStore.uninstall(emu) }
                                    }
                                }
                            }
                        }
                        Text("Emulators run as Mac apps, not in bottles. WYNIX never downloads keys, firmware, BIOS or games: dump them from a console you own. Right-click a card to update or uninstall.")
                            .font(.app(.caption)).foregroundStyle(.secondary)
                    }

                    let bottles = store.bottles.filter { matches($0.name) }
                    if !bottles.isEmpty {
                        section("Windows Spaces") {
                            ForEach(bottles) { bottle in
                                let count = store.programs[bottle.id]?.count ?? 0
                                CatalogCard(title: bottle.name,
                                            detail: "Its own Windows space · \(count) \(count == 1 ? "program" : "programs")",
                                            icon: "shippingbox", tint: .gray, actionTitle: "Open") { openBottle(bottle) }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.string("disclaimer.compatibility"))
                        Text("Unofficial. Not affiliated with Valve, Apple, CodeWeavers or Sikarugir.")
                    }
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 40).padding(.vertical, 28)
                .frame(maxWidth: 1080)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { store.bottles.forEach { if store.programs[$0.id] == nil { store.scanPrograms($0) } } }
        .alert("Emulators", isPresented: Binding(get: { emulatorStore.alertMessage != nil },
                                                 set: { if !$0 { emulatorStore.alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(emulatorStore.alertMessage ?? "") }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.app(.title3).weight(.semibold))
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) { content() }
        }
    }

    // MARK: Greeting

    private func hero(showStores: @escaping () -> Void) -> some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                (Text(greeting + (firstName.isEmpty ? "" : ", ")).fontWeight(.light) + Text(firstName).fontWeight(.semibold))
                    .font(.app(size: 36))
                Text(prompt).font(.app(size: 36, weight: .light)).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            if model.state == .ready && games.isEmpty {
                StepsLine(current: 2)
            } else if model.state != .ready && model.state != .checking {
                StepsLine(current: 1)
            }

            chips(showStores: showStores)

            if model.state == .installing {
                VStack(spacing: 6) {
                    ProgressView(value: model.progress, total: 100)
                        .tint(model.needsUserAction ? .orange : .primary)
                    Text(model.transferText.isEmpty ? model.message : model.transferText)
                        .font(.app(.caption)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: 420)
            } else if model.state == .failed || model.state == .partial {
                Text(model.message).font(.app(.caption)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 520)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 64)
    }

    @ViewBuilder private func chips(showStores: @escaping () -> Void) -> some View {
        let tour = { tutorialDone = false }
        let row = Group {
            switch model.state {
            case .ready:
                if games.isEmpty {
                    Chip(title: model.isSteamRunning ? "Show Steam" : "Open Steam", icon: "play.fill", primary: true, action: model.openSteam)
                        .disabled(model.isBusy)
                } else {
                    Chip(title: "Play a game", icon: "play.fill", primary: true, action: openGames)
                    Chip(title: model.isSteamRunning ? "Show Steam" : "Open Steam", icon: "macwindow", action: model.openSteam)
                        .disabled(model.isBusy)
                }
                Chip(title: "Add a store", icon: "bag", action: showStores)
                Chip(title: "Install a Windows app", icon: "plus.square", action: installApp)
                if !games.isEmpty {
                    Chip(title: "Make games faster", icon: "gauge.with.dots.needle.67percent", action: optimize)
                } else {
                    Chip(title: "Take the tour", icon: "sparkles", action: tour)
                }
            case .notInstalled, .partial, .failed:
                Chip(title: model.primaryTitle, icon: "arrow.down.circle", primary: true, action: model.primaryAction)
                    .disabled(model.isBusy)
                Chip(title: "Other stores", icon: "bag", action: showStores)
                Chip(title: "Install a Windows app", icon: "plus.square", action: installApp)
                Chip(title: "Take the tour", icon: "sparkles", action: tour)
            case .installing, .checking:
                EmptyView()
            }
        }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { row }
            VStack(spacing: 10) { row }
        }
    }

    // MARK: Games

    private var continuePlaying: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your games").font(.app(.title3).weight(.semibold))
                Spacer()
                Button("Show All", action: openGames).buttonStyle(.link).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(games.prefix(12)) { game in
                        LibraryCover(game: game, action: openGames)
                    }
                }
                .padding(.vertical, 4)
            }
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
            actionTitle: model.state == .ready ? (model.isSteamRunning ? "Show" : "Open") : "Install",
            busy: model.isBusy
        ) {
            if model.state == .ready { model.openSteam() } else { model.primaryAction() }
        }
    }
}

/// "1 Install Steam › 2 Sign in › 3 Press Play", with the current step lit.
struct StepsLine: View {
    let current: Int

    var body: some View {
        HStack(spacing: 10) {
            step(1, "Install Steam")
            Image(systemName: "chevron.right").font(.app(.caption)).foregroundStyle(.tertiary)
            step(2, "Sign in and get a game")
            Image(systemName: "chevron.right").font(.app(.caption)).foregroundStyle(.tertiary)
            step(3, "Press Play")
        }
        .font(.app(.callout))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current) of 3. 1, Install Steam. 2, Sign in and get a game. 3, Press Play.")
    }

    private func step(_ n: Int, _ title: String) -> some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().strokeBorder(.primary.opacity(n == current ? 0.9 : 0.25))
                if n < current {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                } else {
                    Text("\(n)").font(.system(size: 10, weight: .semibold))
                }
            }
            .frame(width: 18, height: 18)
            Text(title)
        }
        .foregroundStyle(n == current ? Color.primary : Color.secondary)
    }
}

/// Outline capsule with a small WYNIX-pink line icon; the one `primary` chip per screen has a brighter edge.
struct Chip: View {
    let title: String
    let icon: String
    var tint: Color = .steamyAccent
    var primary = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(primary ? Color.primary : tint)
                    .accessibilityHidden(true)
                Text(title).lineLimit(1)
            }
            .font(.app(.body).weight(primary ? .semibold : .regular))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 18).padding(.vertical, 11)
            .background(.primary.opacity(hovering ? 0.1 : primary ? 0.07 : 0.03), in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(primary ? 0.45 : 0.18)))
            .contentShape(Capsule())
            .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}

/// One game cover: art and the name under it.
struct LibraryCover: View {
    let game: SteamGame
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                AsyncImage(url: URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(game.id)/library_600x900.jpg")) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        ZStack {
                            Color.primary.opacity(0.08)
                            Text(game.name).font(.app(.caption)).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center).padding(8)
                        }
                    }
                }
                .frame(width: 124, height: 186)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(hovering ? 0.6 : 0.1)))
                Text(game.name).font(.app(.callout)).foregroundStyle(.secondary).lineLimit(1).frame(width: 124, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .help(game.name)
        .accessibilityLabel("\(game.name), show in Games")
    }
}

/// Store or space tile: logo, name, one line, and its action as a small capsule.
struct CatalogCard: View {
    let title: String
    let detail: String
    let icon: String
    let tint: Color
    var logo: String?
    let actionTitle: String
    var busy = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Group {
                    if let logo, let image = BrandLogo.image(logo) {
                        Image(nsImage: image).renderingMode(image.isTemplate ? .template : .original).resizable().scaledToFit().padding(image.isTemplate ? 9 : 4)
                            .foregroundStyle(.white)
                            .background(tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        Image(systemName: icon).font(.system(size: 17, weight: .light)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.15)))
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: 40, height: 40)
                Spacer(minLength: 8)
                Button(action: action) {
                    Text(actionTitle).font(.app(.callout).weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .overlay(Capsule().strokeBorder(.primary.opacity(0.2)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .opacity(busy ? 0.45 : 1)
                .accessibilityLabel("\(actionTitle) \(title)")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.app(.body).weight(.semibold)).lineLimit(1)
                Text(detail).font(.app(.caption)).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
            }
        }
        .padding(14)
        .background(.primary.opacity(hovering ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.09)))
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}

/// Slow light streaks behind the glass. Paused under Reduce Motion and whenever the window
/// isn't frontmost (so it never draws while a game is playing).
struct AuroraBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion || activeState == .inactive)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { g, size in
                let dark = scheme == .dark
                // A wide soft glow plus a narrow bright core make one light ribbon.
                // WYNIX rose: a wide soft glow plus a narrow bright core make one light ribbon.
                streak(&g, size, t: t, period: 40, color: Color(hex: 0xF08FB0), alpha: dark ? 0.75 : 0.3, base: CGPoint(x: 0.35, y: 0.62), angle: -22, thickness: 0.24)
                streak(&g, size, t: t, period: 40, color: Color(hex: 0xFFE0EA), alpha: dark ? 0.6 : 0.3, base: CGPoint(x: 0.35, y: 0.62), angle: -22, thickness: 0.035)
                streak(&g, size, t: t + 17, period: 52, color: Color(hex: 0xE88AA6), alpha: dark ? 0.5 : 0.2, base: CGPoint(x: 0.95, y: 0.02), angle: -12, thickness: 0.14)
            }
        }
        .background(scheme == .dark ? Color(hex: 0x070507) : Color(hex: 0xF4F0F2))
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    /// A soft elongated glow that drifts on a slow loop.
    private func streak(_ g: inout GraphicsContext, _ size: CGSize, t: Double, period: Double, color: Color,
                        alpha: Double, base: CGPoint, angle: Double, thickness: Double) {
        let phase = (t.truncatingRemainder(dividingBy: period)) / period * 2 * .pi
        let center = CGPoint(x: size.width * (base.x + 0.08 * sin(phase)), y: size.height * (base.y + 0.06 * cos(phase)))
        let r = max(size.width, size.height) * 0.75
        var layer = g
        layer.translateBy(x: center.x, y: center.y)
        layer.rotate(by: .degrees(angle + 6 * sin(phase)))
        layer.scaleBy(x: 1, y: thickness)
        layer.fill(Path(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)),
                   with: .radialGradient(Gradient(colors: [color.opacity(alpha), color.opacity(alpha * 0.35), .clear]),
                                         center: .zero, startRadius: 0, endRadius: r))
    }
}

struct SidebarHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).font(.app(.caption)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 2)
    }
}

/// A text row in the sidebar list; the selected one sits on a soft glass pill.
struct SidebarItem: View {
    let title: String
    let selected: Bool
    var secondary = false
    let action: () -> Void

    var body: some View {
        Text(title).lineLimit(1)
            .foregroundStyle(secondary ? .secondary : .primary)
            .sidebarRow(selected: selected, action: action)
    }
}

struct SidebarRowStyle: ViewModifier {
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .font(.app(.body).weight(selected ? .semibold : .regular))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background {
                if selected {
                    Color.clear.clearGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else if hovering {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.06))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onHover { hovering = $0 }
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, action)
    }
}

/// Round icon button in the slim rail; the selected one is a glass circle.
struct RailButton: View {
    let icon: String
    let label: String
    var selected = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: selected ? .regular : .light))
                .foregroundStyle(selected ? .primary : .secondary)
                .frame(width: 40, height: 40)
                .background {
                    if selected {
                        Color.clear.clearGlass(in: Circle())
                    } else if hovering {
                        Circle().fill(.primary.opacity(0.06))
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

extension View {
    func sidebarRow(selected: Bool, action: @escaping () -> Void) -> some View {
        modifier(SidebarRowStyle(selected: selected, action: action))
    }

    /// See-through glass with a thin light edge, like the reference.
    @ViewBuilder func clearGlass<S: InsettableShape>(in shape: S) -> some View {
        let edge = shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.38), .white.opacity(0.06), .white.opacity(0.16)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        // A thin frost at low opacity: the light behind stays clearly visible, just softened.
        background(.white.opacity(0.03), in: shape)
            .background(.ultraThinMaterial.opacity(0.3), in: shape)
            .overlay(edge)
    }

    /// Liquid Glass on macOS 26+, a material on older systems (deployment target is macOS 14).
    @ViewBuilder func wynixGlass<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }
}

/// Store brand marks bundled from Simple Icons (Resources/Logos, CC0 SVG paths).
/// Trademarks belong to their owners and are used only to identify each store.
enum BrandLogo {
    private static var cache: [String: NSImage] = [:]
    static func image(_ name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        // SVG = one-color store mark (tinted); PNG = the app's own full-color icon (emulators).
        let svg = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "Logos")
        guard let url = svg ?? Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Logos"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = svg != nil
        cache[name] = image
        return image
    }
}

extension Color {
    /// Accent: WYNIX pink from the app icon. Lighter in Dark Mode, deeper in Light Mode so it
    /// stays readable as text. WCAG contrast: 5.5:1 on the dark window, 6.2:1 on white.
    static let steamyAccent = Color(nsColor: NSColor(name: "steamyAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0xE8 / 255, green: 0x6A / 255, blue: 0x92 / 255, alpha: 1)
            : NSColor(srgbRed: 0xB0 / 255, green: 0x2E / 255, blue: 0x5F / 255, alpha: 1)
    })
    /// Fill for prominent buttons, from the icon's pink. White text on it: 5.1:1.
    static let wynixFill = Color(hex: 0xC23A6B)

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
    /// Fixed-size text that still follows the app's Text Size setting.
    static func app(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let stored = UserDefaults.standard.double(forKey: "textScale")
        return .system(size: size * (stored == 0 ? 1 : stored), weight: weight)
    }

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
    @AppStorage(Prewarm.key) private var prewarm = false
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
            Toggle("Start Steam in the background when WYNIX opens (games open faster)", isOn: $prewarm)
                .help("Steam starts hidden so Play only has to hand over the game. It closes by itself if you don't start a game within 5 minutes, or when WYNIX quits. Skipped on low battery or Low Power Mode.")
            Toggle("Show advanced bottle options by default", isOn: $advanced)
            Button("Show the WYNIX tour again") { tutorialDone = false }
            Link("Support WYNIX on Ko-fi (optional, nothing is locked)", destination: URL(string: "https://ko-fi.com/wynix")!)
            Link("Terms, privacy and licenses", destination: URL(string: "https://wynix.app/legal.html")!)

            Section("Help") {
                HelpItem("Home", "Game stores and your bottles. Press Install Steam once, then Open it and sign in with your normal account.")
                HelpItem("Games", "Every Steam game you installed. Press Play: WYNIX detects DirectX 11 or 12 and recommends the best settings. Right click a game to make a Dock shortcut or hide it.")
                HelpItem("Bottles", "A bottle is a small Windows setup that lives inside WYNIX. Each one keeps its own programs and settings, so a broken game can't mess up the rest.")
                HelpItem("Install from File", "Runs any Windows installer (.exe or .msi), games or not. The program shows up in the bottle and in ~/Applications like a Mac app.")
                HelpItem("New Bottle", "Makes a separate setup. Use it when one game needs different graphics settings than the others.")
                HelpItem("Optimize", "Applies the best settings to your bottles in one click: frame cap and Mac shortcuts. Play also does this for each game.")
                HelpItem("Boost", "Pick a lower resolution in the game (1280×720 or 1600×900, your screen's shape) and MetalFX sharpens it up to 1080p. Play picks the right mode for each game; DirectX 12 games are capped at 60 FPS.")
                HelpItem("Graphics layer", "Play picks it for you. If a game crashes or looks wrong, turn on D3DMetal 3.0 (compatibility) in the bottle's options.")
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

/// Keeps Steam out of the game's way. Every 5 s while WYNIX runs:
/// - Steam.exe (downloads, unpacking, updates) always runs in the background band: macOS keeps it
///   on the efficiency cores, so a download no longer heats the Mac (it finishes a bit slower).
/// - While a game runs, Steam's UI and service join it, so the game gets the performance cores.
/// - With no game, the UI goes back to normal so the Steam window stays smooth.
/// A game can't be raised above normal without admin rights; lowering everything else is the lever.
enum SteamGovernor {
    nonisolated private static let work = DispatchQueue(label: "wynix.steamgovernor", qos: .utility)
    nonisolated(unsafe) private static var lowered: Set<pid_t> = []
    nonisolated(unsafe) private static var boosted: Set<pid_t> = []
    nonisolated(unsafe) private static var wasGameRunning = false
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?

    static func start() {
        let t = DispatchSource.makeTimerSource(queue: work)
        t.schedule(deadline: .now() + 2, repeating: 5, leeway: .seconds(1))
        t.setEventHandler { tick() }
        t.resume()
        timer = t
    }

    nonisolated private static func tick() {
        let ps = Process()
        let pipe = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,args="]
        ps.standardOutput = pipe
        guard (try? ps.run()) != nil else { return }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        ps.waitUntilExit()
        var client: [pid_t] = [], helpers: [pid_t] = [], games: [pid_t] = []
        var mainHelper: pid_t?
        var gameRunning = false
        for line in output.lowercased().split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let pid = pid_t(parts[0]) else { continue }
            let args = parts[1]
            if args.contains("steamapps\\common\\") { gameRunning = true; games.append(pid) }
            else if args.contains("\\steam.exe") { client.append(pid) }
            else if args.contains("steamwebhelper.exe") || args.contains("steamservice.exe") {
                helpers.append(pid)
                if args.contains("steamwebhelper.exe"), !args.contains("--type=") { mainHelper = pid }  // the UI process
            }
        }
        // Steam starts the game, so a game would inherit Steam's background band: lift it, once per pid.
        for pid in games where !boosted.contains(pid) { if taskpolicy("-B", pid) { boosted.insert(pid) } }
        boosted.formIntersection(games)
        if let c = client.first { if lastClient?.pid != c { lastClient = (c, Date()) } } else { lastClient = nil }
        let steamSettled = lastClient.map { Date().timeIntervalSince($0.since) > 120 } ?? false  // past login/update restarts
        quitSteamIfWindowClosed(mainHelper: mainHelper, steamRunning: steamSettled, gameRunning: gameRunning)
        if wasGameRunning && !gameRunning {  // game over (Steam stays open): give Chrome & co. their CPU back
            DispatchQueue.main.async { MainActor.assumeIsolated { GameModeBooster.shared.release() } }
        }
        wasGameRunning = gameRunning
        let want = Set(client + (gameRunning ? helpers : []))
        for pid in want.subtracting(lowered) where taskpolicy("-b", pid) { lowered.insert(pid) }
        for pid in lowered.subtracting(want) {
            if helpers.contains(pid) { _ = taskpolicy("-B", pid) }  // game over: UI back to normal
            lowered.remove(pid)  // or the process is gone
        }
    }

    /// Steam's window X only closes its UI process (steamwebhelper). Steam.exe stays alive in the
    /// hidden tray, takes the exit for a crash and restarts the UI ~5 s later: the window "reopens
    /// by itself" (measured 2026-11-19). On a Mac, closing the window means quit, so when the UI
    /// process is replaced and no game is running, stop Steam properly. A UI that lived under 30 s
    /// (login, update restarts) is left alone.
    nonisolated(unsafe) private static var lastHelper: (pid: pid_t, since: Date)?
    nonisolated(unsafe) private static var lastClient: (pid: pid_t, since: Date)?
    nonisolated private static func quitSteamIfWindowClosed(mainHelper: pid_t?, steamRunning: Bool, gameRunning: Bool) {
        defer {  // keep the last UI across a gap, forget it only when Steam itself is gone
            if let h = mainHelper { if lastHelper?.pid != h { lastHelper = (h, Date()) } } else if !steamRunning { lastHelper = nil }
        }
        // Act only when a NEW UI process shows up (what the X causes), never on a one-tick gap,
        // and never while WYNIX is starting Steam or a game.
        guard steamRunning, !gameRunning, let last = lastHelper, let now = mainHelper, now != last.pid,
              Date().timeIntervalSince(last.since) > 30, !launchInProgress(),
              let script = Bundle.main.path(forResource: "setup", ofType: "sh") else { return }
        let stop = Process()
        stop.executableURL = URL(fileURLWithPath: "/bin/bash")
        stop.arguments = [script, "stop"]
        stop.standardOutput = FileHandle.nullDevice
        stop.standardError = FileHandle.nullDevice
        try? stop.run()
        stop.waitUntilExit()
    }

    nonisolated private static func launchInProgress() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "setup\\.sh (play|launch|prewarm)"]
        p.standardOutput = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus == 0
    }

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
