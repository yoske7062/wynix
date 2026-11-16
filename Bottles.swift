import AppKit
import Foundation
import SwiftUI

// MARK: - Model

/// A Sikarugir wrapper in ~/Applications/Sikarugir. One wrapper = one bottle.
struct Bottle: Identifiable, Hashable {
    let url: URL
    var id: String { url.path }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var contents: URL { url.appendingPathComponent("Contents") }
    var plist: URL { contents.appendingPathComponent("Info.plist") }
    var driveC: URL { contents.appendingPathComponent("drive_c") }
    var prefix: URL { contents.appendingPathComponent("SharedSupport/prefix") }
    var launcher: URL { contents.appendingPathComponent("MacOS/Sikarugir") }
    var wine: URL { contents.appendingPathComponent("SharedSupport/wine/bin/wine") }
    var programsFile: URL { contents.appendingPathComponent(".macsteam-programs.json") }
    var scriptsDir: URL { driveC.appendingPathComponent("macsteam-scripts") }
    var steamDir: URL { driveC.appendingPathComponent("Program Files (x86)/Steam") }
    /// Managed by setup.sh: name, location and D3DMetal are fixed.
    var isSteam: Bool { name == "Steam" }

    func windowsPath(_ file: URL) -> String {
        // resolvingSymlinksInPath leaves missing files unresolved, so try both spellings of drive_c.
        let path = file.resolvingSymlinksInPath().path
        for root in [driveC.path, driveC.resolvingSymlinksInPath().path] where path.hasPrefix(root + "/") {
            return "C:\\" + path.dropFirst(root.count + 1).replacingOccurrences(of: "/", with: "\\")
        }
        return "Z:" + path.replacingOccurrences(of: "/", with: "\\")
    }

    func unixURL(windowsPath raw: String) -> URL? {
        let path = raw.replacingOccurrences(of: "\\", with: "/")
        guard path.count >= 3, path.dropFirst().first == ":" else { return nil }
        let drive = path.prefix(1).lowercased()
        let rest = String(path.dropFirst(2).drop(while: { $0 == "/" }))
        switch drive {
        case "c": return driveC.appendingPathComponent(rest)
        case "z": return URL(fileURLWithPath: "/" + rest)
        default: return prefix.appendingPathComponent("dosdevices/\(drive):/\(rest)")
        }
    }
}

struct WinProgram: Identifiable, Hashable, Codable {
    var name: String
    var path: String
    var custom = false
    var iconData: Data?
    var id: String { path }
    enum CodingKeys: String, CodingKey { case name, path }
}

enum GraphicsBackend: String, CaseIterable, Identifiable {
    case auto = "Auto", d3dmetal = "D3DMetal", dxmt = "DXMT", dxvk = "DXVK", wined3d = "WineD3D"
    var id: String { rawValue }
    /// Auto starts on D3DMetal and is re-picked per program at launch (see `detect`).
    var plistValues: [String: Any] {
        let concrete = self == .auto ? .d3dmetal : self
        return ["D3DMETAL": concrete == .d3dmetal ? 1 : 0, "DXMT": concrete == .dxmt ? 1 : 0,
                "DXVK": concrete == .dxvk ? 1 : 0, "SteamyAutoGraphics": self == .auto ? 1 : 0]
    }

    /// Picks a backend from the DirectX DLLs a program (or the DLLs next to it, e.g. UnityPlayer.dll)
    /// references. D3DMetal covers DX10-12; it has no DX9 path, so older games go to WineD3D.
    static func detect(for program: URL) -> GraphicsBackend {
        let fm = FileManager.default
        var files = [program]
        let siblings = (try? fm.contentsOfDirectory(at: program.deletingLastPathComponent(), includingPropertiesForKeys: [.fileSizeKey])) ?? []
        files += siblings.filter { $0.pathExtension.lowercased() == "dll" }.prefix(60)
        var found = Set<String>()
        for file in files {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size < 300_000_000, let data = try? Data(contentsOf: file, options: .alwaysMapped) else { continue }
            for dll in ["d3d12", "d3d11", "d3d10", "d3d9", "d3d8", "ddraw"] where !found.contains(dll) {
                if [dll + ".dll", dll.uppercased() + ".dll", dll.uppercased() + ".DLL"].contains(where: { data.range(of: Data($0.utf8)) != nil }) {
                    found.insert(dll)
                }
            }
        }
        if found.contains("d3d12") || found.contains("d3d11") || found.contains("d3d10") { return .d3dmetal }
        if found.contains("d3d9") || found.contains("d3d8") || found.contains("ddraw") { return .wined3d }
        return .d3dmetal
    }
}

let windowsVersions: [(id: String, title: String)] = [
    ("win11", "Windows 11"), ("win10", "Windows 10"), ("win81", "Windows 8.1"),
    ("win8", "Windows 8"), ("win7", "Windows 7"), ("winxp", "Windows XP")
]

let dllModes = ["native,builtin", "builtin,native", "native", "builtin", ""]

func dllModeTitle(_ mode: String) -> String {
    mode.isEmpty ? "disabled" : mode.replacingOccurrences(of: ",", with: ", ")
}

func isValidBottleName(_ name: String) -> Bool {
    name.range(of: #"^[A-Za-z0-9 _.-]{1,40}$"#, options: .regularExpression) != nil && !name.hasPrefix(".")
}

// MARK: - Windows binary parsing (shortcut targets and EXE icons)

private struct Bytes {
    let data: Data
    func u8(_ o: Int) -> Int? { o >= 0 && o < data.count ? Int(data[data.startIndex + o]) : nil }
    func u16(_ o: Int) -> Int? { guard let a = u8(o), let b = u8(o + 1) else { return nil }; return a | b << 8 }
    func u32(_ o: Int) -> Int? { guard let a = u16(o), let b = u16(o + 2) else { return nil }; return a | b << 16 }
    func slice(_ o: Int, _ n: Int) -> Data? {
        guard o >= 0, n >= 0, o + n <= data.count else { return nil }
        return data.subdata(in: data.startIndex + o ..< data.startIndex + o + n)
    }
    func cString(_ o: Int) -> String? {
        var end = o
        while let c = u8(end), c != 0 { end += 1 }
        return slice(o, end - o).flatMap { String(data: $0, encoding: .windowsCP1252) }
    }
}

enum WinBinary {
    /// Reads target path and icon location from a .lnk (MS-SHLLINK).
    static func shortcut(_ url: URL) -> (target: String?, icon: String?) {
        guard let data = try? Data(contentsOf: url) else { return (nil, nil) }
        let b = Bytes(data: data)
        guard b.u32(0) == 0x4C, let flags = b.u32(0x14) else { return (nil, nil) }
        var off = 0x4C
        var target: String?
        if flags & 0x1 != 0 {
            guard let size = b.u16(off) else { return (nil, nil) }
            off += 2 + size
        }
        if flags & 0x2 != 0, let size = b.u32(off) {
            if let infoFlags = b.u32(off + 8), infoFlags & 1 != 0, let base = b.u32(off + 16) {
                target = b.cString(off + base)
            }
            off += size
        }
        let unicode = flags & 0x80 != 0
        var icon: String?
        for bit in [0x4, 0x8, 0x10, 0x20, 0x40] where flags & bit != 0 {
            guard let count = b.u16(off) else { break }
            let length = unicode ? count * 2 : count
            if bit == 0x40, let raw = b.slice(off + 2, length) {
                icon = String(data: raw, encoding: unicode ? .utf16LittleEndian : .windowsCP1252)
            }
            off += 2 + length
        }
        return (target, icon)
    }

    /// Builds an .ico from the first RT_GROUP_ICON of a PE file.
    static func icon(exe url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        let b = Bytes(data: data)
        guard b.u16(0) == 0x5A4D, let pe = b.u32(0x3C), b.u32(pe) == 0x4550,
              let sectionCount = b.u16(pe + 6), let optSize = b.u16(pe + 20), let magic = b.u16(pe + 24)
        else { return nil }
        let opt = pe + 24
        guard let rsrcRVA = b.u32(opt + (magic == 0x20B ? 112 : 96) + 16), rsrcRVA != 0 else { return nil }

        var sections: [(va: Int, size: Int, raw: Int)] = []
        for i in 0..<sectionCount {
            let s = opt + optSize + i * 40
            guard let vs = b.u32(s + 8), let va = b.u32(s + 12), let rs = b.u32(s + 16), let raw = b.u32(s + 20)
            else { return nil }
            sections.append((va, max(vs, rs), raw))
        }
        func fileOffset(_ rva: Int) -> Int? {
            sections.first { rva >= $0.va && rva < $0.va + $0.size }.map { rva - $0.va + $0.raw }
        }
        guard let root = fileOffset(rsrcRVA) else { return nil }

        typealias Entry = (id: Int, off: Int, isDir: Bool)
        func entries(_ dir: Int) -> [Entry] {
            guard let named = b.u16(dir + 12), let ids = b.u16(dir + 14), named + ids < 4096 else { return [] }
            return (0..<(named + ids)).compactMap { i in
                guard let name = b.u32(dir + 16 + i * 8), let target = b.u32(dir + 20 + i * 8) else { return nil }
                return (name & 0x8000_0000 != 0 ? -1 : name, root + (target & 0x7FFF_FFFF), target & 0x8000_0000 != 0)
            }
        }
        func leaf(_ entry: Entry) -> Data? {
            var current = entry
            for _ in 0..<4 where current.isDir {
                guard let next = entries(current.off).first else { return nil }
                current = next
            }
            guard !current.isDir, let rva = b.u32(current.off), let size = b.u32(current.off + 4),
                  let off = fileOffset(rva) else { return nil }
            return b.slice(off, size)
        }

        let types = entries(root)
        guard let groupType = types.first(where: { $0.id == 14 }),
              let iconType = types.first(where: { $0.id == 3 }),
              let group = entries(groupType.off).first, let groupData = leaf(group) else { return nil }
        var images: [Int: Data] = [:]
        for entry in entries(iconType.off) where entry.id >= 0 {
            images[entry.id] = leaf(entry)
        }
        let g = Bytes(data: groupData)
        guard let count = g.u16(4) else { return nil }
        var parts: [(header: Data, image: Data)] = []
        for i in 0..<count {
            let e = 6 + i * 14
            if let header = g.slice(e, 12), let id = g.u16(e + 12), let image = images[id] {
                parts.append((header, image))
            }
        }
        guard !parts.isEmpty else { return nil }

        func le(_ v: Int, _ n: Int) -> Data { Data((0..<n).map { UInt8((v >> ($0 * 8)) & 0xFF) }) }
        var ico = le(0, 2) + le(1, 2) + le(parts.count, 2)
        var offset = 6 + parts.count * 16
        for part in parts {
            ico += part.header.prefix(8) + le(part.image.count, 4) + le(offset, 4)
            offset += part.image.count
        }
        for part in parts { ico += part.image }
        return ico
    }

    static func iconData(for file: URL, bottle: Bottle) -> Data? {
        switch file.pathExtension.lowercased() {
        case "exe", "dll":
            return icon(exe: file)
        case "ico":
            return try? Data(contentsOf: file)
        case "lnk":
            let link = shortcut(file)
            if var location = link.icon, !location.contains("%") {
                if let comma = location.lastIndex(of: ","), location[location.index(after: comma)...].allSatisfy({ $0.isNumber || $0 == "-" }) {
                    location = String(location[..<comma])
                }
                if let url = bottle.unixURL(windowsPath: location), let data = iconData(for: url, bottle: bottle) {
                    return data
                }
            }
            if let target = link.target, let url = bottle.unixURL(windowsPath: target),
               url.pathExtension.lowercased() != "lnk" {
                return iconData(for: url, bottle: bottle)
            }
            return nil
        default:
            return nil
        }
    }
}

// MARK: - Registry files (read-only; writes go through `wine reg`)

enum RegistryFile {
    static func section(_ file: URL, _ name: String) -> [String: String] {
        guard let text = (try? String(contentsOf: file, encoding: .utf8))
                ?? (try? String(contentsOf: file, encoding: .isoLatin1)) else { return [:] }
        let header = "[" + name.replacingOccurrences(of: "\\", with: "\\\\") + "]"
        var inside = false
        var values: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("[") {
                if inside { break }
                inside = line.lowercased().hasPrefix(header.lowercased())
                continue
            }
            guard inside, line.hasPrefix("\""), let eq = line.range(of: "\"=") else { continue }
            let key = String(line[line.index(after: line.startIndex)..<eq.lowerBound])
            var value = String(line[eq.upperBound...])
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        return values
    }

    static func windowsVersion(_ bottle: Bottle) -> String {
        let values = section(bottle.prefix.appendingPathComponent("system.reg"),
                             "Software\\Microsoft\\Windows NT\\CurrentVersion")
        let build = Int(values["CurrentBuild"] ?? values["CurrentBuildNumber"] ?? "") ?? 0
        switch build {
        case 22000...: return "Windows 11"
        case 10240...: return "Windows 10"
        case 9600...: return "Windows 8.1"
        case 9200...: return "Windows 8"
        case 7600...: return "Windows 7"
        case 1...: return "Windows XP"
        default: return "Unknown"
        }
    }
}

// MARK: - Store

/// Output collected from a child process on a background queue.
final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    func append(_ d: Data) { lock.lock(); buffer.append(d); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
}

@MainActor
final class BottleStore: ObservableObject {
    static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Sikarugir")

    @Published var bottles: [Bottle] = []
    @Published var programs: [String: [WinProgram]] = [:]
    @Published var scanning: Set<String> = []
    @Published var activity: String?
    @Published var alertMessage: String?
    @Published var riskPrompt: RiskPrompt?

    struct RiskPrompt {
        let name: String
        let marker: String
        let proceed: () -> Void
    }

    init() {
        reload()
        // A bottle deleted or added in Finder while the app was in the background: one directory listing.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        let list = urls.filter { $0.pathExtension == "app" }
            .map(Bottle.init(url:))
            .filter { fm.isExecutableFile(atPath: $0.wine.path) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if list != bottles { bottles = list }  // no redraw on every app activation
    }

    // MARK: Programs

    func scanPrograms(_ bottle: Bottle) {
        scanning.insert(bottle.id)
        Task.detached(priority: .userInitiated) {
            let found = BottleStore.findPrograms(in: bottle)
            await MainActor.run {
                self.programs[bottle.id] = found
                self.scanning.remove(bottle.id)
            }
        }
    }

    nonisolated static func findPrograms(in bottle: Bottle) -> [WinProgram] {
        let fm = FileManager.default
        let menu = "Microsoft/Windows/Start Menu/Programs"
        var dirs = [bottle.driveC.appendingPathComponent("ProgramData/\(menu)")]
        let users = bottle.driveC.appendingPathComponent("users")
        for user in (try? fm.contentsOfDirectory(atPath: users.path)) ?? [] {
            dirs.append(users.appendingPathComponent("\(user)/AppData/Roaming/\(menu)"))
        }
        var result: [WinProgram] = []
        var seen = Set<String>()
        for dir in dirs {
            guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            else { continue }
            for case let url as URL in walker where url.pathExtension.lowercased() == "lnk" {
                let name = url.deletingPathExtension().lastPathComponent
                let lower = name.lowercased()
                guard !lower.contains("uninstall"), seen.insert(lower).inserted else { continue }
                var program = WinProgram(name: name, path: url.path)
                program.iconData = WinBinary.iconData(for: url, bottle: bottle)
                result.append(program)
            }
        }
        for var program in customPrograms(bottle) where seen.insert(program.name.lowercased()).inserted {
            program.custom = true
            program.iconData = WinBinary.iconData(for: URL(fileURLWithPath: program.path), bottle: bottle)
            result.append(program)
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    nonisolated static func customPrograms(_ bottle: Bottle) -> [WinProgram] {
        guard let data = try? Data(contentsOf: bottle.programsFile) else { return [] }
        return (try? JSONDecoder().decode([WinProgram].self, from: data)) ?? []
    }

    private func saveCustomPrograms(_ list: [WinProgram], in bottle: Bottle) {
        do {
            try JSONEncoder().encode(list).write(to: bottle.programsFile, options: .atomic)
        } catch {
            alertMessage = error.localizedDescription
        }
        scanPrograms(bottle)
    }

    func addProgram(_ file: URL, name: String? = nil, to bottle: Bottle) {
        var list = Self.customPrograms(bottle).filter { $0.path != file.path }
        list.append(WinProgram(name: name ?? file.deletingPathExtension().lastPathComponent, path: file.path))
        saveCustomPrograms(list, in: bottle)
    }

    func removeProgram(_ program: WinProgram, from bottle: Bottle) {
        saveCustomPrograms(Self.customPrograms(bottle).filter { $0.path != program.path }, in: bottle)
    }

    // MARK: Running things

    // ponytail: name-based match only, renamed tools slip through; add hash list if that matters.
    static let piracyMarkers = ["luatools", "steamtools", "greenluma", "creamapi", "smokeapi", "goldberg", "steam_emu", "steamless"]

    /// Runs `action` directly, or asks first when the file looks like a known piracy tool.
    func guarded(_ file: URL, in bottle: Bottle, _ action: @escaping () -> Void) {
        var subject = file.path.lowercased()
        switch file.pathExtension.lowercased() {
        case "lnk": subject += " " + (WinBinary.shortcut(file).target ?? "").lowercased()
        case "bat": subject += " " + ((try? String(contentsOf: file, encoding: .utf8)) ?? "").lowercased()
        default: break
        }
        if let hit = Self.piracyMarkers.first(where: subject.contains) {
            riskPrompt = RiskPrompt(name: file.deletingPathExtension().lastPathComponent, marker: hit, proceed: action)
        } else {
            action()
        }
    }

    /// Opens a Windows file (.exe, .lnk, .bat, .msi) through the wrapper so the
    /// bottle's graphics and sync settings apply.
    /// The piracy warning is shown once, at install time (see `install`), not on every launch.
    func open(_ file: URL, in bottle: Bottle) {
        if !bottle.isSteam && flag(bottle, "SteamyAutoGraphics") {
            var target = file
            if file.pathExtension.lowercased() == "lnk",
               let t = WinBinary.shortcut(file).target, let url = bottle.unixURL(windowsPath: t) { target = url }
            if target.pathExtension.lowercased() == "exe" {
                var values = GraphicsBackend.detect(for: target).plistValues
                values["SteamyAutoGraphics"] = 1
                setPlist(bottle, values)
            }
        }
        launcher(bottle, ["WSS-installer", file.path])
    }

    // MARK: Environment variables (exported through the wrapper's "CLI Custom Commands")

    func environment(_ bottle: Bottle) -> [String: String] {
        let raw = plistDictionary(bottle)["CLI Custom Commands"] as? String ?? ""
        var env: [String: String] = [:]
        for part in raw.split(separator: ";") {
            let item = part.trimmingCharacters(in: .whitespaces)
            guard item.hasPrefix("export "), let eq = item.firstIndex(of: "=") else { continue }
            env[String(item[item.index(item.startIndex, offsetBy: 7)..<eq])] = String(item[item.index(after: eq)...])
        }
        return env
    }

    func setEnvironment(_ bottle: Bottle, _ key: String, _ value: String?) {
        var env = environment(bottle)
        env[key] = value
        let line = env.keys.sorted().map { "export \($0)=\(env[$0]!)" }.joined(separator: "; ")
        setPlist(bottle, ["CLI Custom Commands": line])
    }

    func install(_ file: URL, in bottle: Bottle) {
        guarded(file, in: bottle) { [weak self] in
            self?.activity = "Installing \(file.lastPathComponent) into \(bottle.name)…"
            self?.launcher(bottle, ["WSS-installer", file.path]) { status, output in
                self?.activity = nil
                if status != 0 { self?.alertMessage = "\(file.lastPathComponent) did not finish installing:\n\(output.suffix(400))" }
                self?.scanPrograms(bottle)
            }
        }
    }

    /// Steam re-adds itself to Windows' auto-start list when it exits, and Wine replays that
    /// list whenever the bottle wakes up. Clear it before Steamy wakes the Steam bottle.
    private func clearSteamAutorun(_ bottle: Bottle) {
        guard bottle.isSteam, let script = Bundle.main.path(forResource: "setup", ofType: "sh") else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [script, "autorun-off"]
        task.environment = InstallerModel.taskEnvironment()
        try? task.run()
        task.waitUntilExit()
    }

    /// Closes Steam and every program running in any bottle (used when Steamy quits).
    nonisolated static func closeAllWindowsPrograms() {
        if let script = Bundle.main.path(forResource: "setup", ofType: "sh") {
            let stop = Process()
            stop.executableURL = URL(fileURLWithPath: "/bin/bash")
            stop.arguments = [script, "stop"]
            stop.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "USER": NSUserName()]
            try? stop.run()
            stop.waitUntilExit()
        }
        // TERM first so wineserver saves the registry; KILL only leftovers after ~5 s.
        pkill("-TERM")
        _ = waitUntil(timeout: 5, step: 0.25) { !windowsProgramsRunning }
        pkill("-KILL")
    }

    nonisolated static func pkill(_ signal: String) {
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = [signal, "-f", "Applications/Sikarugir/|Steamy Bottles/"]
        try? kill.run()
        kill.waitUntilExit()
    }

    /// Polls `done` every `step` seconds up to `timeout`; true if it became true.
    nonisolated static func waitUntil(timeout: Double, step: Double, _ done: () -> Bool) -> Bool {
        var waited = 0.0
        while !done() {
            if waited >= timeout { return false }
            Thread.sleep(forTimeInterval: step)
            waited += step
        }
        return true
    }

    /// True while any Wine process from a bottle is running.
    nonisolated static var windowsProgramsRunning: Bool {
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        check.arguments = ["-f", "Applications/Sikarugir/.*/(wine|wineserver)|Steamy Bottles/.*/(wine|wineserver)"]
        check.standardOutput = FileHandle.nullDevice
        try? check.run()
        check.waitUntilExit()
        return check.terminationStatus == 0
    }

    func launcher(_ bottle: Bottle, _ arguments: [String], completion: ((Int32, String) -> Void)? = nil) {
        guard FileManager.default.fileExists(atPath: bottle.url.path) else {
            reload()
            alertMessage = "\(bottle.name) is no longer in the Sikarugir folder. It may have been deleted or moved."
            completion?(-1, "")  // callers set `activity` and clear it in completion
            return
        }
        clearSteamAutorun(bottle)
        spawn(bottle.launcher, arguments, environment: InstallerModel.taskEnvironment(), completion: completion)
    }

    func wine(_ bottle: Bottle, _ arguments: [String], completion: ((Bool, String) -> Void)? = nil) {
        clearSteamAutorun(bottle)
        let c = bottle.contents.path
        var env = InstallerModel.taskEnvironment()
        env["WINEPREFIX"] = bottle.prefix.path
        env["WINEDEBUG"] = "-all"
        env["DYLD_FALLBACK_LIBRARY_PATH"] = [
            "\(c)/Frameworks/moltenvkcx", "\(c)/SharedSupport/wine/lib", "\(c)/SharedSupport/wine/lib64",
            "\(c)/Frameworks", "\(c)/Frameworks/GStreamer.framework/Libraries", "/usr/lib", "/usr/libexec", "/usr/lib/system"
        ].joined(separator: ":")
        // Match the running wineserver's sync mode, or clients fail to connect.
        env["WINEMSYNC"] = flag(bottle, "WINEMSYNC") ? "1" : "0"
        env["WINEESYNC"] = flag(bottle, "WINEESYNC") ? "1" : "0"
        spawn(bottle.wine, arguments, environment: env) { [weak self] status, output in
            if status != 0 { self?.alertMessage = "wine \(arguments.prefix(2).joined(separator: " ")) failed:\n\(output.suffix(400))" }
            completion?(status == 0, output)
        }
    }

    func setRegistry(_ bottle: Bottle, key: String, name: String, value: String?, completion: (() -> Void)? = nil) {
        let args = value.map { ["reg", "add", key, "/v", name, "/t", "REG_SZ", "/d", $0, "/f"] }
            ?? ["reg", "delete", key, "/v", name, "/f"]
        wine(bottle, args) { _, _ in completion?() }
    }

    func setDWORD(_ bottle: Bottle, key: String, name: String, value: Int) {
        wine(bottle, ["reg", "add", key, "/v", name, "/t", "REG_DWORD", "/d", String(value), "/f"]) { [weak self] ok, _ in
            if ok { self?.activity = nil }
        }
    }

    /// Imports registry values in one wine process. Values are already REGEDIT4-formatted
    /// (`"text"` or `dword:00000001`).
    func importRegistry(_ bottle: Bottle, _ sections: [String: [String: String]], completion: (() -> Void)? = nil) {
        var text = "REGEDIT4\r\n"
        for (key, values) in sections {
            text += "\r\n[\(key)]\r\n"
            for (name, value) in values { text += "\"\(name)\"=\(value)\r\n" }
        }
        let file = bottle.scriptsDir.appendingPathComponent("steamy-\(UUID().uuidString).reg")
        do {
            try FileManager.default.createDirectory(at: bottle.scriptsDir, withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            alertMessage = error.localizedDescription
            return
        }
        wine(bottle, ["regedit", "/S", bottle.windowsPath(file)]) { _, _ in
            try? FileManager.default.removeItem(at: file)
            completion?()
        }
    }

    static let macDriverKey = "HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver"

    /// One-click gaming profile. Every key here was checked against this engine's
    /// winemac driver and the Sikarugir launcher. Takes effect on the bottle's next start.
    func optimizeForGaming(_ bottle: Bottle, completion: (() -> Void)? = nil) {
        var values: [String: Any] = [
            "WINEMSYNC": 1,                     // Apple-native sync primitives, lowest CPU overhead
            "WINEESYNC": 1,                     // fallback if MSync is unavailable
            "WINEDEBUG": "-all",                // no Wine logging on the hot path
            "Debug Mode": 0,
            "SteamyOptimized": Self.optimizeVersion,
            "Try To Use GPU Info": 1,           // report the real GPU/VRAM so games pick sane presets
            "LSApplicationCategoryType": "public.app-category.games", // lets macOS Game Mode engage
            "NSAppSleepDisabled": true          // no App Nap throttling when the game loses focus
        ]
        if !bottle.isSteam {
            values.merge(GraphicsBackend.auto.plistValues) { _, new in new }  // per-program DirectX detection
        }
        setPlist(bottle, values)
        // DLSS -> MetalFX (upscaling, and frame generation on macOS 26). Only games that call
        // DLSS use it; the rest are unaffected.
        setEnvironment(bottle, "D3DM_ENABLE_METALFX", "1")
        // Cap games at 60 FPS: no need to burn a fanless Mac. DXVK and DXMT support a cap;
        // D3DMetal has none (the opt-in "Limit display to 60 Hz" setting covers it).
        setEnvironment(bottle, "DXVK_FRAME_RATE", "60")
        // This DXVK build (dxvk-macOS-async) compiles shaders in the background: fewer stutters.
        setEnvironment(bottle, "DXVK_ASYNC", "1")
        writeDXMTConfig(bottle, boost: boost(bottle))
        importRegistry(bottle, [
            Self.macDriverKey: [
                "RetinaMode": "\"n\"",                     // render at point resolution: biggest FPS win on Retina Macs
                "CaptureDisplaysForFullscreen": "\"y\""    // fullscreen games bypass the window compositor
            ],
            "HKEY_CURRENT_USER\\Software\\Wine\\WineDbg": ["ShowCrashDialog": "dword:00000000"],
            // Windows tray icons become unclickable menu bar icons on macOS; hide them.
            "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer":
                ["NoTrayItemsDisplay": "dword:00000001"],
            "HKEY_CURRENT_USER\\Control Panel\\Desktop": [
                "FontSmoothing": "\"2\"",
                "FontSmoothingType": "dword:00000002",
                "FontSmoothingOrientation": "dword:00000001"
            ]
        ], completion: completion)
    }

    func optimizeAll() {
        let targets = bottles
        guard !targets.isEmpty else { alertMessage = "No bottles to optimize yet."; return }
        activity = "Optimizing \(targets.count) bottle\(targets.count == 1 ? "" : "s")…"
        var remaining = targets.count
        for bottle in targets {
            optimizeForGaming(bottle) { [weak self] in
                remaining -= 1
                if remaining == 0 { self?.activity = nil }
            }
        }
    }

    // MARK: One-click launchers (official installers, each in its own optimized bottle)

    struct Launcher: Identifiable {
        let name: String
        let detail: String
        let icon: String
        let url: URL
        let fileName: String
        let logo: String
        let brand: Color
        var id: String { name }
    }

    static let launchers: [Launcher] = [
        Launcher(name: "Epic Games", detail: "Epic Games Store and free weekly games", icon: "e.square.fill",
                 url: URL(string: "https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncherInstaller.msi")!,
                 fileName: "EpicGamesLauncherInstaller.msi", logo: "epicgames", brand: Color(hex: 0x2F2D2E)),
        Launcher(name: "GOG Galaxy", detail: "DRM-free games from GOG", icon: "g.square.fill",
                 url: URL(string: "https://webinstallers.gog-statics.com/download/GOG_Galaxy_2.0.exe")!,
                 fileName: "GOG_Galaxy_2.0.exe", logo: "gogdotcom", brand: Color(hex: 0x86328A)),
        Launcher(name: "Battle.net", detail: "Blizzard games", icon: "b.square.fill",
                 url: URL(string: "https://www.battle.net/download/getInstallerForGame?os=win&gameProgram=BATTLENET_APP&version=Live")!,
                 fileName: "Battle.net-Setup.exe", logo: "battledotnet", brand: Color(hex: 0x148EFF)),
        Launcher(name: "EA app", detail: "EA and Origin games", icon: "a.square.fill",
                 url: URL(string: "https://origin-a.akamaihd.net/EA-Desktop-Client-Download/installer-releases/EAappInstaller.exe")!,
                 fileName: "EAappInstaller.exe", logo: "ea", brand: Color(hex: 0xFF4747)),
        Launcher(name: "Ubisoft Connect", detail: "Ubisoft games", icon: "u.square.fill",
                 url: URL(string: "https://static3.cdn.ubi.com/orbit/launcher_installer/UbisoftConnectInstaller.exe")!,
                 fileName: "UbisoftConnectInstaller.exe", logo: "ubisoft", brand: Color(hex: 0x0070FF))
    ]

    func installLauncher(_ launcher: Launcher) {
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/MacSteamSetup/installers")
        let dest = cache.appendingPathComponent(launcher.fileName)
        activity = "Downloading \(launcher.name)…"
        URLSession.shared.downloadTask(with: launcher.url) { [weak self] tmp, response, error in
            var failure = error?.localizedDescription
            if failure == nil, let tmp, (response as? HTTPURLResponse)?.statusCode == 200 {
                do {
                    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tmp, to: dest)
                } catch { failure = error.localizedDescription }
            } else if failure == nil {
                failure = "Download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))."
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if let failure { self.activity = nil; self.alertMessage = "\(launcher.name): \(failure)"; return }
                // Launchers need CrossOver's fixes (e.g. Battle.net's folder permissions), which
                // only the Wine 11 engine has, so they use it when it's installed.
                let run: (Bottle) -> Void = { bottle in
                    let engine = self.engines.first { $0.url != nil } ?? Self.bundledEngine
                    self.setEngine(engine, for: bottle) {
                        self.optimizeForGaming(bottle) {
                            // Launchers are web-style apps: DXVK draws them cleanly; D3DMetal glitched
                            // and kept the CPU busy (seen with Battle.net).
                            self.setPlist(bottle, GraphicsBackend.dxvk.plistValues)
                            self.install(dest, in: bottle)
                        }
                    }
                }
                if let bottle = self.bottles.first(where: { $0.name == launcher.name }) {
                    run(bottle)
                } else {
                    self.createBottle(named: launcher.name) { if let bottle = $0 { run(bottle) } }
                }
            }
        }.resume()
    }

    // MARK: Wine engines
    //
    // Each bottle runs the Wine in its Contents/SharedSupport/wine. The engine it was created
    // with (Sikarugir Wine 10) stays there; other engines live once in `enginesRoot` and the
    // bottle's wine folder becomes a symlink to them. The original is kept as `wine.sikarugir`
    // so switching back is instant.

    struct Engine: Identifiable, Hashable {
        let id: String
        let title: String
        let url: URL?   // nil: the bottle's own bundled engine
    }

    static let enginesRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Steamy/Engines")
    static let bundledEngine = Engine(id: "bundled", title: "Wine 10 (stable)", url: nil)

    var engines: [Engine] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: Self.enginesRoot, includingPropertiesForKeys: nil)) ?? []
        return [Self.bundledEngine] + dirs
            .filter { fm.isExecutableFile(atPath: $0.appendingPathComponent("wine/bin/wine").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { dir in
                let title = (try? String(contentsOf: dir.appendingPathComponent("title"), encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return Engine(id: dir.lastPathComponent, title: title ?? dir.lastPathComponent,
                              url: dir.appendingPathComponent("wine"))
            }
    }

    private func wineDir(_ bottle: Bottle) -> URL { bottle.contents.appendingPathComponent("SharedSupport/wine") }

    func engine(of bottle: Bottle) -> Engine {
        let link = try? FileManager.default.destinationOfSymbolicLink(atPath: wineDir(bottle).path)
        if let link, let match = engines.first(where: { $0.url?.path == URL(fileURLWithPath: link).standardizedFileURL.path }) {
            return match
        }
        return Self.bundledEngine
    }

    /// The bottle's original engine is still around (needed to switch back to it).
    func canUseBundledEngine(_ bottle: Bottle) -> Bool {
        let fm = FileManager.default
        let wine = wineDir(bottle)
        let isLink = (try? fm.destinationOfSymbolicLink(atPath: wine.path)) != nil
        return !isLink || fm.fileExists(atPath: wine.deletingLastPathComponent().appendingPathComponent("wine.sikarugir").path)
    }

    func setEngine(_ engine: Engine, for bottle: Bottle, completion: (() -> Void)? = nil) {
        guard engine != self.engine(of: bottle) else { completion?(); return }
        activity = "Switching \(bottle.name) to \(engine.title)…"
        launcher(bottle, ["WSS-wineserverkill"]) { [weak self] _, _ in
            guard let self else { return }
            let fm = FileManager.default
            let wine = self.wineDir(bottle)
            let backup = wine.deletingLastPathComponent().appendingPathComponent("wine.sikarugir")
            let isLink = (try? fm.destinationOfSymbolicLink(atPath: wine.path)) != nil
            do {
                if isLink {
                    try fm.removeItem(at: wine)
                } else if fm.fileExists(atPath: wine.path) {
                    if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
                    try fm.moveItem(at: wine, to: backup)
                }
                if let url = engine.url {
                    try fm.createSymbolicLink(at: wine, withDestinationURL: url)
                } else {
                    try fm.moveItem(at: backup, to: wine)
                }
            } catch {
                self.alertMessage = "Could not switch engine: \(error.localizedDescription)"
            }
            self.activity = nil
            self.objectWillChange.send()
            completion?()
        }
    }

    // MARK: Native Mac apps

    static let macAppsFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Steamy Apps")

    /// Creates a small .app in ~/Applications/Steamy Apps so the Windows program shows up
    /// in Launchpad, Spotlight and the Dock like any Mac app.
    @discardableResult
    func createMacApp(_ program: WinProgram, in bottle: Bottle) -> URL? {
        let safeName = program.name.replacingOccurrences(of: #"[/:\x00-\x1F]"#, with: "-", options: .regularExpression)
        let app = Self.macAppsFolder.appendingPathComponent(safeName + ".app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = "#!/bin/bash\nexec \(quoted(bottle.launcher.path)) WSS-installer \(quoted(program.path)) >/dev/null 2>&1\n"
        let info: [String: Any] = [
            "CFBundleExecutable": "launch",
            "CFBundleIdentifier": "local.steamy.app.\(abs(program.path.hashValue))",
            "CFBundleName": program.name,
            "CFBundlePackageType": "APPL",
            "LSUIElement": true,
            "LSApplicationCategoryType": "public.app-category.games"
        ]
        do {
            if FileManager.default.fileExists(atPath: app.path) { try FileManager.default.removeItem(at: app) }
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            let launch = macOS.appendingPathComponent("launch")
            try script.write(to: launch, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launch.path)
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
        } catch {
            alertMessage = error.localizedDescription
            return nil
        }
        if let data = program.iconData, let image = NSImage(data: data) {
            NSWorkspace.shared.setIcon(image, forFile: app.path, options: [])
        }
        return app
    }

    /// Clears Steam's web cache, which fixes a blank or broken login window.
    func repairSteamLogin(_ bottle: Bottle) {
        launcher(bottle, ["WSS-wineserverkill"]) { [weak self] _, _ in
            let users = bottle.driveC.appendingPathComponent("users")
            for user in (try? FileManager.default.contentsOfDirectory(atPath: users.path)) ?? [] {
                try? FileManager.default.removeItem(at: users.appendingPathComponent("\(user)/AppData/Local/Steam/htmlcache"))
            }
            self?.launcher(bottle, [])
        }
    }

    func createMacApps(for bottle: Bottle) {
        let list = programs[bottle.id] ?? []
        let made = list.compactMap { createMacApp($0, in: bottle) }
        if !made.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(made) }
    }

    func runScript(_ script: String, in bottle: Bottle, saveAs rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        let fileName = name.isEmpty ? "last-run" : name.replacingOccurrences(of: #"[^A-Za-z0-9 _.-]"#, with: "-", options: .regularExpression)
        let file = bottle.scriptsDir.appendingPathComponent(fileName + ".bat")
        let body = "@echo off\r\n" + script.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n") + "\r\n"
        do {
            try FileManager.default.createDirectory(at: bottle.scriptsDir, withIntermediateDirectories: true)
            try body.data(using: .utf8)!.write(to: file, options: .atomic)
        } catch {
            alertMessage = error.localizedDescription
            return
        }
        if !name.isEmpty { addProgram(file, name: name, to: bottle) }
        open(file, in: bottle)
    }

    private func spawn(_ executable: URL, _ arguments: [String], environment: [String: String],
                       completion: ((Int32, String) -> Void)?) {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = executable
        task.arguments = arguments
        task.environment = environment
        task.currentDirectoryURL = executable.deletingLastPathComponent()
        task.standardOutput = pipe
        task.standardError = pipe
        // Drain while running: a full 64 KB pipe would block the child forever.
        let collected = LockedData()
        let order = NSLock()  // a handler in flight finishes before the final drain, so output stays in order
        pipe.fileHandleForReading.readabilityHandler = { handle in
            order.lock(); defer { order.unlock() }
            let data = handle.availableData
            if !data.isEmpty { collected.append(data) }
        }
        task.terminationHandler = { finished in
            order.lock()
            pipe.fileHandleForReading.readabilityHandler = nil
            collected.append(pipe.fileHandleForReading.readDataToEndOfFile())
            order.unlock()
            let output = String(decoding: collected.data, as: UTF8.self)
            DispatchQueue.main.async { completion?(finished.terminationStatus, output) }
        }
        do {
            try task.run()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    // MARK: Settings (wrapper Info.plist)

    func plistDictionary(_ bottle: Bottle) -> [String: Any] {
        (NSDictionary(contentsOf: bottle.plist) as? [String: Any]) ?? [:]
    }

    func flag(_ bottle: Bottle, _ key: String) -> Bool {
        (plistDictionary(bottle)[key] as? NSNumber)?.intValue == 1
    }

    func setPlist(_ bottle: Bottle, _ values: [String: Any]) {
        var dict = plistDictionary(bottle)
        guard !dict.isEmpty else { alertMessage = "Bottle settings file is missing."; return }
        dict.merge(values) { _, new in new }
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try data.write(to: bottle.plist, options: .atomic)
        } catch {
            alertMessage = error.localizedDescription
        }
        objectWillChange.send()
    }

    /// FPS overlay. Metal games (D3DMetal/DXMT) get Apple's Metal Performance HUD via the
    /// wrapper's METAL_HUD flag; DXVK games get DXVK's own counter.
    func fpsCounter(_ bottle: Bottle) -> Bool { flag(bottle, "METAL_HUD") }

    func setFPSCounter(_ bottle: Bottle, _ on: Bool) {
        setPlist(bottle, ["METAL_HUD": on ? 1 : 0])
        // Only the frame rate: Apple's HUD otherwise shows a dozen developer metrics.
        // https://developer.apple.com/documentation/xcode/customizing-metal-performance-hud
        let hud: [String: String] = ["MTL_HUD_ELEMENTS": "fps", "MTL_HUD_SCALE": "0.12",
                                     "MTL_HUD_OPACITY": "0.85", "MTL_HUD_DISABLE_MENU_BAR": "1", "DXVK_HUD": "fps"]
        for (key, value) in hud { setEnvironment(bottle, key, on ? value : nil) }
    }

    // MARK: Steamy Boost
    //
    // DirectX 11 games render at a lower resolution (1600x900) and DXMT upscales the output to
    // the screen with Apple's MetalFX, plus Metal-paced frames at a steady 60 FPS. Uses DXMT's
    // own options: https://github.com/3Shain/dxmt/blob/main/docs/CUSTOMIZATION.md

    static let boostRenderWidth = 1600.0

    func boost(_ bottle: Bottle) -> Bool { flag(bottle, "SteamyBoost") }

    /// MetalFX factor that turns a 1600-wide image into the main display's width (1.0-2.0).
    static var boostFactor: Double {
        min(2.0, max(1.0, Double(CGDisplayPixelsWide(CGMainDisplayID())) / boostRenderWidth))
    }

    /// Writes C:/steamy/dxmt.conf: a steady 60 FPS cap always (cooler Mac), plus the MetalFX
    /// upscale factor when Steamy Boost is on.
    @discardableResult
    func writeDXMTConfig(_ bottle: Bottle, boost: Bool) -> Bool {
        let confDir = bottle.driveC.appendingPathComponent("steamy")
        var conf = "# Written by Steamy\nd3d11.preferredMaxFrameRate = 60\n"
        if boost { conf += "d3d11.metalSpatialUpscaleFactor = \(String(format: "%.2f", Self.boostFactor))\n" }
        do {
            try FileManager.default.createDirectory(at: confDir, withIntermediateDirectories: true)
            try conf.write(to: confDir.appendingPathComponent("dxmt.conf"), atomically: true, encoding: .utf8)
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
        setEnvironment(bottle, "DXMT_CONFIG_FILE", "C:/steamy/dxmt.conf")
        return true
    }

    func setBoost(_ bottle: Bottle, _ on: Bool) {
        guard writeDXMTConfig(bottle, boost: on) else { return }
        if on {
            var values = GraphicsBackend.dxmt.plistValues
            values["SteamyBoost"] = 1
            setPlist(bottle, values)
            setEnvironment(bottle, "DXMT_METALFX_SPATIAL_SWAPCHAIN", "1")
        } else {
            var values = (bottle.isSteam ? GraphicsBackend.d3dmetal : GraphicsBackend.auto).plistValues
            values["SteamyBoost"] = 0
            setPlist(bottle, values)
            setEnvironment(bottle, "DXMT_METALFX_SPATIAL_SWAPCHAIN", nil)
        }
    }

    // MARK: Optimized state

    /// Bump when `optimizeForGaming` gains settings, so bottles get offered the new ones.
    static let optimizeVersion = 4

    func isOptimized(_ bottle: Bottle) -> Bool {
        ((plistDictionary(bottle)["SteamyOptimized"] as? NSNumber)?.intValue ?? 0) >= Self.optimizeVersion
    }

    func graphics(_ bottle: Bottle) -> GraphicsBackend {
        if flag(bottle, "SteamyAutoGraphics") { return .auto }
        if flag(bottle, "D3DMETAL") { return .d3dmetal }
        if flag(bottle, "DXMT") { return .dxmt }
        if flag(bottle, "DXVK") { return .dxvk }
        return .wined3d
    }

    // MARK: Bottle lifecycle

    func createBottle(named name: String, completion: @escaping (Bottle?) -> Void) {
        guard let script = Bundle.main.path(forResource: "setup", ofType: "sh") else {
            alertMessage = L10n.string("error.internalScriptMissing")
            return completion(nil)
        }
        activity = "Creating bottle \(name)…"
        var env = InstallerModel.taskEnvironment()
        if let dir = Self.bottleStorageDir { env["STEAMY_BOTTLE_DIR"] = dir.path }
        spawn(URL(fileURLWithPath: "/bin/bash"), [script, "create-bottle", name],
              environment: env) { [weak self] status, output in
            guard let self else { return }
            self.activity = nil
            self.reload()
            if status == 0 {
                completion(self.bottles.first { $0.name == name })
            } else {
                let error = output.split(separator: "\n").last { $0.hasPrefix("@@ERROR|") }
                self.alertMessage = error.map { String($0.dropFirst(8)) } ?? "Could not create the bottle.\n\(output.suffix(400))"
                completion(nil)
            }
        }
    }

    func rename(_ bottle: Bottle, to name: String) {
        guard !bottle.isSteam, isValidBottleName(name) else { alertMessage = "Invalid bottle name."; return }
        let target = Self.root.appendingPathComponent(name + ".app")
        launcher(bottle, ["WSS-wineserverkill"]) { [weak self] _, _ in
            do {
                if let real = Self.storedURL(of: bottle) {
                    let renamed = real.deletingLastPathComponent().appendingPathComponent(name + ".app")
                    // New link first: if it fails, move the bottle back; the old link goes last.
                    try FileManager.default.moveItem(at: real, to: renamed)
                    do {
                        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: renamed)
                    } catch {
                        try? FileManager.default.moveItem(at: renamed, to: real)
                        throw error
                    }
                    try? FileManager.default.removeItem(at: bottle.url)
                } else {
                    try FileManager.default.moveItem(at: bottle.url, to: target)
                }
                self?.setPlist(Bottle(url: target), ["CFBundleName": name])
            } catch {
                self?.alertMessage = error.localizedDescription
            }
            self?.reload()
        }
    }

    func duplicate(_ bottle: Bottle) {
        var name = "\(bottle.name) copy"
        var n = 2
        while FileManager.default.fileExists(atPath: Self.root.appendingPathComponent(name + ".app").path) {
            name = "\(bottle.name) copy \(n)"; n += 1
        }
        let target = Self.root.appendingPathComponent(name + ".app")
        let real = Self.storedURL(of: bottle)
        activity = "Duplicating \(bottle.name)…"
        Task.detached {
            let failure: String?
            do {
                if let real {  // copy the stored bottle next to itself and link the copy
                    let copy = real.deletingLastPathComponent().appendingPathComponent(name + ".app")
                    try FileManager.default.copyItem(at: real, to: copy)
                    try FileManager.default.createSymbolicLink(at: target, withDestinationURL: copy)
                } else {
                    try FileManager.default.copyItem(at: bottle.url, to: target)
                }
                failure = nil
            } catch { failure = error.localizedDescription }
            await MainActor.run {
                self.activity = nil
                if let failure { self.alertMessage = failure; return }
                let copy = Bottle(url: target)
                self.setPlist(copy, ["CFBundleName": name, "CFBundleIdentifier": "local.macsteam.bottle.\(UUID().uuidString)"])
                try? FileManager.default.removeItem(at: copy.contents.appendingPathComponent(".macsteamsetup-owner"))
                self.reload()
            }
        }
    }

    func trash(_ bottle: Bottle, completion: @escaping () -> Void) {
        guard !bottle.isSteam else { return }
        launcher(bottle, ["WSS-wineserverkill"]) { [weak self] _, _ in
            NSWorkspace.shared.recycle([bottle.url] + [Self.storedURL(of: bottle)].compactMap { $0 }) { _, error in
                DispatchQueue.main.async {
                    if let error { self?.alertMessage = error.localizedDescription }
                    self?.reload()
                    completion()
                }
            }
        }
    }

    // MARK: Storage location (This Mac or an external drive)

    /// External, writable drives a bottle can live on (e.g. a USB SSD).
    static var externalVolumes: [URL] {
        let keys: [URLResourceKey] = [.volumeIsInternalKey, .volumeIsRootFileSystemKey, .volumeIsReadOnlyKey]
        return (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [])
            .filter { url in
                let v = try? url.resourceValues(forKeys: Set(keys))
                return url.path.hasPrefix("/Volumes/") && v?.volumeIsInternal == false
                    && v?.volumeIsRootFileSystem == false && v?.volumeIsReadOnly == false
            }
    }

    /// Folder new bottles are stored in, or nil for This Mac. Setting "bottleStorage": a volume
    /// path, or "local". Unset defaults to the first external drive, so installs go to the SSD.
    static var bottleStorageDir: URL? {
        let choice = UserDefaults.standard.string(forKey: "bottleStorage")
        if choice == "local" { return nil }
        let volume = externalVolumes.first { $0.path == choice } ?? (choice == nil ? externalVolumes.first : nil)
        return volume?.appendingPathComponent("Steamy Bottles")
    }

    /// Where a linked bottle really lives (nil when it is stored in ~/Applications/Sikarugir).
    nonisolated static func storedURL(of bottle: Bottle) -> URL? {
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: bottle.url.path) else { return nil }
        return URL(fileURLWithPath: dest, relativeTo: bottle.url.deletingLastPathComponent()).standardizedFileURL
    }

    /// Moves a bottle to `dir` (nil = back to This Mac), keeping it linked in ~/Applications/Sikarugir.
    func move(_ bottle: Bottle, to dir: URL?) {
        let current = Self.storedURL(of: bottle) ?? bottle.url
        let destination = (dir ?? Self.root).appendingPathComponent(bottle.name + ".app")
        guard current.standardizedFileURL != destination.standardizedFileURL else { return }
        activity = "Moving \(bottle.name) to \(dir == nil ? "This Mac" : dir!.deletingLastPathComponent().lastPathComponent)…"
        launcher(bottle, ["WSS-wineserverkill"]) { [weak self] _, _ in
            Task.detached {
                let fm = FileManager.default
                var failure: String?
                do {
                    if let dir { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
                    // Moving back to This Mac lands exactly where the link is; the link is removed below.
                    if destination.path != bottle.url.path, fm.fileExists(atPath: destination.path) {
                        throw CocoaError(.fileWriteFileExists)
                    }
                    if Self.storedURL(of: bottle) != nil { try fm.removeItem(at: bottle.url) }  // drop the old link
                    try fm.moveItem(at: current, to: destination)  // copies across drives
                    if dir != nil { try fm.createSymbolicLink(at: bottle.url, withDestinationURL: destination) }
                } catch {
                    failure = error.localizedDescription
                    if !fm.fileExists(atPath: bottle.url.path), fm.fileExists(atPath: current.path) {
                        try? fm.createSymbolicLink(at: bottle.url, withDestinationURL: current)  // restore
                    }
                }
                let message = failure
                await MainActor.run {
                    self?.activity = nil
                    if let message { self?.alertMessage = "Could not move \(bottle.name): \(message)" }
                    self?.reload()
                }
            }
        }
    }

    // MARK: Helpers

    func pickFile(in bottle: Bottle?, title: String = "Choose a Windows program or installer") -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = bottle?.driveC
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        return panel.runModal() == .OK ? panel.url : nil
    }
}

// MARK: - Bottle screen

struct BottleView: View {
    @ObservedObject var store: BottleStore
    let bottle: Bottle
    let onDeleted: () -> Void

    @State private var windowsVersion = "…"
    @State private var openingID: String?
    @State private var pendingLaunch: WinProgram?

    /// Opens a program with visible feedback: Wine apps can take several seconds to appear.
    private func launch(_ program: WinProgram, checkOptimized: Bool = true) {
        if checkOptimized && !store.isOptimized(bottle) {
            pendingLaunch = program
            return
        }
        store.open(URL(fileURLWithPath: program.path), in: bottle)
        withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { openingID = program.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if openingID == program.id { withAnimation(.easeOut(duration: 0.3)) { openingID = nil } }
        }
    }

    private var programs: [WinProgram] { store.programs[bottle.id] ?? [] }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Text(bottle.name).font(.app(.largeTitle).bold())
                    Spacer()
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                        GridRow {
                            Text("Bottle Type:").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            Text(windowsVersion)
                        }
                        GridRow {
                            Text("Status:").foregroundStyle(.secondary)
                            Text(store.scanning.contains(bottle.id) ? "Scanning…" : "Ready")
                        }
                    }
                    .font(.app(.caption))
                }
                .padding(.bottom, 14)
                Divider()

                if programs.isEmpty && !store.scanning.contains(bottle.id) {
                    ContentUnavailableView {
                        Label("No Applications", systemImage: "square.dashed")
                    } description: {
                        Text("Install software or add an existing .exe to this bottle.")
                    } actions: {
                        Button("Install Software…") { if let f = store.pickFile(in: nil) { store.install(f, in: bottle) } }
                            .buttonStyle(.borderedProminent)
                        Button("Add Application…") { if let f = store.pickFile(in: bottle) { store.addProgram(f, to: bottle) } }
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 150), spacing: 16)], spacing: 22) {
                            ForEach(programs) { program in
                                ProgramTile(program: program, opening: openingID == program.id)
                                    .onTapGesture(count: 2) { launch(program) }
                                    .contextMenu {
                                        Button("Open") { launch(program) }
                                        Button("Add to Launchpad (Mac App)") {
                                            if let app = store.createMacApp(program, in: bottle) {
                                                NSWorkspace.shared.activateFileViewerSelecting([app])
                                            }
                                        }
                                        Button("Show in Finder") {
                                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: program.path)])
                                        }
                                        if program.custom {
                                            Divider()
                                            Button("Remove from Bottle List") { store.removeProgram(program, from: bottle) }
                                        }
                                    }
                            }
                        }
                        .padding(.vertical, 18)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .frame(maxWidth: .infinity)

            Divider()
            BottleSidePanel(store: store, bottle: bottle, onDeleted: onDeleted)
                .frame(width: 290)
        }
        .alert("Optimize before launching?", isPresented: Binding(
            get: { pendingLaunch != nil }, set: { if !$0 { pendingLaunch = nil } }
        )) {
            Button("Optimize & Launch") {
                if let program = pendingLaunch {
                    store.optimizeForGaming(bottle) { launch(program, checkOptimized: false) }
                }
            }
            Button("Launch Anyway") { if let program = pendingLaunch { launch(program, checkOptimized: false) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(bottle.name) isn't optimized yet. Optimizing gives better performance and takes a second.")
        }
        .onAppear {
            store.scanPrograms(bottle)
            let b = bottle
            Task.detached {
                let version = RegistryFile.windowsVersion(b)
                await MainActor.run { windowsVersion = version }
            }
        }
    }
}

struct ProgramTile: View {
    let program: WinProgram
    var opening = false
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let data = program.iconData, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                } else {
                    Image(systemName: program.path.lowercased().hasSuffix(".bat") ? "terminal.fill" : "app.dashed")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .frame(width: 60, height: 60)
            .scaleEffect(opening ? (pulse ? 1.08 : 0.94) : 1)
            .shadow(color: opening ? Color.steamyAccent.opacity(0.6) : .clear, radius: opening ? 12 : 0)
            .overlay(alignment: .bottomTrailing) {
                if opening {
                    ProgressView().controlSize(.small).offset(x: 6, y: 6).transition(.scale)
                }
            }
            .onChange(of: opening) { _, isOpening in
                if isOpening {
                    withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { pulse = true }
                } else {
                    pulse = false
                }
            }
            Text(opening ? "Opening…" : program.name)
                .font(.app(.callout))
                .foregroundStyle(opening ? Color.steamyAccent : Color.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(width: 130)
        .contentShape(Rectangle())
        .help(program.path)
    }
}

// MARK: - Right-hand panel

struct BottleSidePanel: View {
    @ObservedObject var store: BottleStore
    let bottle: Bottle
    let onDeleted: () -> Void

    @State private var showRunCommand = false
    @State private var showWinetricks = false
    @State private var showDLLs = false
    @State private var showRename = false
    @State private var confirmDelete = false
    @State private var macDriver: [String: String] = [:]
    @State private var size = "Calculating…"
    @AppStorage("showAdvancedOptions") private var advanced = false
    @State private var pendingEngine: BottleStore.Engine?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !advanced {
                    simpleOptions
                } else {
                Button { advanced = false } label: {
                    Label("Back to Simple Options", systemImage: "chevron.left")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.steamyAccent)
                .padding(.bottom, 10)
                Button { showRunCommand = true } label: {
                    Label("Run Command", systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)

                PanelSection("Install") {
                    PanelButton("Install Software into Bottle…", icon: "arrow.down.app") {
                        if let f = store.pickFile(in: nil) { store.install(f, in: bottle) }
                    }
                    PanelButton("Add Existing Application…", icon: "plus.app") {
                        if let f = store.pickFile(in: bottle) { store.addProgram(f, to: bottle) }
                    }
                    PanelButton("Winetricks…", icon: "wand.and.stars") { showWinetricks = true }
                    PanelButton("Add All Apps to Launchpad", icon: "square.grid.3x3") { store.createMacApps(for: bottle) }
                }

                PanelSection("Bottle Actions", expanded: false) {
                    PanelButton("Open C: Drive", icon: "internaldrive") { NSWorkspace.shared.open(bottle.driveC) }
                    PanelButton("Command Prompt", icon: "terminal") { store.launcher(bottle, ["WSS-cmd"]) }
                    PanelButton("Wine Explorer", icon: "folder") { store.launcher(bottle, ["WSS-explorer"]) }
                    PanelButton("Registry Editor", icon: "list.bullet.indent") { store.launcher(bottle, ["WSS-regedit"]) }
                    PanelButton("Task Manager", icon: "chart.bar.doc.horizontal") { store.launcher(bottle, ["WSS-taskmgr"]) }
                    PanelButton("Uninstall Programs", icon: "trash.square") { store.launcher(bottle, ["WSS-uninstaller"]) }
                    PanelButton("Simulate Reboot", icon: "arrow.clockwise") { store.launcher(bottle, ["WSS-wineboot"]) }
                    PanelButton("Force Quit Bottle", icon: "xmark.octagon") { store.launcher(bottle, ["WSS-wineserverkill"]) }
                    PanelButton("Refresh Applications", icon: "arrow.triangle.2.circlepath") { store.scanPrograms(bottle) }
                    if bottle.isSteam {
                        PanelButton("Repair Steam Login Screen", icon: "wrench.and.screwdriver") { store.repairSteamLogin(bottle) }
                    }
                    PanelButton("Duplicate Bottle", icon: "plus.square.on.square") { store.duplicate(bottle) }
                    if !bottle.isSteam {
                        PanelButton("Rename Bottle…", icon: "pencil") { showRename = true }
                        PanelButton("Delete Bottle…", icon: "trash", role: .destructive) { confirmDelete = true }
                    }
                }

                PanelSection("Advanced Settings") {
                    Button {
                        store.optimizeForGaming(bottle) { loadMacDriver() }
                    } label: {
                        Label(store.isOptimized(bottle) ? "Optimized ✓ (Apply Again)" : "Optimize for Gaming",
                              systemImage: store.isOptimized(bottle) ? "checkmark.circle.fill" : "bolt.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.steamyAccent).foregroundStyle(Color.onSteamyAccent)
                    SettingRow("Engine") {
                        Picker("", selection: Binding(
                            get: { store.engine(of: bottle) },
                            set: { pendingEngine = $0 }
                        )) {
                            ForEach(store.engines) { engine in
                                Text(engine.title).tag(engine)
                                    .disabled(engine.url == nil && !store.canUseBundledEngine(bottle))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                    }
                    SettingRow("Graphics") {
                        Picker("", selection: Binding(
                            get: { store.graphics(bottle) },
                            set: { store.setPlist(bottle, $0.plistValues) }
                        )) {
                            ForEach(GraphicsBackend.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                        .disabled(bottle.isSteam)
                    }
                    if bottle.isSteam {
                        Text("Steam bottle stays on D3DMetal (managed by setup).")
                            .font(.app(.caption2)).foregroundStyle(.tertiary)
                    }
                    SettingRow("DLSS (via MetalFX)") {
                        Toggle("", isOn: Binding(
                            get: { store.environment(bottle)["D3DM_ENABLE_METALFX"] == "1" },
                            set: { store.setEnvironment(bottle, "D3DM_ENABLE_METALFX", $0 ? "1" : nil) }
                        ))
                        .toggleStyle(.switch).labelsHidden()
                        .disabled(store.graphics(bottle) == .dxvk || store.graphics(bottle) == .wined3d)
                    }
                    plistToggle("MSync", key: "WINEMSYNC")
                    plistToggle("ESync", key: "WINEESYNC")
                    plistToggle("DirectX 9 via DXVK (D9VK)", key: "D9VK")
                    plistToggle("DirectDraw fix (cnc-ddraw)", key: "CNC_DDRAW")
                    SettingRow("FPS Counter (in game)") {
                        Toggle("", isOn: Binding(get: { store.fpsCounter(bottle) }, set: { store.setFPSCounter(bottle, $0) }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                    plistToggle("Fast Math", key: "FASTMATH")
                    macDriverToggle("High Resolution Mode", key: "RetinaMode", defaultOn: false)
                    macDriverToggle("Exclusive Fullscreen", key: "CaptureDisplaysForFullscreen", defaultOn: false)
                    macDriverToggle("VSync", key: "AllowVerticalSync", defaultOn: true)
                    SettingRow("Mac Keyboard (⌘ as Ctrl)") {
                        Toggle("", isOn: Binding(get: { macDriver["LeftCommandIsCtrl"]?.lowercased() == "y" }, set: { on in
                            let v = on ? "y" : "n"
                            for key in ["LeftCommandIsCtrl", "RightCommandIsCtrl", "LeftOptionIsAlt", "RightOptionIsAlt"] { macDriver[key] = v }
                            store.importRegistry(bottle, [BottleStore.macDriverKey: [
                                "LeftCommandIsCtrl": "\"\(v)\"", "RightCommandIsCtrl": "\"\(v)\"",
                                "LeftOptionIsAlt": "\"\(v)\"", "RightOptionIsAlt": "\"\(v)\""]])
                        }))
                        .toggleStyle(.switch).labelsHidden()
                    }
                    SettingRow("Windows Version") {
                        Menu("Set…") {
                            ForEach(windowsVersions, id: \.id) { version in
                                Button(version.title) { store.wine(bottle, ["winecfg", "-v", version.id]) }
                            }
                        }
                        .frame(width: 90)
                    }
                    Text("Changes apply the next time the bottle starts.")
                        .font(.app(.caption2)).foregroundStyle(.tertiary)
                }

                PanelSection("Extras") {
                    PanelButton("DLL Overrides (Libraries)…", icon: "puzzlepiece.extension") { showDLLs = true }
                    PanelButton("Add xinput1_4 Override", icon: "gamecontroller") {
                        store.setRegistry(bottle, key: "HKCU\\Software\\Wine\\DllOverrides", name: "xinput1_4", value: "native,builtin")
                    }
                    PanelButton("Disable WPF Hardware Acceleration", icon: "rectangle.on.rectangle.slash") {
                        store.setDWORD(bottle, key: "HKCU\\Software\\Microsoft\\Avalon.Graphics", name: "DisableHWAcceleration", value: 1)
                    }
                    if FileManager.default.fileExists(atPath: bottle.steamDir.path) {
                        SettingRow("Block Steam Auto-Update") {
                            Toggle("", isOn: Binding(
                                get: { FileManager.default.fileExists(atPath: bottle.steamDir.appendingPathComponent("steam.cfg").path) },
                                set: { setSteamUpdateBlocked($0) }
                            ))
                            .toggleStyle(.switch).labelsHidden()
                        }
                    }
                }

                PanelSection("Control Panels") {
                    PanelButton("Wine Configuration", icon: "slider.horizontal.3") { store.launcher(bottle, ["WSS-winecfg"]) }
                    PanelButton("Game Controllers", icon: "gamecontroller") { store.wine(bottle, ["control", "joy.cpl"]) }
                    PanelButton("Internet Settings", icon: "globe") { store.wine(bottle, ["control", "inetcpl.cpl"]) }
                    PanelButton("Add/Remove Programs", icon: "shippingbox") { store.wine(bottle, ["control", "appwiz.cpl"]) }
                    PanelButton("Control Panel", icon: "switch.2") { store.launcher(bottle, ["WSS-control"]) }
                }

                PanelSection("Bottle Details", expanded: false) {
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                        GridRow { Text("Size").foregroundStyle(.secondary); Text(size) }
                        GridRow { Text("Engine").foregroundStyle(.secondary); Text(store.engine(of: bottle).title) }
                        GridRow {
                            Text("ID").foregroundStyle(.secondary)
                            Text(store.plistDictionary(bottle)["CFBundleIdentifier"] as? String ?? "-").lineLimit(1).truncationMode(.middle)
                        }
                        GridRow {
                            Text("Path").foregroundStyle(.secondary)
                            Text(bottle.url.path).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        }
                    }
                    .font(.app(.caption))
                    PanelButton("Show in Finder", icon: "magnifyingglass") {
                        NSWorkspace.shared.activateFileViewerSelecting([bottle.url])
                    }
                    PanelButton("Open Logs", icon: "doc.text") {
                        NSWorkspace.shared.open(bottle.contents.appendingPathComponent("SharedSupport/Logs"))
                    }
                }
                }
            }
            .padding(14)
        }
        .sheet(isPresented: $showRunCommand) { RunCommandSheet(store: store, bottle: bottle) }
        .sheet(isPresented: $showWinetricks) {
            TextPromptSheet(title: "Winetricks", prompt: "Verbs separated by spaces (e.g. vcrun2019 dotnet48 corefonts)", action: "Run") { text in
                store.launcher(bottle, ["WSS-winetricks"] + text.split(separator: " ").map(String.init))
            }
        }
        .sheet(isPresented: $showRename) {
            TextPromptSheet(title: "Rename Bottle", prompt: "Letters, numbers, spaces, - _ .", initial: bottle.name, action: "Rename") { text in
                store.rename(bottle, to: text)
            }
        }
        .sheet(isPresented: $showDLLs) { DLLOverridesSheet(store: store, bottle: bottle) }
        .alert("Switch to \(pendingEngine?.title ?? "")?", isPresented: Binding(
            get: { pendingEngine != nil }, set: { if !$0 { pendingEngine = nil } }
        )) {
            Button("Cancel", role: .cancel) {}
            Button("Switch") { if let engine = pendingEngine { store.setEngine(engine, for: bottle) } }
        } message: {
            Text("Everything running in \(bottle.name) will close. Installed programs stay. The first start on a new engine takes a little longer while Windows updates itself.")
        }
        .alert("Delete \(bottle.name)?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) { store.trash(bottle, completion: onDeleted) }
        } message: {
            Text("The bottle and every program installed in it will be moved to the Trash.")
        }
        .task(id: bottle.id) {
            let b = bottle
            loadMacDriver()
            let bytes = await Task.detached { FileManager.default.allocatedSize(of: b.contents) }.value
            size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }

    private func loadMacDriver() {
        let b = bottle
        Task.detached {
            let values = RegistryFile.section(b.prefix.appendingPathComponent("user.reg"), "Software\\Wine\\Mac Driver")
            await MainActor.run { macDriver = values }
        }
    }

    // MARK: Simple mode: plain-language choices for new users

    private var simpleOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            BigActionButton(title: "Install a Program", detail: "Pick a Windows installer (.exe or .msi)",
                            icon: "arrow.down.app.fill", tint: .blue) {
                if let f = store.pickFile(in: nil) { store.install(f, in: bottle) }
            }
            let optimized = store.isOptimized(bottle)
            BigActionButton(title: optimized ? "Optimized ✓" : "Make Games Run Faster",
                            detail: optimized ? "Best settings already on. Click to apply again."
                                              : "One click: the best speed settings",
                            icon: optimized ? "checkmark.circle.fill" : "bolt.fill", tint: .steamyAccent) {
                store.optimizeForGaming(bottle) { loadMacDriver() }
            }
            BigActionButton(title: "Something Not Working?", detail: "Closes everything in this bottle and restarts it",
                            icon: "wrench.and.screwdriver.fill", tint: .orange) {
                store.launcher(bottle, ["WSS-wineserverkill"]) { _, _ in store.launcher(bottle, ["WSS-wineboot"]) }
            }
            BigActionButton(title: "Open Files", detail: "See this bottle's C: drive in Finder",
                            icon: "folder.fill", tint: .gray) {
                NSWorkspace.shared.open(bottle.driveC)
            }

            Divider().padding(.vertical, 4)

            simpleToggle("Sharper Graphics", detail: "Looks crisper, but games run slower",
                         isOn: macDriver["RetinaMode"]?.lowercased() == "y") { on in
                macDriver["RetinaMode"] = on ? "y" : "n"
                store.importRegistry(bottle, [BottleStore.macDriverKey: ["RetinaMode": on ? "\"y\"" : "\"n\""]])
            }
            simpleToggle("Boost", detail: "Set games to 1600×900: MetalFX sharpens them to your screen at a steady 60 FPS (DirectX 11 games)",
                         isOn: store.boost(bottle)) { store.setBoost(bottle, $0) }
            simpleToggle("Show FPS Counter", detail: "See frame rate and GPU load while you play",
                         isOn: store.fpsCounter(bottle)) { store.setFPSCounter(bottle, $0) }
            simpleToggle("Mac Keyboard Shortcuts", detail: "⌘C, ⌘V and ⌘Z work like on your Mac",
                         isOn: macDriver["LeftCommandIsCtrl"]?.lowercased() == "y") { on in
                let v = on ? "y" : "n"
                for key in ["LeftCommandIsCtrl", "RightCommandIsCtrl", "LeftOptionIsAlt", "RightOptionIsAlt"] { macDriver[key] = v }
                store.importRegistry(bottle, [BottleStore.macDriverKey: [
                    "LeftCommandIsCtrl": "\"\(v)\"", "RightCommandIsCtrl": "\"\(v)\"",
                    "LeftOptionIsAlt": "\"\(v)\"", "RightOptionIsAlt": "\"\(v)\""]])
            }
            if FileManager.default.fileExists(atPath: bottle.steamDir.path) {
                simpleToggle("Stop Steam Auto-Updates", detail: "Keeps Steam stable so nothing breaks",
                             isOn: FileManager.default.fileExists(atPath: bottle.steamDir.appendingPathComponent("steam.cfg").path)) {
                    setSteamUpdateBlocked($0)
                }
            }

            Divider().padding(.vertical, 4)

            Button { advanced = true } label: {
                Label("Show All Advanced Options", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)

            if !bottle.isSteam {
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("Delete Bottle…", systemImage: "trash").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
        }
    }

    private func simpleToggle(_ title: String, detail: String, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.app(.caption)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(title, isOn: Binding(get: { isOn }, set: set))
                .toggleStyle(.switch).labelsHidden()
        }
    }

    /// A y/n value under HKCU\Software\Wine\Mac Driver; `defaultOn` is Wine's default when unset.
    private func macDriverToggle(_ title: String, key: String, defaultOn: Bool) -> some View {
        SettingRow(title) {
            Toggle("", isOn: Binding(
                get: { macDriver[key].map { $0.lowercased() == "y" } ?? defaultOn },
                set: { on in
                    macDriver[key] = on ? "y" : "n"
                    store.importRegistry(bottle, [BottleStore.macDriverKey: [key: on ? "\"y\"" : "\"n\""]])
                }
            ))
            .toggleStyle(.switch).labelsHidden()
        }
    }

    private func plistToggle(_ title: String, key: String) -> some View {
        SettingRow(title) {
            Toggle("", isOn: Binding(get: { store.flag(bottle, key) }, set: { store.setPlist(bottle, [key: $0 ? 1 : 0]) }))
                .toggleStyle(.switch).labelsHidden()
        }
    }

    private func setSteamUpdateBlocked(_ blocked: Bool) {
        let file = bottle.steamDir.appendingPathComponent("steam.cfg")
        do {
            if blocked {
                try "BootStrapperInhibitAll=Enable\n".write(to: file, atomically: true, encoding: .utf8)
            } else {
                try FileManager.default.removeItem(at: file)
            }
        } catch {
            store.alertMessage = error.localizedDescription
        }
        store.objectWillChange.send()
    }
}

extension FileManager {
    func allocatedSize(of url: URL) -> Int64 {
        guard let walker = enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}

/// Sidebar entry for a bottle, with right-click Rename / Duplicate / Delete.
struct BottleSidebarRow: View {
    @ObservedObject var store: BottleStore
    let bottle: Bottle
    let onDeleted: () -> Void
    @State private var confirmDelete = false
    @State private var showRename = false

    var body: some View {
        Label(bottle.name, systemImage: "shippingbox.fill")
            .contextMenu {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([bottle.url]) }
                Button("Duplicate") { store.duplicate(bottle) }
                let stored = BottleStore.storedURL(of: bottle)
                ForEach(BottleStore.externalVolumes.filter { stored?.path.hasPrefix($0.path + "/") != true }, id: \.self) { volume in
                    Button("Move to \(volume.lastPathComponent)") {
                        store.move(bottle, to: volume.appendingPathComponent("Steamy Bottles"))
                    }
                }
                if stored != nil {
                    Button("Move to This Mac") { store.move(bottle, to: nil) }
                }
                if !bottle.isSteam {
                    Button("Rename…") { showRename = true }
                    Divider()
                    Button("Delete Bottle…", role: .destructive) { confirmDelete = true }
                }
            }
            .alert("Delete \(bottle.name)?", isPresented: $confirmDelete) {
                Button("Cancel", role: .cancel) {}
                Button("Move to Trash", role: .destructive) { store.trash(bottle, completion: onDeleted) }
            } message: {
                Text("The bottle and every program installed in it will be moved to the Trash.")
            }
            .sheet(isPresented: $showRename) {
                TextPromptSheet(title: "Rename Bottle", prompt: "Letters, numbers, spaces, - _ .", initial: bottle.name, action: "Rename") {
                    store.rename(bottle, to: $0)
                }
            }
    }
}

struct BigActionButton: View {
    let title: String
    let detail: String
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.steamyAccent)
                    .frame(width: 40, height: 40)
                    .background(Color.steamyAccent.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.app(.body).weight(.semibold))
                    Text(detail).font(.app(.caption)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PanelSection<Content: View>: View {
    let title: String
    @State private var expanded: Bool
    @ViewBuilder let content: Content

    init(_ title: String, expanded: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        _expanded = State(initialValue: expanded)
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack {
                    Text(title.uppercased()).font(.app(.caption).bold())
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.app(.caption))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 6) { content }
            }
        }
        .padding(.vertical, 6)
    }
}

struct PanelButton: View {
    let title: String
    let icon: String
    var role: ButtonRole?
    let action: () -> Void

    init(_ title: String, icon: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .foregroundStyle(role == .destructive ? Color.red : Color.primary)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            control
        }
    }
}

// MARK: - Sheets

struct RunCommandSheet: View {
    @ObservedObject var store: BottleStore
    let bottle: Bottle
    @Environment(\.dismiss) private var dismiss
    @State private var script = ""
    @State private var saveName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Run Command in \(bottle.name)").font(.app(.title2).bold())
            Text("Windows batch commands (cmd.exe syntax). Browse inserts a program; you can paste lines like reg add, set and cd /d.")
                .font(.app(.callout)).foregroundStyle(.secondary)
            TextEditor(text: $script)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 170)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Button("Browse…") {
                    guard let url = store.pickFile(in: bottle) else { return }
                    let separator = script.isEmpty || script.hasSuffix("\n") ? "" : "\n"
                    let dir = bottle.windowsPath(url.deletingLastPathComponent())
                    script += "\(separator)cd /d \"\(dir)\"\nstart \"\" \"\(bottle.windowsPath(url))\"\n"
                }
                Button("Open Command Prompt") { store.launcher(bottle, ["WSS-cmd"]); dismiss() }
                Spacer()
            }
            TextField("Save as application named (optional)", text: $saveName)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Run") {
                    store.runScript(script, in: bottle, saveAs: saveName)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

struct TextPromptSheet: View {
    let title: String
    let prompt: String
    var initial = ""
    let action: String
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.app(.title2).bold())
            TextField(prompt, text: $text).onAppear { text = initial }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action) {
                    onSubmit(text.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct DLLOverridesSheet: View {
    @ObservedObject var store: BottleStore
    let bottle: Bottle
    @Environment(\.dismiss) private var dismiss
    @State private var overrides: [String: String] = [:]
    @State private var newName = ""
    @State private var newMode = "native,builtin"

    private let key = "HKCU\\Software\\Wine\\DllOverrides"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DLL Overrides").font(.app(.title2).bold())
            Text("Same as Wine Configuration → Libraries. Takes effect next time programs start.")
                .font(.app(.callout)).foregroundStyle(.secondary)
            HStack {
                TextField("DLL name (e.g. xinput1_4)", text: $newName)
                Picker("", selection: $newMode) {
                    ForEach(dllModes, id: \.self) { Text(dllModeTitle($0)).tag($0) }
                }
                .labelsHidden().frame(width: 150)
                Button("Add") {
                    let name = newName.trimmingCharacters(in: .whitespaces).lowercased()
                        .replacingOccurrences(of: ".dll", with: "")
                    guard !name.isEmpty else { return }
                    overrides[name] = newMode
                    store.setRegistry(bottle, key: key, name: name, value: newMode)
                    newName = ""
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            List {
                ForEach(overrides.keys.sorted(), id: \.self) { name in
                    HStack {
                        Text(name).font(.system(.body, design: .monospaced))
                        Spacer()
                        Text(dllModeTitle(overrides[name] ?? "")).foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            overrides[name] = nil
                            store.setRegistry(bottle, key: key, name: name, value: nil)
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .frame(height: 220)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            overrides = RegistryFile.section(bottle.prefix.appendingPathComponent("user.reg"), "Software\\Wine\\DllOverrides")
        }
    }
}

struct OptimizeSheet: View {
    @ObservedObject var store: BottleStore
    @Environment(\.dismiss) private var dismiss

    private let items: [(icon: String, title: String, detail: String)] = [
        ("bolt.fill", "MSync on", "Apple-native thread sync, lowest CPU overhead."),
        ("cpu", "Real GPU info", "Games see your actual GPU and VRAM and pick sane presets."),
        ("rectangle.on.rectangle", "Standard resolution", "Renders at point resolution instead of Retina: the biggest FPS gain."),
        ("arrow.up.left.and.arrow.down.right", "Exclusive fullscreen", "Fullscreen games skip the window compositor."),
        ("gamecontroller.fill", "macOS Game Mode + no App Nap", "Marks bottles as games so macOS prioritizes them and never throttles them."),
        ("text.badge.minus", "Logging off", "No Wine debug output while playing."),
        ("xmark.octagon", "No crash pop-ups", "Hides Wine's \"Program Error\" dialogs."),
        ("textformat", "Smooth fonts", "ClearType font smoothing so apps look closer to native."),
        ("sparkles", "DLSS via MetalFX", "Games with DLSS get Apple's MetalFX upscaling and frame generation."),
        ("thermometer.medium", "60 FPS cap", "Games stop at a steady 60 so your Mac stays cooler (DXVK and DXMT games). Turn on 'Limit display to 60 Hz' in Settings for DirectX 12 games.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Optimize for Gaming", systemImage: "bolt.fill").font(.app(.title2).bold()).foregroundStyle(.steamyAccent)
            let pending = store.bottles.filter { !store.isOptimized($0) }
            if pending.isEmpty {
                Label("All bottles are already optimized. No need to do it again.", systemImage: "checkmark.circle.fill")
                    .font(.app(.callout)).foregroundStyle(.steamyAccent)
            } else {
                Text("\(pending.count) of \(store.bottles.count) bottle(s) need optimizing: \(pending.map(\.name).joined(separator: ", ")). Takes effect next time each bottle starts.")
                    .font(.app(.callout)).foregroundStyle(.secondary)
            }
            ForEach(items, id: \.title) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.icon).foregroundStyle(.steamyAccent).frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).fontWeight(.medium)
                        Text(item.detail).font(.app(.caption)).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Graphics stays on D3DMetal (fastest for DirectX 11/12). Wine and Rosetta still cost some performance; this removes the overhead that can be removed.")
                .font(.app(.caption)).foregroundStyle(.tertiary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Optimize") {
                    store.optimizeAll()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .tint(.steamyAccent).foregroundStyle(Color.onSteamyAccent)
                .disabled(store.bottles.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 480)
    }
}

struct NewBottleSheet: View {
    @ObservedObject var store: BottleStore
    let onCreated: (Bottle) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var engine = BottleStore.bundledEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Bottle").font(.app(.title2).bold())
            Text("Creates a separate Windows 10 environment with its own C: drive, using the Wine engine downloaded during Steam setup.")
                .font(.app(.callout)).foregroundStyle(.secondary)
            TextField("Bottle name", text: $name)
            if store.engines.count > 1 {
                Picker("Engine", selection: $engine) {
                    ForEach(store.engines) { Text($0.title).tag($0) }
                }
            }
            if !name.isEmpty && !isValidBottleName(name) {
                Text("Use letters, numbers, spaces, - _ . (max 40).").font(.app(.caption)).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    let chosen = engine
                    store.createBottle(named: name) { bottle in
                        guard let bottle else { return }
                        store.setEngine(chosen, for: bottle) { onCreated(bottle) }
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValidBottleName(name) || store.bottles.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame })
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

struct InstallSheet: View {
    @ObservedObject var store: BottleStore
    @State var bottleID: String?
    @State var file: URL? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Install Software").font(.app(.title2).bold())
            HStack {
                Text(file?.lastPathComponent ?? "No installer selected")
                    .foregroundStyle(file == nil ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose Installer…") { file = store.pickFile(in: nil) ?? file }
            }
            Text("Or drag a .exe or .msi onto this window.")
                .font(.app(.caption)).foregroundStyle(.secondary)
            Picker("Install into bottle", selection: $bottleID) {
                ForEach(store.bottles) { Text($0.name).tag(Optional($0.id)) }
            }
            if store.bottles.isEmpty {
                Text("No bottles yet. Prepare Windows Steam or create a new bottle first.").font(.app(.caption)).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Install") {
                    if let file, let bottle = store.bottles.first(where: { $0.id == bottleID }) {
                        store.install(file, in: bottle)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(file == nil || bottleID == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(6).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            WindowsInstallerDrop.load(providers) { file = $0 }
        }
        .onAppear { if bottleID == nil { bottleID = store.bottles.first?.id } }
    }
}

/// Accepts a dropped Windows installer (.exe / .msi) from Finder.
enum WindowsInstallerDrop {
    static let extensions: Set<String> = ["exe", "msi"]

    static func isInstaller(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    /// Returns true when the drop carries a file; `handler` gets the URL only if it is an installer.
    @discardableResult
    static func load(_ providers: [NSItemProvider], handler: @escaping (URL) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, isInstaller(url) else { return }
            DispatchQueue.main.async { handler(url) }
        }
        return true
    }
}

// MARK: - Game Mode helpers (pure, checked in Tests/bottles_check.swift)

enum GameModeSafety {
    /// Process start time in microseconds, nil if the pid is gone. Distinguishes a reused pid.
    static func startTime(_ pid: pid_t) -> Int? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let t = info.kp_proc.p_starttime
        return Int(t.tv_sec) * 1_000_000 + Int(t.tv_usec)
    }

    /// Saved "pid:start" strings -> pids that still run the same process.
    static func stillSame(_ saved: [String], startTime: (pid_t) -> Int?) -> [pid_t] {
        saved.compactMap { entry in
            let p = entry.split(separator: ":")
            guard p.count == 2, let pid = pid_t(p[0]), let start = Int(p[1]), startTime(pid) == start else { return nil }
            return pid
        }
    }

    /// Index of the ~60 Hz mode with the same pixel size, only when the display now runs above 61 Hz.
    static func mode60Index(current: (w: Int, h: Int, hz: Double), modes: [(w: Int, h: Int, hz: Double)]) -> Int? {
        guard current.hz > 61 else { return nil }
        return modes.indices
            .filter { modes[$0].w == current.w && modes[$0].h == current.h && abs(modes[$0].hz - 60) <= 1 }
            .min { abs(modes[$0].hz - 60) < abs(modes[$1].hz - 60) }
    }
}
