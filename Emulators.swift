import AppKit
import CryptoKit
import Foundation

/// Console emulators that are ordinary Mac apps (no Wine, no bottle). WYNIX downloads a pinned
/// official release, checks its SHA-256, installs it into ~/Applications/WYNIX Emulators, writes
/// a few settings and opens it. Keys, firmware and games are never downloaded: the user dumps
/// them from their own console.
struct Emulator: Identifiable, Hashable {
    struct Download: Hashable { let url: String; let sha256: String }

    let id: String
    let name: String
    let detail: String
    let version: String
    let app: String               // bundle name inside `appsRoot`
    let downloads: [Download]
    let minimumMacOS: Int
    let needsRosetta: Bool

    static let all: [Emulator] = [
        // Switch: Ryubing's Ryujinx (MIT). Universal app with Hypervisor support on Apple silicon,
        // Vulkan through the bundled MoltenVK. Stable channel; upstream publishes no checksum,
        // so the SHA-256 below is our own pin of the official file.
        Emulator(id: "switch", name: "Nintendo Switch", detail: "Ryujinx · native Apple silicon app",
                 version: "1.3.3", app: "Ryujinx.app",
                 downloads: [.init(url: "https://git.ryujinx.app/projects/Ryubing/releases/download/1.3.3/ryujinx-1.3.3-macos_universal.app.tar.gz",
                                   sha256: "e4818bb84c98e0d3120691821e90772099e46101273d3f145ffdb10eee2c0dbb")],
                 minimumMacOS: 12, needsRosetta: false),
        // PS4: shadPS4 (GPL-2.0). The emulator core is an Intel build (runs through Rosetta 2,
        // it executes the PS4's x86-64 code directly); the Qt launcher is native arm64.
        // Checksums are the digests GitHub publishes for these release assets.
        Emulator(id: "ps4", name: "PlayStation 4", detail: "shadPS4 · Mac app (core runs via Rosetta)",
                 version: "0.21.0", app: "shadPS4QtLauncher.app",
                 downloads: [.init(url: "https://github.com/shadps4-emu/shadPS4/releases/download/v.0.21.0/shadps4-macos-sdl-0.21.0.zip",
                                   sha256: "391b585d3131ebf69c585410349117d9436e529151e430156c02f7ffde364b8f"),
                             .init(url: "https://github.com/shadps4-emu/shadps4-qtlauncher/releases/download/shadPS4QtLauncher-2026-11-19-1c35b9b147a8e67474fba6500bdfc309bef6f8e1/shadPS4QtLauncher-macos-qt-2026-11-19-1c35b9b.zip",
                                   sha256: "11364f6e11f9f36c95ae66b8ed62504f1d6a9e411f1d28cd50cbc5f8a7394d9e")],
                 minimumMacOS: 26, needsRosetta: true),
    ]

    static var home = FileManager.default.homeDirectoryForCurrentUser
    static var appsRoot: URL { home.appendingPathComponent("Applications/WYNIX Emulators") }
    static var stateRoot: URL { home.appendingPathComponent("Library/Application Support/Steamy/Emulators") }
    static var shadLauncherDir: URL { home.appendingPathComponent("Library/Application Support/shadPS4QtLauncher") }
    static var shadUserDir: URL { home.appendingPathComponent("Library/Application Support/shadPS4") }

    var appURL: URL { Self.appsRoot.appendingPathComponent(app) }
    var versionFile: URL { Self.stateRoot.appendingPathComponent("\(id).version") }
    /// shadPS4 core lives where the Qt launcher keeps its versions.
    var coreDir: URL { Self.shadLauncherDir.appendingPathComponent("versions/WYNIX \(version)") }

    var installedVersion: String? {
        guard FileManager.default.fileExists(atPath: appURL.path) else { return nil }
        return (try? String(contentsOf: versionFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
    }
    var supported: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: minimumMacOS, minorVersion: 0, patchVersion: 0))
    }
}

// MARK: - Settings (pure, checked by Tests/emulators_check.swift)

enum EmulatorConfig {
    /// Deep merge: keys in `patch` win, everything else in `base` is kept.
    static func merge(_ base: [String: Any], _ patch: [String: Any]) -> [String: Any] {
        var out = base
        for (key, value) in patch {
            if let sub = value as? [String: Any], let old = out[key] as? [String: Any] {
                out[key] = merge(old, sub)
            } else {
                out[key] = value
            }
        }
        return out
    }

    /// shadPS4 defaults the Vulkan pipeline cache to off (emulator_settings.h); on keeps compiled
    /// pipelines between runs, so a game stutters less the second time.
    static let shadPS4Patch: [String: Any] = ["Vulkan": ["pipeline_cache_enabled": true]]

    /// Sets `key=value` in `[section]` of a QSettings INI, adding the section/key when missing.
    static func setINI(_ text: String, section: String, key: String, value: String) -> String {
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let header = "[\(section)]"
        guard let start = lines.firstIndex(of: header) else {
            if !lines.isEmpty { lines.append("") }
            return (lines + [header, "\(key)=\(value)"]).joined(separator: "\n") + "\n"
        }
        var end = start + 1
        while end < lines.count, !lines[end].hasPrefix("[") { end += 1 }
        if let row = (start + 1..<end).first(where: { lines[$0].hasPrefix("\(key)=") }) {
            lines[row] = "\(key)=\(value)"
        } else {
            var insert = end
            while insert > start + 1, lines[insert - 1].isEmpty { insert -= 1 }
            lines.insert("\(key)=\(value)", at: insert)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Value of `key` in `[section]`, if set.
    static func getINI(_ text: String, section: String, key: String) -> String? {
        var inSection = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("[") { inSection = line == "[\(section)]"; continue }
            if inSection, line.hasPrefix("\(key)=") { return String(line.dropFirst(key.count + 1)) }
        }
        return nil
    }

    /// True for a core WYNIX installed (versions/WYNIX <version>/...), which WYNIX may replace.
    static func isWynixCore(_ path: String, versionsDir: String) -> Bool {
        path.hasPrefix(versionsDir + "/WYNIX ")
    }

    /// Adds the core to the launcher's versions.json once (same fields its own "Add version" writes).
    static func addVersion(_ list: [[String: Any]], name: String, path: String, date: String) -> [[String: Any]] {
        if list.contains(where: { $0["path"] as? String == path }) { return list }
        return list + [["name": name, "path": path, "date": date, "codename": "WYNIX", "type": 0]]
    }
}

// MARK: - Install / update / uninstall / open

@MainActor
final class EmulatorStore: ObservableObject {
    @Published private(set) var busy: String?          // emulator id being worked on
    @Published private(set) var installed: [String: String] = [:]
    @Published var alertMessage: String?

    init() { refresh() }

    func refresh() {
        installed = Dictionary(uniqueKeysWithValues: Emulator.all.compactMap { e in e.installedVersion.map { (e.id, $0) } })
    }

    func needsUpdate(_ e: Emulator) -> Bool { installed[e.id].map { $0 != e.version } ?? false }

    func install(_ e: Emulator) {
        guard busy == nil else { return }
        guard e.supported else { alertMessage = "\(e.name) needs macOS \(e.minimumMacOS) or later."; return }
        if e.needsRosetta, !Self.rosettaReady() {
            alertMessage = "\(e.name) needs Rosetta 2. Open Terminal and run: softwareupdate --install-rosetta"
            return
        }
        busy = e.id
        Task.detached {
            var failure: String?
            do { try Self.installBlocking(e) } catch { failure = "\(e.name): \(error.localizedDescription)" }
            let message = failure
            await MainActor.run {
                self.busy = nil
                self.alertMessage = message
                self.refresh()
            }
        }
    }

    func uninstall(_ e: Emulator) {
        guard busy == nil else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: e.appURL)
        try? fm.removeItem(at: e.versionFile)
        if e.id == "ps4" { try? fm.removeItem(at: e.coreDir) }  // saves, games and settings stay
        refresh()
    }

    func open(_ e: Emulator) {
        guard busy == nil else { return }
        if e.id == "ps4" { try? Self.configureShadPS4(e, settings: false) }  // repair core selection only
        NSWorkspace.shared.openApplication(at: e.appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    nonisolated static func rosettaReady() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        p.arguments = ["-x86_64", "/usr/bin/true"]
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Blocking. Downloads and verifies everything first, then swaps the app in.
    nonisolated static func installBlocking(_ e: Emulator) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Emulator.appsRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: Emulator.stateRoot, withIntermediateDirectories: true)
        // Leftovers from an install interrupted by a quit or crash.
        for old in (try? fm.contentsOfDirectory(at: Emulator.stateRoot, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix(".download-") { try? fm.removeItem(at: old) }
        let work = Emulator.stateRoot.appendingPathComponent(".download-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        var extracted: [URL] = []
        for (i, d) in e.downloads.enumerated() {
            let file = work.appendingPathComponent("\(i)-" + (d.url as NSString).lastPathComponent)
            try run("/usr/bin/curl", ["--connect-timeout", "20", "--speed-limit", "1024", "--speed-time", "60",
                                      "--fail", "--location", "--retry", "2", "--silent", "--show-error", "--output", file.path, d.url])
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == d.sha256 else {
                throw NSError(domain: "WYNIX", code: 1, userInfo: [NSLocalizedDescriptionKey: "Download did not match its checksum. Nothing was installed."])
            }
            let out = work.appendingPathComponent("out\(i)")
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
            try run("/usr/bin/ditto", ["-x", "-k", file.path, out.path], when: file.pathExtension == "zip")
            try run("/usr/bin/tar", ["-xzf", file.path, "-C", out.path], when: file.pathExtension != "zip")
            // The Qt launcher zip wraps a tar.gz.
            for inner in (try? fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? [] where inner.lastPathComponent.hasSuffix(".tar.gz") {
                try run("/usr/bin/tar", ["-xzf", inner.path, "-C", out.path])
                try fm.removeItem(at: inner)
            }
            try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", out.path])
            extracted.append(out)
        }

        guard let newApp = extracted.lazy.map({ $0.appendingPathComponent(e.app) }).first(where: { fm.fileExists(atPath: $0.path) }) else {
            throw NSError(domain: "WYNIX", code: 2, userInfo: [NSLocalizedDescriptionKey: "The download did not contain \(e.app)."])
        }
        if e.id == "ps4" {
            guard let core = extracted.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("shadps4").path) }) else {
                throw NSError(domain: "WYNIX", code: 2, userInfo: [NSLocalizedDescriptionKey: "The download did not contain the shadPS4 core."])
            }
            try fm.createDirectory(at: e.coreDir.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: e.coreDir)
            try fm.moveItem(at: core, to: e.coreDir)
        }
        // Same volume: remove + move. Never re-sign: Ryujinx needs its hypervisor/JIT entitlements.
        let backup = work.appendingPathComponent("previous.app")
        let hadApp = (try? fm.moveItem(at: e.appURL, to: backup)) != nil
        do { try fm.moveItem(at: newApp, to: e.appURL) } catch {
            if hadApp { try? fm.moveItem(at: backup, to: e.appURL) }  // keep the working install
            throw error
        }
        try e.version.write(to: e.versionFile, atomically: true, encoding: .utf8)
        if e.id == "ps4" {
            // An update leaves the previous WYNIX core behind: drop it so the launcher moves on.
            let versions = e.coreDir.deletingLastPathComponent()
            for old in (try? fm.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil)) ?? []
            where old.lastPathComponent.hasPrefix("WYNIX ") && old.lastPathComponent != e.coreDir.lastPathComponent {
                try? fm.removeItem(at: old)
            }
            let marker = Emulator.stateRoot.appendingPathComponent("ps4.configured")
            try configureShadPS4(e, settings: !fm.fileExists(atPath: marker.path))
            try? Data().write(to: marker)
        }
    }

    /// Registers WYNIX's core with the launcher (unless the user picked another working core) and,
    /// on the first install only, turns on shadPS4's pipeline cache keeping every other setting.
    nonisolated static func configureShadPS4(_ e: Emulator, settings: Bool) throws {
        let fm = FileManager.default
        let exe = e.coreDir.appendingPathComponent("shadps4").path
        guard fm.fileExists(atPath: exe) else { return }
        try fm.createDirectory(at: Emulator.shadLauncherDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: Emulator.shadUserDir, withIntermediateDirectories: true)

        let versionsURL = Emulator.shadLauncherDir.appendingPathComponent("versions.json")
        let list: [[String: Any]]
        if let data = try? Data(contentsOf: versionsURL) {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }  // not ours to fix
            list = parsed
        } else { list = [] }
        let versionsDir = e.coreDir.deletingLastPathComponent().path
        let updated = EmulatorConfig.addVersion(list.filter { entry in
            let path = entry["path"] as? String ?? ""
            return !EmulatorConfig.isWynixCore(path, versionsDir: versionsDir) || path == exe
        }, name: "WYNIX \(e.version)", path: exe, date: "2026-10-30")
        try JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .withoutEscapingSlashes]).write(to: versionsURL)

        let iniURL = Emulator.shadLauncherDir.appendingPathComponent("qt_ui.ini")
        var ini = (try? String(contentsOf: iniURL, encoding: .utf8)) ?? ""
        let selected = EmulatorConfig.getINI(ini, section: "version_manager", key: "versionSelected") ?? ""
        // A quoted/escaped QSettings value or CRLF file came from the launcher itself: leave it.
        let editable = !selected.contains("\"") && !ini.contains("\r")
        if editable, selected != exe, selected.isEmpty || !fm.fileExists(atPath: selected) || EmulatorConfig.isWynixCore(selected, versionsDir: versionsDir) {
            ini = EmulatorConfig.setINI(ini, section: "version_manager", key: "versionPath", value: e.coreDir.deletingLastPathComponent().path)
            ini = EmulatorConfig.setINI(ini, section: "version_manager", key: "versionSelected", value: exe)
            try ini.write(to: iniURL, atomically: true, encoding: .utf8)
        }

        guard settings else { return }
        let configURL = Emulator.shadUserDir.appendingPathComponent("config.json")
        var config: [String: Any] = [:]
        if let data = try? Data(contentsOf: configURL) {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            config = parsed
        }
        let merged = EmulatorConfig.merge(config, EmulatorConfig.shadPS4Patch)
        try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: configURL)
    }

    nonisolated private static func run(_ exe: String, _ args: [String], when condition: Bool = true) throws {
        guard condition else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "WYNIX", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "\((exe as NSString).lastPathComponent) failed (\(p.terminationStatus))."])
        }
    }
}
