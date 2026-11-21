import AppKit
import CryptoKit
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
    var isEpic: Bool { name == "Epic Games" }

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

/// Which DirectX version a Steam game really renders with. Byte-scanning alone is wrong for
/// engines that ship both (Unity, RE Engine), so engine markers come first.
enum GameAPI: String {
    case dx12, dx11, unknown

    static func detect(folder: URL) -> GameAPI {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])) ?? []
        func lower(_ u: URL) -> String { u.lastPathComponent.lowercased() }
        // RE Engine: "TargetPlatform=DirectX12" in a *config.ini.
        for ini in items where lower(ini).hasSuffix("config.ini") {
            guard (try? ini.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 < 1_000_000,
                  let text = try? String(contentsOf: ini, encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \.isNewline) {
                switch line.filter({ !$0.isWhitespace }).lowercased() {
                case "targetplatform=directx12": return .dx12
                case "targetplatform=directx11": return .dx11
                default: break
                }
            }
        }
        // Unity: DX11 unless boot.config forces d3d12.
        if let data = items.first(where: { lower($0).hasSuffix("_data") && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) {
            let boot = (try? String(contentsOf: data.appendingPathComponent("boot.config"), encoding: .utf8))?.lowercased() ?? ""
            return boot.contains("d3d12") ? .dx12 : .dx11
        }
        // Root .exe files only (not DLLs). ponytail: three casings of the name, not a full case-insensitive scan.
        var has11 = false
        for exe in items.filter({ $0.pathExtension.lowercased() == "exe" }).prefix(8) {
            guard let handle = try? FileHandle(forReadingFrom: exe), let data = try? handle.read(upToCount: 64 << 20) else { continue }
            try? handle.close()
            func has(_ n: String) -> Bool { [n, n.uppercased().replacingOccurrences(of: ".DLL", with: ".dll"), n.uppercased()].contains { data.range(of: Data($0.utf8)) != nil } }
            if has("d3d12.dll") { return .dx12 }
            if has("d3d11.dll") { has11 = true }
        }
        return has11 ? .dx11 : .unknown
    }

    /// Finds <library>/steamapps/common/<installDir> in the Steam bottle's libraries (main one plus libraryfolders.vdf).
    static func steamFolder(in bottle: Bottle, installDirectory: String) -> URL? {
        let main = bottle.steamDir.appendingPathComponent("steamapps")
        var roots = [main]
        let vdf = (try? String(contentsOf: main.appendingPathComponent("libraryfolders.vdf"), encoding: .utf8)) ?? ""
        for line in vdf.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
            guard parts.count >= 4, parts[1] == "path",
                  let url = bottle.unixURL(windowsPath: parts[3].replacingOccurrences(of: "\\\\", with: "\\")) else { continue }
            roots.append(url.appendingPathComponent("steamapps"))
        }
        return roots.map { $0.appendingPathComponent("common/\(installDirectory)") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
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
/// DXMT (DirectX 11 -> Metal) newer than the one Sikarugir bottles ship (0.74). 0.80 measured faster in a
/// D3D11 test in the Steam bottle (499/508/685 vs 419/151/291 FPS, 2026-11-21) and Steam drew with it.
/// Only for bottles on their own Wine 10 engine: on the Wine 11 engines 0.80 did not load as builtin.
enum DXMTUpdate {
    static let version = "v0.80"
    static let url = "https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz"
    static let sha256 = "8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d"
    static var staged: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steamy/DXMT/\(version)")
    }
    static var stagedAvailable: Bool {
        FileManager.default.fileExists(atPath: staged.appendingPathComponent("x86_64-unix/winemetal.so").path)
    }

    static func needsUpdate(renderer: URL) -> Bool {
        let current = (try? String(contentsOf: renderer.appendingPathComponent("dxmt/version"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current, current.hasPrefix("v") else { return false }  // no DXMT in this bottle
        return current.compare(version, options: .numeric) == .orderedAscending
    }

    /// Blocking: download, verify, extract to `staged`.
    static func downloadAndStage() throws {
        let fm = FileManager.default
        let work = staged.deletingLastPathComponent().appendingPathComponent(".download-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        func run(_ exe: String, _ args: [String]) throws {
            let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
        }
        let archive = work.appendingPathComponent("dxmt.tar.gz")
        try run("/usr/bin/curl", ["--connect-timeout", "20", "--fail", "--location", "--retry", "2", "--silent", "--output", archive.path, url])
        guard D3DMetalSwap.verify(archive, expected: sha256) else { throw CocoaError(.fileReadCorruptFile) }
        try run("/usr/bin/tar", ["-xzf", archive.path, "-C", work.path])
        let out = work.appendingPathComponent(version)
        guard fm.fileExists(atPath: out.appendingPathComponent("x86_64-unix/winemetal.so").path) else { throw CocoaError(.fileReadCorruptFile) }
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", out.path])
        try? fm.removeItem(at: staged)
        try fm.moveItem(at: out, to: staged)
    }

    /// Replaces renderer/dxmt/wine with the staged build. The old folder stays as renderer/dxmt-<old>
    /// for a one-step rollback (rename it back).
    static func apply(renderer: URL) throws {
        let fm = FileManager.default
        let dxmt = renderer.appendingPathComponent("dxmt")
        guard needsUpdate(renderer: renderer), stagedAvailable else { return }
        let old = (try? String(contentsOf: dxmt.appendingPathComponent("version"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "old"
        let backup = renderer.appendingPathComponent("dxmt-\(old)")
        let temp = renderer.appendingPathComponent(".dxmt-new")
        try? fm.removeItem(at: temp)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); ditto.arguments = [dxmt.path, temp.path]
        try ditto.run(); ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        try fm.removeItem(at: temp.appendingPathComponent("wine"))
        try fm.copyItem(at: staged, to: temp.appendingPathComponent("wine"))
        try version.write(to: temp.appendingPathComponent("version"), atomically: true, encoding: .utf8)
        if !fm.fileExists(atPath: backup.path) { try fm.moveItem(at: dxmt, to: backup) } else { try fm.removeItem(at: dxmt) }
        try fm.moveItem(at: temp, to: dxmt)
    }
}

final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    func append(_ d: Data) { lock.lock(); buffer.append(d); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
    func drain() -> Data {
        lock.lock()
        defer { lock.unlock() }
        let result = buffer
        buffer.removeAll(keepingCapacity: true)
        return result
    }
}

/// Swaps a bottle's renderer/d3dmetal between Apple's D3DMetal 3.0 (shipped) and 4.0 beta (staged).
/// The 3.0 folder is kept as renderer/d3dmetal-3.0 and never deleted while 4 is active.
/// 4.0b3 is staged in ~/Library/Application Support/Steamy/D3DMetal/4.0b3, downloaded once from the
/// WYNIX site (SHA-256 pinned below); until then, or if the download fails, bottles stay on 3.0.
enum D3DMetalSwap {
    static let downloadURL = "https://wynix.app/downloads/d3dmetal-4.0b3.tar.xz"
    static let expectedSHA256 = "189c582f3cea43834fa155cca060cc500954a100549c072822b6a0f457360c7c"

    static func sha256(of file: URL) -> String? {
        guard let d = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    /// True only when the file's SHA-256 equals `expected` (case-insensitive).
    static func verify(_ file: URL, expected: String = expectedSHA256) -> Bool {
        sha256(of: file) == expected.lowercased()
    }

    /// Blocking: download, verify, extract to a temp dir, then move into `staged`. Call off the main thread.
    static func downloadAndStage(from url: String = downloadURL, expected: String = expectedSHA256, to staged: URL = staged) throws {
        let fm = FileManager.default
        let work = staged.deletingLastPathComponent().appendingPathComponent(".download-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        func run(_ exe: String, _ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
        }
        let archive = work.appendingPathComponent("d3dmetal.tar.xz"), out = work.appendingPathComponent("out")
        try run("/usr/bin/curl", ["--connect-timeout", "20", "--speed-limit", "1024", "--speed-time", "60",
                                  "--fail", "--location", "--retry", "2", "--silent", "--show-error", "--output", archive.path, url])
        guard verify(archive, expected: expected) else { throw CocoaError(.fileReadCorruptFile) }
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        try run("/usr/bin/tar", ["-xJf", archive.path, "-C", out.path])
        guard fm.fileExists(atPath: out.appendingPathComponent("external/D3DMetal.framework").path) else { throw CocoaError(.fileReadCorruptFile) }
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", out.path])
        try? fm.removeItem(at: staged)
        try fm.moveItem(at: out, to: staged)  // same volume: atomic
    }

    static let staged = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Steamy/D3DMetal/4.0b3")
    static var stagedAvailable: Bool {
        FileManager.default.fileExists(atPath: staged.appendingPathComponent("external/D3DMetal.framework").path)
    }

    static func version(renderer: URL) -> String? {
        let info = renderer.appendingPathComponent("d3dmetal/external/D3DMetal.framework/Versions/A/Resources/Info.plist")
        return (NSDictionary(contentsOf: info))?["CFBundleShortVersionString"] as? String
    }

    /// `renderer` is Contents/Frameworks/renderer. Copy to a temp sibling first, then rename.
    static func swap(renderer: URL, staged: URL, to4: Bool) throws {
        let fm = FileManager.default
        let live = renderer.appendingPathComponent("d3dmetal"), backup = renderer.appendingPathComponent("d3dmetal-3.0")
        let temp = renderer.appendingPathComponent(".d3dmetal-new"), old = renderer.appendingPathComponent(".d3dmetal-old")
        try? fm.removeItem(at: temp); try? fm.removeItem(at: old)
        if to4 {
            if version(renderer: renderer)?.hasPrefix("4") == true { return }
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = [staged.path, temp.path]
            try ditto.run(); ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else { try? fm.removeItem(at: temp); throw CocoaError(.fileWriteUnknown) }
            let xattr = Process()
            xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattr.arguments = ["-dr", "com.apple.quarantine", temp.path]
            try? xattr.run(); xattr.waitUntilExit()
            // 4.0b3 ships the DLSS->MetalFX shim as nvngx-on-metalfx.*; the Read Me says to rename it to nvngx.*.
            for (dir, ext) in [("x86_64-unix", "so"), ("x86_64-windows", "dll")] {
                let wine = temp.appendingPathComponent("wine/\(dir)")
                let from = wine.appendingPathComponent("nvngx-on-metalfx.\(ext)"), to = wine.appendingPathComponent("nvngx.\(ext)")
                if fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) { try? fm.moveItem(at: from, to: to) }
            }
            if fm.fileExists(atPath: backup.path) { try fm.moveItem(at: live, to: old) }  // 3.0 already saved
            else { try fm.moveItem(at: live, to: backup) }
            do { try fm.moveItem(at: temp, to: live) } catch {
                if !fm.fileExists(atPath: backup.path) || fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: live) }
                else { try? fm.moveItem(at: backup, to: live) }
                throw error
            }
            try? fm.removeItem(at: old)
        } else {
            guard fm.fileExists(atPath: backup.path) else { return }
            try fm.moveItem(at: live, to: old)
            do { try fm.moveItem(at: backup, to: live) } catch { try? fm.moveItem(at: old, to: live); throw error }
            try? fm.removeItem(at: old)
        }
    }
}

enum AccountRecoveryLinks {
    static let epicAccount = URL(string: "https://www.epicgames.com/account/personal")!
    static let rockstarSupport = URL(string: "https://support.rockstargames.com/")!
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

    private var hudMigrated = false

    func reload() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        let list = urls.filter { $0.pathExtension == "app" }
            .map(Bottle.init(url:))
            .filter { fm.isExecutableFile(atPath: $0.wine.path) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        list.forEach(Self.fixPrefixPermissions)
        // Steam Play goes through setup.sh, not launcher(): keep each injected dylib current here too.
        for b in list where environment(b)["DYLD_INSERT_LIBRARIES"] != nil { _ = ensureUpscaler(b) }
        if list != bottles { bottles = list }  // no redraw on every app activation
        if !hudMigrated { hudMigrated = true; list.forEach(removeAppleHUD) }
        let found = scanEngines()
        if found != engines { engines = found }
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

    /// Lets users leave a stuck store/verification flow without touching credentials or account data.
    /// WYNIX cannot control Epic or Rockstar's verification dialog, so this returns to the
    /// WYNIX-owned bottle controls, closes running programs, and opens the official account paths.
    func changeEpicRockstarAccount(in bottle: Bottle) {
        guard bottle.isEpic else { return }
        launcher(bottle, ["WSS-wineserverkill"]) { [weak self] _, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                NSWorkspace.shared.open(AccountRecoveryLinks.epicAccount)
                let epicLauncher = self.programs[bottle.id]?.first {
                    $0.path.lowercased().contains("epicgameslauncher.exe")
                }
                if let epicLauncher {
                    self.open(URL(fileURLWithPath: epicLauncher.path), in: bottle)
                } else {
                    self.alertMessage = "Epic Games Launcher was not found in this bottle. Open Epic Games, sign out, then sign in with the account you want to use."
                }
            }
        }
    }

    func openRockstarRecovery() {
        NSWorkspace.shared.open(AccountRecoveryLinks.rockstarSupport)
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
            guard let self else { return }
            self.activity = "Installing \(file.lastPathComponent) into \(bottle.name)…"
            // Store installers (Epic, GOG, EA, Ubisoft, Battle.net) start their launcher when done, so the
            // wrapper never exits and the completion below never fires: "Installing…" stayed up forever
            // and nothing appeared until WYNIX restarted. Watch for the new program instead.
            let before = Set(Self.findPrograms(in: bottle).map(\.name))
            var finished = false
            func watch() {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [weak self] in
                    let found = Set(Self.findPrograms(in: bottle).map(\.name))
                    DispatchQueue.main.async {
                        guard let self, !finished else { return }
                        if !found.subtracting(before).isEmpty {
                            finished = true
                            self.activity = nil
                            self.scanPrograms(bottle)
                        } else { watch() }
                    }
                }
            }
            watch()
            self.launcher(bottle, ["WSS-installer", file.path]) { [weak self] status, output in
                guard let self else { return }
                if !finished {
                    finished = true
                    self.activity = nil
                    if status != 0 { self.alertMessage = "\(file.lastPathComponent) did not finish installing:\n\(output.suffix(400))" }
                }
                self.scanPrograms(bottle)
            }
        }
    }

    /// Steam re-adds itself to Windows' auto-start list when it exits, and Wine replays that
    /// list whenever the bottle wakes up. Clear it before Steamy wakes the Steam bottle.
    /// Runs `then` on main after autorun-off finished. The wait happens on a serial queue, so
    /// calls keep their order and main never blocks. Non-Steam bottles run `then` right away.
    private static let autorunQueue = DispatchQueue(label: "wynix.autorun")
    private func afterSteamAutorunOff(_ bottle: Bottle, _ then: @escaping @MainActor () -> Void) {
        guard bottle.isSteam, let script = Bundle.main.path(forResource: "setup", ofType: "sh") else { then(); return }
        let env = InstallerModel.taskEnvironment()
        Self.autorunQueue.async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = [script, "autorun-off"]
            task.environment = env
            try? task.run()
            task.waitUntilExit()
            DispatchQueue.main.async { MainActor.assumeIsolated { then() } }
        }
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

    /// Same as closeAllWindowsPrograms, in a separate bash process that keeps running after WYNIX quits.
    nonisolated static func closeAllWindowsProgramsDetached() {
        guard let script = Bundle.main.path(forResource: "setup", ofType: "sh") else { return }
        let pattern = "Applications/Sikarugir/|Steamy Bottles/"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", """
            /bin/bash "$1" stop >/dev/null 2>&1
            /usr/bin/pkill -TERM -f "$2"; /bin/sleep 5; /usr/bin/pkill -KILL -f "$2"
            """, "wynix-cleanup", script, pattern]
        task.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "USER": NSUserName()]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
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

    /// False (and tells the user) when the bottle was deleted or moved in Finder; stops callers recreating a stray folder.
    private func bottleExists(_ bottle: Bottle) -> Bool {
        if FileManager.default.fileExists(atPath: bottle.url.path) { return true }
        reload()
        alertMessage = "\(bottle.name) is no longer in the Sikarugir folder. It may have been deleted or moved."
        return false
    }

    func launcher(_ bottle: Bottle, _ arguments: [String], completion: ((Int32, String) -> Void)? = nil) {
        guard bottleExists(bottle) else {
            completion?(-1, "")  // callers set `activity` and clear it in completion
            return
        }
        removeAppleHUD(bottle)
        Self.ensureUserFolders(bottle)
        // macOS Game Mode: top CPU/GPU priority and fewer background tasks while the game is fullscreen.
        if (plistDictionary(bottle)["LSSupportsGameMode"] as? Bool) != true {
            setPlist(bottle, ["LSSupportsGameMode": true, "LSApplicationCategoryType": "public.app-category.games"])
        }
        if needsDylib(bottle) {  // a missing injected dylib would abort Wine
            if !ensureUpscaler(bottle) {  // only for this launch; the setting stays, a later restore re-adds it
                setEnvironment(bottle, "DYLD_INSERT_LIBRARIES", nil)
                if upscaleDX12(bottle) || benchmarking(bottle) || hudOn(bottle) {  // silent when nothing visible depends on it
                    alertMessage = "Boost, the HUD and benchmark are off for this launch of \(bottle.name): their files could not be restored."
                }
            } else if let path = upscalerURL(bottle)?.path, environment(bottle)["DYLD_INSERT_LIBRARIES"] == nil {
                setEnvironment(bottle, "DYLD_INSERT_LIBRARIES", path)
            }
        }
        afterSteamAutorunOff(bottle) { [self] in
            spawn(bottle.launcher, arguments, environment: InstallerModel.taskEnvironment(), completion: completion)
        }
    }

    func wine(_ bottle: Bottle, _ arguments: [String], completion: ((Bool, String) -> Void)? = nil) {
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
        afterSteamAutorunOff(bottle) { [self] in
            spawn(bottle.wine, arguments, environment: env) { [weak self] status, output in
                if status != 0 { self?.alertMessage = "wine \(arguments.prefix(2).joined(separator: " ")) failed:\n\(output.suffix(400))" }
                completion?(status == 0, output)
            }
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
        guard FileManager.default.fileExists(atPath: bottle.url.path) else { completion?(); return }
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
            completion?()
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
        guard bottleExists(bottle) else { completion?(); return }
        applyD3DMetalPreference(bottle)
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
        // No forced FPS cap: players asked for uncapped (Koikatsu). The opt-in "Limit display to
        // 60 Hz" setting caps every renderer for those who want a cooler Mac. Clears older caps.
        setEnvironment(bottle, "DXVK_FRAME_RATE", nil)
        setEnvironment(bottle, "D3DM_MAX_FPS", nil)
        // This DXVK build (dxvk-macOS-async) compiles shaders in the background: fewer stutters.
        setEnvironment(bottle, "DXVK_ASYNC", "1")
        // MoltenVK (DXVK's Metal layer): compile shaders on all cores at once (off by default; macOS
        // 13.3+), so first-time effects stutter less. And keep Metal fast math on, MoltenVK's own
        // default, which the template's FASTMATH = 0 can switch off.
        // https://github.com/KhronosGroup/MoltenVK/blob/v1.2.10/Docs/MoltenVK_Configuration_Parameters.md
        setEnvironment(bottle, "MVK_CONFIG_SHOULD_MAXIMIZE_CONCURRENT_COMPILATION", "1")
        setPlist(bottle, ["FASTMATH": 1])
        writeDXMTConfig(bottle, boost: boost(bottle))
        updateDXMT(bottle)
        // Steam bottle: MetalFX upscaling is the default; only an explicit off (key = 0) or DXMT Boost skips it.
        if bottle.isSteam && plistDictionary(bottle)["WynixUpscaleDX12"] == nil && !boost(bottle) {
            setUpscaleDX12(bottle, true, notify: false)
        }
        // Exclusive Fullscreen off: with it on, Cmd-Tab out of a fullscreen game left it hidden and
        // unreachable (Koikatsu, 2026-11-20). Still a toggle in the bottle settings.
        var macDriver = ["CaptureDisplaysForFullscreen": "\"n\""]
        // Point resolution is the biggest FPS win on Retina Macs, but it was overwriting the user's
        // "High Resolution Mode" choice on every Optimize (Steam looked pixelated). Only set it once.
        if RegistryFile.section(bottle.prefix.appendingPathComponent("user.reg"), "Software\\Wine\\Mac Driver")["RetinaMode"] == nil {
            macDriver["RetinaMode"] = "\"n\""
        }
        importRegistry(bottle, [
            Self.macDriverKey: macDriver,
            // Without this a game that switches the display mode leaves Wine's window at the old size.
            "HKEY_CURRENT_USER\\Software\\Wine\\X11 Driver": ["EmulateModeset": "\"y\""],
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

    /// Cached: the body reads this often. Refreshed by reload() (also on every app activation).
    @Published private(set) var engines: [Engine] = []

    private func scanEngines() -> [Engine] {
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
        if let link, let match = Self.matchEngine(link: link, in: engines) { return match }
        return Self.bundledEngine
    }

    /// The engine whose folder holds `link`: its own wine folder or any variant under it
    /// (<engine>/variants/dxmt/wine, <engine>/variants/d3dmetal/wine).
    static func matchEngine(link: String, in engines: [Engine]) -> Engine? {
        let target = URL(fileURLWithPath: link).standardizedFileURL.path
        return engines.first { engine in
            guard let dir = engine.url?.deletingLastPathComponent().standardizedFileURL.path else { return false }
            return target == dir || target.hasPrefix(dir + "/")
        }
    }

    /// Where a bottle's wine link should point for this engine: the variant for its renderer when
    /// the engine has variants (DXMT/Boost on -> dxmt, else d3dmetal), else the engine's wine folder.
    static func linkTarget(for engine: Engine, dxmt: Bool, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL? {
        guard let url = engine.url else { return nil }
        let variant = url.deletingLastPathComponent().appendingPathComponent("variants/\(dxmt ? "dxmt" : "d3dmetal")/wine")
        return fileExists(variant.path) ? variant : url
    }

    private func wantsDXMT(_ bottle: Bottle) -> Bool { flag(bottle, "DXMT") || boost(bottle) }

    /// The bottle's original engine is still around (needed to switch back to it).
    func canUseBundledEngine(_ bottle: Bottle) -> Bool {
        let fm = FileManager.default
        let wine = wineDir(bottle)
        let isLink = (try? fm.destinationOfSymbolicLink(atPath: wine.path)) != nil
        return !isLink || fm.fileExists(atPath: wine.deletingLastPathComponent().appendingPathComponent("wine.sikarugir").path)
    }

    func setEngine(_ engine: Engine, for bottle: Bottle, completion: (() -> Void)? = nil) {
        let target = Self.linkTarget(for: engine, dxmt: wantsDXMT(bottle))
        let current = (try? FileManager.default.destinationOfSymbolicLink(atPath: wineDir(bottle).path))
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        guard engine != self.engine(of: bottle) || (target != nil && current != target?.standardizedFileURL.path) else { completion?(); return }
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
                if let url = target {
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

    // MARK: Wine 11 engine (Whisky Libraries)
    //
    // This engine's ntdll ignores WINEDLLPATH_PREPEND, so DXMT and D3DMetal only load when their files
    // sit inside the engine. The engine therefore ships as two APFS clones (variants/dxmt, variants/d3dmetal)
    // of one Wine folder, each with a renderer copied in; the bottle's wine link points at the variant
    // for its renderer (setEngine here, and setup.sh before every Steam start).

    static let wine11ID = "wine-11.19"
    static let wine11URL = URL(string: "https://github.com/frankea/Whisky/releases/download/v4.8.3/Libraries.tar.gz")!
    static let wine11SHA256 = "08ffabd7b7c352470faee2b1d51061b341316e401439ca805c5302acc2fb8818"

    /// Builds <engineDir>/variants/{dxmt,d3dmetal}/wine as clones of <engineDir>/wine, with the files of
    /// `renderer` (a bottle's Contents/Frameworks/renderer) copied into lib/: renderer/dxmt/wine
    /// x86_64-windows and x86_64-unix (winemetal.so, overwriting the engine's), and for d3dmetal also
    /// renderer/d3dmetal/external into lib/external. DXMT 0.80 from Whisky's bundle (Libraries/DXMT) did
    /// not load as builtin (d3d11 and winemetal missing in +loaddll, 2026-11-20); the bottle's 0.74 does.
    /// Same volume, so `cp -c` makes the clones nearly free; falls back to a plain copy without APFS.
    nonisolated static func buildEngineVariants(engineDir: URL, renderer: URL) throws {
        let fm = FileManager.default
        func run(_ tool: String, _ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
            let err = Pipe(); p.standardError = err; p.standardOutput = FileHandle.nullDevice
            try p.run()
            let msg = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                throw NSError(domain: "WynixEngine", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey:
                    "\(([tool] + args).joined(separator: " ")) failed: " + (String(data: msg, encoding: .utf8) ?? "")])
            }
        }
        func copyInto(_ from: URL, _ to: URL) throws {  // contents of `from` into `to`, links kept as links
            guard fm.fileExists(atPath: from.path) else {
                throw NSError(domain: "WynixEngine", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing \(from.path)."])
            }
            try fm.createDirectory(at: to, withIntermediateDirectories: true)
            try run("/bin/cp", ["-RPf", from.path + "/.", to.path])
        }
        let base = engineDir.appendingPathComponent("wine")
        guard fm.isExecutableFile(atPath: base.appendingPathComponent("bin/wine").path) else {
            throw NSError(domain: "WynixEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Engine has no bin/wine."])
        }
        let staging = engineDir.appendingPathComponent(".variants-new")
        try? fm.removeItem(at: staging)
        for name in ["dxmt", "d3dmetal"] {
            let wine = staging.appendingPathComponent(name + "/wine")
            try fm.createDirectory(at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { try run("/bin/cp", ["-cR", base.path, wine.path]) } catch { try? fm.removeItem(at: wine); try run("/bin/cp", ["-R", base.path, wine.path]) }
            let lib = wine.appendingPathComponent("lib/wine")
            let src = renderer.appendingPathComponent(name + "/wine")
            try copyInto(src.appendingPathComponent("x86_64-windows"), lib.appendingPathComponent("x86_64-windows"))
            try copyInto(src.appendingPathComponent("x86_64-unix"), lib.appendingPathComponent("x86_64-unix"))
            if name == "d3dmetal" {
                try run("/usr/bin/ditto", [renderer.appendingPathComponent("d3dmetal/external").path, wine.appendingPathComponent("lib/external").path])
            }
        }
        let variants = engineDir.appendingPathComponent("variants")
        try? fm.removeItem(at: variants)
        try fm.moveItem(at: staging, to: variants)
    }

    /// Downloads (SSD temp when /Volumes/SSD exists, else the engines folder), checks the sha256,
    /// extracts Libraries/Wine to Engines/wine-11.19/wine and builds both renderer variants from `bottle`.
    func installWine11(from bottle: Bottle, completion: ((Bool) -> Void)? = nil) {
        let fm = FileManager.default
        let engineDir = Self.enginesRoot.appendingPathComponent(Self.wine11ID)
        let ssd = URL(fileURLWithPath: "/Volumes/SSD")
        let tempBase = fm.fileExists(atPath: ssd.path) ? ssd.appendingPathComponent("wynix-tmp") : Self.enginesRoot
        let renderer = rendererDir(bottle)
        // Already installed: a bottle may be running from it right now, never replace it underneath.
        if fm.fileExists(atPath: engineDir.appendingPathComponent("variants/dxmt/wine/bin/wine").path) { reload(); completion?(true); return }
        activity = "Installing Wine 11 (beta)…"
        let url = Self.wine11URL.absoluteString, expected = Self.wine11SHA256
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            var failure: String?
            let temp = tempBase.appendingPathComponent("wine11-\(UUID().uuidString)")
            do {
                try fm.createDirectory(at: temp, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: temp) }
                func run(_ tool: String, _ args: [String]) throws -> String {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
                    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
                    try p.run()
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    guard p.terminationStatus == 0 else { throw NSError(domain: "WynixEngine", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "\(tool) failed (\(p.terminationStatus))."]) }
                    return String(data: data, encoding: .utf8) ?? ""
                }
                func status(_ text: String) { DispatchQueue.main.async { self?.activity = text } }
                func sha(_ f: URL) -> String? { try? run("/usr/bin/shasum", ["-a", "256", f.path]).split(separator: " ").first.map(String.init) }
                // A finished download with the right checksum is reused (and kept for the next try).
                let tar = tempBase.appendingPathComponent("wine11-Libraries.tar.gz")
                if !(fm.fileExists(atPath: tar.path) && sha(tar) == expected) {
                    status("Downloading Wine 11 (beta), about 480 MB…")
                    try? fm.removeItem(at: tar)
                    _ = try run("/usr/bin/curl", ["-fsSL", "--retry", "3", "-o", tar.path, url])
                    status("Checking the download…")
                    guard sha(tar) == expected else { try? fm.removeItem(at: tar); throw NSError(domain: "WynixEngine", code: 3, userInfo: [NSLocalizedDescriptionKey: "Download does not match the expected checksum."]) }
                }
                defer { try? fm.removeItem(at: tar) }
                status("Unpacking Wine 11 (beta)…")
                let unpacked = temp.appendingPathComponent("x")
                try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
                _ = try run("/usr/bin/tar", ["-xzf", tar.path, "-C", unpacked.path])
                let wine = unpacked.appendingPathComponent("Libraries/Wine")
                guard fm.isExecutableFile(atPath: wine.appendingPathComponent("bin/wine").path) else { throw NSError(domain: "WynixEngine", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unexpected archive layout."]) }
                try? fm.removeItem(at: engineDir)
                try fm.createDirectory(at: engineDir, withIntermediateDirectories: true)
                try fm.moveItem(at: wine, to: engineDir.appendingPathComponent("wine"))
                let dxmtVersion = (try? String(contentsOf: renderer.appendingPathComponent("dxmt/version"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
                try (dxmtVersion ?? "unknown").write(to: engineDir.appendingPathComponent("dxmt-version"), atomically: true, encoding: .utf8)
                try "Wine 11 (beta)".write(to: engineDir.appendingPathComponent("title"), atomically: true, encoding: .utf8)
                status("Preparing the DXMT and D3DMetal variants…")
                try Self.buildEngineVariants(engineDir: engineDir, renderer: renderer)
            } catch {
                failure = error.localizedDescription
                try? fm.removeItem(at: engineDir)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.activity = nil
                if let failure { self.alertMessage = "Could not install Wine 11: \(failure)" }
                self.reload()
                completion?(failure == nil)
            }
        }
    }

    // MARK: Native Mac apps

    static let macAppsFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Steamy Apps")

    /// Creates a small .app in ~/Applications/Steamy Apps so the Windows program shows up
    /// in Launchpad, Spotlight and the Dock like any Mac app.
    @discardableResult
    func createMacApp(_ program: WinProgram, in bottle: Bottle) -> URL? {
        let shownName = displayName(program, in: bottle)
        let safeName = shownName.replacingOccurrences(of: #"[/:\x00-\x1F]"#, with: "-", options: .regularExpression)
        let app = Self.macAppsFolder.appendingPathComponent(safeName + ".app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = "#!/bin/bash\nexec \(quoted(bottle.launcher.path)) WSS-installer \(quoted(program.path)) >/dev/null 2>&1\n"
        let info: [String: Any] = [
            "CFBundleExecutable": "launch",
            "CFBundleIdentifier": "local.steamy.app.\(abs(program.path.hashValue))",
            "CFBundleName": shownName,
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

    /// Parsed Info.plist per bottle, re-read only when the file's modification date changes.
    private var plistCache: [URL: (Date?, [String: Any])] = [:]

    func plistDictionary(_ bottle: Bottle) -> [String: Any] {
        let mtime = try? bottle.plist.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let hit = plistCache[bottle.url], hit.0 == mtime, mtime != nil { return hit.1 }
        let dict = (NSDictionary(contentsOf: bottle.plist) as? [String: Any]) ?? [:]
        plistCache[bottle.url] = (mtime, dict)
        return dict
    }

    func flag(_ bottle: Bottle, _ key: String) -> Bool {
        (plistDictionary(bottle)[key] as? NSNumber)?.intValue == 1
    }

    /// Forgets every per-game profile choice ("Play without changes" included).
    func resetGameRecommendations(_ bottle: Bottle) {
        var dict = plistDictionary(bottle)
        let keys = dict.keys.filter { $0.hasPrefix("WynixGameProfile_") }
        guard !keys.isEmpty else { return }
        keys.forEach { dict.removeValue(forKey: $0) }
        if let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) {
            try? data.write(to: bottle.plist, options: .atomic)
        }
        plistCache[bottle.url] = nil
        objectWillChange.send()
    }

    /// Custom tile names live in the bottle's Info.plist ("WynixDisplayNames": program path -> name); no file is renamed.
    nonisolated static func displayName(_ program: WinProgram, overrides: [String: Any]) -> String {
        let custom = (overrides["WynixDisplayNames"] as? [String: String])?[program.path]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.flatMap { $0.isEmpty ? nil : $0 } ?? program.name
    }

    func displayName(_ program: WinProgram, in bottle: Bottle) -> String {
        Self.displayName(program, overrides: plistDictionary(bottle))
    }

    /// Empty name removes the override.
    func setDisplayName(_ name: String, for program: WinProgram, in bottle: Bottle) {
        var names = (plistDictionary(bottle)["WynixDisplayNames"] as? [String: String]) ?? [:]
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        names[program.path] = clean.isEmpty ? nil : clean
        setPlist(bottle, ["WynixDisplayNames": names])
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
        plistCache[bottle.url] = nil
        objectWillChange.send()
    }

    /// WYNIX performance HUD (FPS, CPU, GPU, memory, temperature) drawn by wynix_upscale.dylib in
    /// the game window. The dylib shows it while this file exists, so the toggle applies live.
    func hudFlag(_ bottle: Bottle) -> URL { bottle.driveC.appendingPathComponent("steamy/hud") }
    func hudOn(_ bottle: Bottle) -> Bool { FileManager.default.fileExists(atPath: hudFlag(bottle).path) }

    /// The dylib is always injected when the bottle can take it: besides upscaling, benchmark and the
    /// HUD it gives every game top priority (render thread QoS, foreground task).
    func needsDylib(_ bottle: Bottle) -> Bool { upscalerURL(bottle) != nil }

    func setHUD(_ bottle: Bottle, _ on: Bool) {
        let fm = FileManager.default
        if on {
            guard ensureUpscaler(bottle), let path = upscalerURL(bottle)?.path else {
                alertMessage = "The performance HUD needs the WYNIX helper library, which can't be installed in this bottle (its files could not be copied)."
                return
            }
            try? fm.createDirectory(at: hudFlag(bottle).deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: hudFlag(bottle).path, contents: nil)
            let wasInjected = environment(bottle)["DYLD_INSERT_LIBRARIES"] != nil
            setEnvironment(bottle, "DYLD_INSERT_LIBRARIES", path)
            if !wasInjected { noteRestartIfRunning() }  // already injected: it appears in the running game
        } else {
            try? fm.removeItem(at: hudFlag(bottle))
        }
        removeAppleHUD(bottle)
        objectWillChange.send()  // the toggle reads a file, not a published property
    }

    /// The Sikarugir template ships the Windows user profile without Documents, Desktop, Downloads,
    /// Music, Pictures and Videos. Games that save there fail: the Rockstar Launcher (GTA V) exits
    /// with code 1, "Unable to launch game". Create them before every launch (cheap, idempotent).
    /// Sikarugir's own chmod pass (on wineserverkill) once left drive_c as rw-rw-rw-: no execute
    /// bit, so no folder inside it opens and every program and Steam fail silently (2026-11-20).
    nonisolated static func fixPrefixPermissions(_ bottle: Bottle) {
        let fm = FileManager.default
        for dir in [bottle.prefix, bottle.driveC] {
            if let mode = (try? fm.attributesOfItem(atPath: dir.path))?[.posixPermissions] as? Int, mode & 0o111 != 0o111 {
                try? fm.setAttributes([.posixPermissions: mode | 0o111], ofItemAtPath: dir.path)
            }
        }
    }

    static func ensureUserFolders(_ bottle: Bottle) {
        let users = bottle.driveC.appendingPathComponent("users")
        let fm = FileManager.default
        fixPrefixPermissions(bottle)
        for user in (try? fm.contentsOfDirectory(at: users, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? [] {
            guard user.lastPathComponent != "Public",
                  (try? user.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
            for folder in ["Documents", "Desktop", "Downloads", "Music", "Pictures", "Videos"] {
                try? fm.createDirectory(at: user.appendingPathComponent(folder), withIntermediateDirectories: true)
            }
        }
    }

    /// Older versions turned on Apple's Metal HUD / DXVK's counter; WYNIX draws its own now.
    func removeAppleHUD(_ bottle: Bottle) {
        let plist = plistDictionary(bottle)
        if (plist["METAL_HUD"] as? NSNumber)?.boolValue == true || (plist["WynixHUD"] as? String)?.isEmpty == false {
            setPlist(bottle, ["METAL_HUD": 0, "WynixHUD": ""])
        }
        let env = environment(bottle)
        for key in ["MTL_HUD_ELEMENTS", "MTL_HUD_SCALE", "MTL_HUD_OPACITY", "MTL_HUD_DISABLE_MENU_BAR",
                    "DXVK_HUD", "WYNIX_UPSCALE_LABEL", "WYNIX_HUD_TEMP"] where env[key] != nil {
            setEnvironment(bottle, key, nil)
        }
    }

    // MARK: D3DMetal 4 (beta) with 3.0 fallback

    private func rendererDir(_ bottle: Bottle) -> URL { bottle.contents.appendingPathComponent("Frameworks/renderer") }

    /// Brings the bottle's DXMT up to DXMTUpdate.version (downloads once). Skipped while Wine runs and on
    /// bottles linked to a shared Wine 11 engine.
    func updateDXMT(_ bottle: Bottle) {
        let renderer = rendererDir(bottle)
        let linked = (try? FileManager.default.destinationOfSymbolicLink(atPath: wineDir(bottle).path)) != nil
        guard !linked, !Self.windowsProgramsRunning, DXMTUpdate.needsUpdate(renderer: renderer) else { return }
        DispatchQueue.global(qos: .utility).async {
            if !DXMTUpdate.stagedAvailable { try? DXMTUpdate.downloadAndStage() }
            try? DXMTUpdate.apply(renderer: renderer)
        }
    }

    func d3dmetalVersion(_ bottle: Bottle) -> String? { D3DMetalSwap.version(renderer: rendererDir(bottle)) }

    /// Default is 4; only an explicit WynixD3DMetal = "3" keeps 3.0.
    func wantsD3DMetal3(_ bottle: Bottle) -> Bool { plistDictionary(bottle)["WynixD3DMetal"] as? String == "3" }

    /// Refuses while Wine runs. Returns true when the bottle ends on the requested version.
    @discardableResult
    func setD3DMetal4(_ bottle: Bottle, on: Bool, quiet: Bool = false) -> Bool {
        guard bottleExists(bottle) else { return false }
        if Self.windowsProgramsRunning {
            if !quiet { alertMessage = "Close Steam and other running programs first, then change the D3DMetal version." }
            return false
        }
        do {
            if on && !D3DMetalSwap.stagedAvailable { return false }
            try D3DMetalSwap.swap(renderer: rendererDir(bottle), staged: D3DMetalSwap.staged, to4: on)
        } catch {
            if !quiet { alertMessage = "Could not switch D3DMetal: \(error.localizedDescription)" }
            return false
        }
        if !quiet { setPlist(bottle, ["WynixD3DMetal": on ? "4" : "3"]) }
        setEnvironment(bottle, "D3DM_MAX_FPS", nil)  // no forced FPS cap (opt-in: "Limit display to 60 Hz")
        return true
    }

    /// Optimize / Play: move to 4 unless the user chose 3.0. Silent; skipped while Wine runs (next time).
    /// `then` runs on main once the bottle's renderer is settled: Play waits for it so Wine never
    /// starts while the framework is half copied.
    func applyD3DMetalPreference(_ bottle: Bottle, then: @escaping @MainActor () -> Void = {}) {
        guard !wantsD3DMetal3(bottle) else { then(); return }
        guard D3DMetalSwap.stagedAvailable else { downloadD3DMetal4(then: bottle); then(); return }
        let is4 = d3dmetalVersion(bottle)?.hasPrefix("4") == true
        if is4 { setEnvironment(bottle, "D3DM_MAX_FPS", nil); then(); return }
        // The swap copies the whole framework: off the main thread, or Play beachballs.
        let renderer = rendererDir(bottle)
        let showing = activity == nil
        if showing { activity = "Switching to D3DMetal 4…" }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = !Self.windowsProgramsRunning
                && (try? D3DMetalSwap.swap(renderer: renderer, staged: D3DMetalSwap.staged, to4: true)) != nil
            DispatchQueue.main.async {
                if showing { self?.activity = nil }
                if ok { self?.setEnvironment(bottle, "D3DM_MAX_FPS", nil) }
                then()
            }
        }
    }

    private var d3dmetalDownloadTried = false

    /// Background download of D3DMetal 4 (once per session). Never blocks Play: the caller carries on
    /// with 3.0, and the swap happens when the download lands (or next launch if Wine is running).
    private func downloadD3DMetal4(then bottle: Bottle) {
        guard !d3dmetalDownloadTried else { return }
        d3dmetalDownloadTried = true
        let showing = activity == nil
        if showing { activity = "Downloading D3DMetal 4…" }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ok = (try? D3DMetalSwap.downloadAndStage()) != nil
            DispatchQueue.main.async {
                guard let self else { return }
                if showing { self.activity = nil }
                if ok { self.applyD3DMetalPreference(bottle) }
                else { self.alertMessage = "Could not download D3DMetal 4; staying on 3.0." }
            }
        }
    }

    /// DXMT/upscaler/HUD env vars are read when Wine starts, so a running bottle needs a restart.
    private func noteRestartIfRunning() {
        if Self.windowsProgramsRunning { alertMessage = "Restart Steam (or the running program) to apply this change." }
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
        // Output never above 1080p width (owner rule: upscaling to 2K costs more than it gives).
        min(2.0, max(1.0, min(1920, Double(CGDisplayPixelsWide(CGMainDisplayID()))) / boostRenderWidth))
    }

    /// Writes C:/steamy/dxmt.conf: no FPS cap, plus the MetalFX
    /// upscale factor when Steamy Boost is on.
    @discardableResult
    func writeDXMTConfig(_ bottle: Bottle, boost: Bool) -> Bool {
        guard FileManager.default.fileExists(atPath: bottle.url.path) else { return false }
        let confDir = bottle.driveC.appendingPathComponent("steamy")
        var conf = "# Written by Steamy\n"
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

    func setBoost(_ bottle: Bottle, _ on: Bool, notify: Bool = true) {
        defer { if notify { noteRestartIfRunning() } }
        guard writeDXMTConfig(bottle, boost: on) else { return }
        if on && upscaleDX12(bottle) { setUpscaleDX12(bottle, false, notify: false) }  // one upscaler at a time
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

    // MARK: DirectX 12 Boost (experimental, see docs/UPSCALING.md)

    /// D3DMetal has no upscaler, so wynix_upscale.dylib is injected into the bottle's Wine
    /// processes: it hands the game a smaller drawable and MetalFX-upscales it to the screen.
    /// EmulateModeset keeps the monitor at its native mode when the game picks 1600x900.
    func upscaleDX12(_ bottle: Bottle) -> Bool { flag(bottle, "WynixUpscaleDX12") }

    /// The dylib lives inside the bottle, so the bottle keeps working when opened from Finder
    /// or the Dock and survives WYNIX being removed. dyld kills Wine if the file is missing, and
    /// the bottle's export line is unquoted and DYLD_INSERT_LIBRARIES is colon-separated, so
    /// bottles whose path has a space or colon (e.g. "Epic Games.app") keep it in ~/.wynix/<bottle> instead.
    func upscalerURL(_ bottle: Bottle) -> URL? {
        func usable(_ url: URL) -> Bool { !url.path.contains(" ") && !url.path.contains(":") }
        let inside = bottle.contents.appendingPathComponent("Frameworks/wynix_upscale.dylib")
        if usable(inside) { return inside }
        let name = bottle.url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: ":", with: "_")
        let outside = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".wynix/\(name)/wynix_upscale.dylib")
        guard usable(outside) else { return nil }
        try? FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        return outside
    }

    /// Copies the bundled dylib into the bottle if missing or outdated.
    func ensureUpscaler(_ bottle: Bottle) -> Bool {
        guard let src = Bundle.main.url(forResource: "wynix_upscale", withExtension: "dylib"),
              let dest = upscalerURL(bottle) else { return false }
        let fm = FileManager.default
        if fm.contentsEqual(atPath: src.path, andPath: dest.path) { return true }
        // Copy beside it, then swap in one rename: a Wine process starting meanwhile never sees it missing.
        let tmp = dest.deletingLastPathComponent().appendingPathComponent(".wynix_upscale.dylib.new")
        do {
            try? fm.removeItem(at: tmp)
            try fm.copyItem(at: src, to: tmp)
            removexattr(tmp.path, "com.apple.quarantine", 0)
            guard Darwin.rename(tmp.path, dest.path) == 0 else { try? fm.removeItem(at: tmp); return false }
            return true
        } catch {
            return false
        }
    }

    // MARK: Benchmark (the dylib records frame times when WYNIX_BENCH_FILE is set, Boost or not)

    func benchmarking(_ bottle: Bottle) -> Bool { flag(bottle, "WynixBenchmark") }
    func benchDir(_ bottle: Bottle) -> URL { bottle.contents.appendingPathComponent("wynix-bench") }

    func setBenchmarking(_ bottle: Bottle, _ on: Bool) {
        guard !on || ensureUpscaler(bottle), let path = upscalerURL(bottle)?.path else {
            alertMessage = "Recording performance needs the WYNIX helper library, which can't be installed in this bottle (its files could not be copied)."
            return
        }
        setEnvironment(bottle, "WYNIX_BENCH_FILE", on ? benchDir(bottle).path + "/" : nil)
        if on { setEnvironment(bottle, "DYLD_INSERT_LIBRARIES", path) }
        setPlist(bottle, ["WynixBenchmark": on ? 1 : 0])
        noteRestartIfRunning()
    }

    /// Last 10 runs, newest first. Files with too few frames to mean anything (Steam's own windows) are skipped.
    func benchRuns(_ bottle: Bottle, since: Date? = nil) -> [BenchRun] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: benchDir(bottle), includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let runs: [BenchRun] = urls.compactMap { u in
            guard let date = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  since == nil || date >= since!,
                  let text = try? String(contentsOf: u, encoding: .utf8), var r = BenchRun.parse(text) else { return nil }
            r.date = date
            return r
        }
        return Array(runs.sorted { $0.date > $1.date }.prefix(10))
    }

    /// Shows the biggest run recorded since `since` (the game's, not Steam's own windows).
    func reportBenchmark(_ bottle: Bottle, game: String, since: Date) {
        guard benchmarking(bottle),
              let r = benchRuns(bottle, since: since).max(by: { $0.frames < $1.frames }) else { return }
        alertMessage = "Benchmark: \(game) \u{2014} \(r.summary)"
    }

    func setUpscaleDX12(_ bottle: Bottle, _ on: Bool, notify: Bool = true) {
        if on && boost(bottle) { setBoost(bottle, false, notify: false) }  // Boost's DXMT already upscales
        guard !on || ensureUpscaler(bottle), let path = upscalerURL(bottle)?.path ?? (on ? nil : "") else {
            alertMessage = upscalerURL(bottle) == nil
                ? "Boost (MetalFX upscaling) can't be used for this bottle: its folder path contains a space."
                : "Boost (MetalFX upscaling) could not be installed into \(bottle.name)."
            return
        }
        if on { setEnvironment(bottle, "DYLD_INSERT_LIBRARIES", path) }
        setEnvironment(bottle, "WYNIX_UPSCALE", on ? "1" : nil)
        setEnvironment(bottle, "WYNIX_UPSCALE_SCALE", nil)  // retired; cleans old bottles
        setPlist(bottle, ["WynixUpscaleDX12": on ? 1 : 0])  // 0 = explicit off, missing = default on (Steam)
        if notify { noteRestartIfRunning() }
    }

    // MARK: Optimized state

    /// Bump when `optimizeForGaming` gains settings, so bottles get offered the new ones.
    static let optimizeVersion = 7

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
        activity = L10n.format("bottle.creating", name)
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
                self.alertMessage = error.map { String($0.dropFirst(8)) } ?? L10n.format("bottle.createFailed", String(output.suffix(400)))
                completion(nil)
            }
        }
    }

    func rename(_ bottle: Bottle, to name: String) {
        guard !bottle.isSteam, isValidBottleName(name) else { alertMessage = L10n.string("bottle.invalidName"); return }
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
    private static var volumesCache: [URL]?
    private static let volumeObservers: [NSObjectProtocol] = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification].map {
        NSWorkspace.shared.notificationCenter.addObserver(forName: $0, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { volumesCache = nil }
        }
    }

    static var externalVolumes: [URL] {
        _ = volumeObservers
        if let cached = volumesCache { return cached }
        let found = scanExternalVolumes()
        volumesCache = found
        return found
    }

    private static func scanExternalVolumes() -> [URL] {
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
    @State private var renaming: WinProgram?

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
                                ProgramTile(program: program, name: store.displayName(program, in: bottle), opening: openingID == program.id)
                                    .onTapGesture(count: 2) { launch(program) }
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityAction(named: "Open") { launch(program) }
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
                                        Button("Rename…") { renaming = program }
                                        if store.displayName(program, in: bottle) != program.name {
                                            Button("Reset Name") { store.setDisplayName("", for: program, in: bottle) }
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
        .sheet(item: $renaming) { program in
            TextPromptSheet(title: "Rename", prompt: "Name shown on the tile (max 60 characters)", initial: store.displayName(program, in: bottle), action: "Save") { text in
                store.setDisplayName(text, for: program, in: bottle)
            }
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

/// Decoded icons, so a redraw doesn't decode the same PNG again.
enum ImageCache {
    private static let cache = NSCache<NSString, NSImage>()
    static func image(key: String, data: Data?) -> NSImage? {
        if let hit = cache.object(forKey: key as NSString) { return hit }
        guard let data, let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key as NSString)
        return image
    }
    static func image(path: String) -> NSImage? {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

struct ProgramTile: View {
    let program: WinProgram
    var name = ""
    var opening = false
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let image = ImageCache.image(key: program.id, data: program.iconData) {
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
            Text(opening ? "Opening…" : name)
                .font(.app(.callout))
                .foregroundStyle(opening ? Color.steamyAccent : Color.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(width: 130)
        .contentShape(Rectangle())
        .help(program.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(opening ? "\(name), opening" : name)
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
    @State private var confirmEpicAccountSwitch = false
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
                    if bottle.isEpic {
                        PanelButton("Change Epic / Rockstar Account", icon: "person.crop.circle.badge.questionmark") {
                            confirmEpicAccountSwitch = true
                        }
                        PanelButton("Rockstar Account Recovery", icon: "key") { store.openRockstarRecovery() }
                    }
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
                    if !store.engines.contains(where: { $0.id == BottleStore.wine11ID }) {
                        Button {
                            store.installWine11(from: bottle)
                        } label: {
                            Label("Install Wine 11 (beta)", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(store.activity != nil)
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
                    SettingRow("Game recommendations") {
                        Button("Reset") { store.resetGameRecommendations(bottle) }
                    }
                    plistToggle("MSync", key: "WINEMSYNC")
                    plistToggle("ESync", key: "WINEESYNC")
                    plistToggle("DirectX 9 via DXVK (D9VK)", key: "D9VK")
                    plistToggle("DirectDraw fix (cnc-ddraw)", key: "CNC_DDRAW")
                    SettingRow("Show performance HUD (in game)") {
                        Toggle("", isOn: Binding(get: { store.hudOn(bottle) }, set: { store.setHUD(bottle, $0) }))
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
        .alert("Change Epic / Rockstar Account?", isPresented: $confirmEpicAccountSwitch) {
            Button("Close & Open Epic") { store.changeEpicRockstarAccount(in: bottle) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("WYNIX will close running apps in this bottle, open Epic account settings, and try to reopen Epic Games Launcher. Sign out and back in in Epic; WYNIX does not read, change, or store credentials. Rockstar's verification screen is controlled by Rockstar.")
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
            if bottle.isEpic {
                BigActionButton(title: "Change Epic / Rockstar Account",
                                detail: "Closes this bottle and opens official account/sign-in paths",
                                icon: "person.crop.circle.badge.questionmark", tint: .orange) {
                    confirmEpicAccountSwitch = true
                }
                BigActionButton(title: "Rockstar Account Recovery",
                                detail: "Open Rockstar's account recovery and sign-in help",
                                icon: "key.fill", tint: .blue) {
                    store.openRockstarRecovery()
                }
            }
            BigActionButton(title: "Support WYNIX ☕", detail: "WYNIX is free. A coffee on Ko-fi helps keep it going (nothing is locked)",
                            icon: "heart.fill", tint: .pink) {
                NSWorkspace.shared.open(URL(string: "https://ko-fi.com/wynix")!)
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
            simpleToggle("Boost (MetalFX upscaling)", detail: "Pick a lower resolution in the game (like 1280×720 or 1600×900); MetalFX upscales it to your screen's shape, up to 1080p.",
                         isOn: store.upscaleDX12(bottle)) { store.setUpscaleDX12(bottle, $0) }
            simpleToggle("Record performance (benchmark)", detail: "Saves frame times while you play and shows average FPS, 1% low and frame time when the game ends",
                         isOn: store.benchmarking(bottle)) { store.setBenchmarking(bottle, $0) }
            benchmarkList
            simpleToggle("DirectX 11 compatibility mode", detail: "Only for DirectX 11 games that look wrong or run worse with the default.",
                         isOn: store.boost(bottle)) { store.setBoost(bottle, $0) }
            if D3DMetalSwap.stagedAvailable, let version = store.d3dmetalVersion(bottle) {
                simpleToggle("Use D3DMetal 3.0 (compatibility)",
                             detail: "D3DMetal 4 (beta) is the default. Turn this on if a game crashes or looks wrong. Using D3DMetal \(version)",
                             isOn: store.wantsD3DMetal3(bottle)) { store.setD3DMetal4(bottle, on: !$0) }
            }
            simpleToggle("Show performance HUD", detail: "FPS, CPU, GPU, memory and temperature, small in the top right while you play",
                         isOn: store.hudOn(bottle)) { store.setHUD(bottle, $0) }
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

    @ViewBuilder private var benchmarkList: some View {
        let runs = store.benchRuns(bottle)
        if !runs.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Benchmarks").font(.app(.caption)).fontWeight(.medium)
                ForEach(runs, id: \.date) { r in
                    Text("\(r.date.formatted(date: .abbreviated, time: .shortened)): \(r.summary)")
                        .font(.app(.caption2)).foregroundStyle(.secondary)
                }
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
                        .help("Remove override")
                        .accessibilityLabel("Remove override for \(name)")
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
        ("thermometer.medium", "No FPS cap", "Games run as fast as your Mac allows. Want a cooler Mac? Turn on 'Limit display to 60 Hz' in Settings.")
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
            Text("Makes a separate Windows space for a game that needs its own settings. Set up Steam first.")
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

    private var selectedBottle: Bottle? { store.bottles.first { $0.id == bottleID } }

    private static func fileSize(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func choose() { file = store.pickFile(in: nil) ?? file }

    private var dropZone: some View {
        VStack(spacing: 10) {
            if let file {
                Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().frame(width: 64, height: 64)
                Text(file.lastPathComponent).font(.app(.headline)).lineLimit(1).truncationMode(.middle)
                Text(Self.fileSize(file)).font(.app(.caption)).foregroundStyle(.secondary)
                Button("Change") { choose() }.controlSize(.small)
                    .accessibilityLabel("Change installer file")
            } else {
                Image(systemName: dropTargeted ? "square.and.arrow.down.fill" : "arrow.down.app")
                    .font(.system(size: 44, weight: .light)).foregroundStyle(Color.steamyAccent)
                Text("Drop a Windows installer here").font(.app(.title3).bold())
                Text(".exe or .msi — or choose a file").font(.app(.callout)).foregroundStyle(.secondary)
                Button("Choose File…") { choose() }
                    .buttonStyle(.borderedProminent).tint(.steamyAccent).foregroundStyle(Color.onSteamyAccent)
                    .accessibilityLabel("Choose installer file")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 190)
        .padding(16)
        .background(Color.steamyAccent.opacity(dropTargeted ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(dropTargeted ? Color.steamyAccent : Color.secondary.opacity(0.5),
                              style: StrokeStyle(lineWidth: dropTargeted ? 2.5 : 1.5, dash: file == nil ? [7, 5] : []))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(file.map { "Selected installer \($0.lastPathComponent)" } ?? "Drop zone for a Windows installer, .exe or .msi")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Install Software").font(.app(.title2).bold())
            dropZone
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Install into").font(.app(.callout).weight(.medium))
                    Picker("Install into", selection: $bottleID) {
                        ForEach(store.bottles) { bottle in
                            Label {
                                Text(bottle.name)
                            } icon: {
                                // Sikarugir's wrapper icon (wine barrel) looks out of place here.
                                Image(systemName: bottle.isSteam ? "gamecontroller.fill" : "macwindow")
                            }.tag(Optional(bottle.id))
                        }
                    }
                    .labelsHidden().frame(maxWidth: 260)
                    .accessibilityLabel("Bottle to install into")
                    Spacer()
                }
                Text(store.bottles.isEmpty
                     ? "No bottles yet. Set up Steam or make a new bottle first."
                     : "Each bottle is a separate Windows. Steam games go in Steam.")
                    .font(.app(.caption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Cancel installation")
                Button("Install") {
                    if let file, let bottle = selectedBottle { store.install(file, in: bottle) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent).tint(.steamyAccent).foregroundStyle(Color.onSteamyAccent)
                .keyboardShortcut(.defaultAction)
                .disabled(file == nil || bottleID == nil)
                .accessibilityLabel("Install software into the selected bottle")
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
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

// MARK: - Benchmark (pure, checked in Tests/bottles_check.swift)

struct BenchRun {
    var date = Date()
    var header = ""        // text after "# wynix-bench v1 "
    var intervals: [Double]  // ms, first 5 s dropped
    var duration: Double     // seconds, whole file
    var frames: Int { intervals.count }
    var avgFPS: Double { intervals.isEmpty ? 0 : Double(intervals.count) * 1000 / intervals.reduce(0, +) }
    var medianMs: Double { intervals.isEmpty ? 0 : intervals.sorted()[intervals.count / 2] }
    /// FPS of the 99th percentile frame time.
    var lowFPS: Double {
        guard !intervals.isEmpty else { return 0 }
        let sorted = intervals.sorted()
        return 1000 / sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.99).rounded(.up)) - 1)]
    }

    /// "68.9 avg FPS, 52.1 1% low, 14.5 ms median, 2 min 03 s; D3DMetal 4.0b3, Boost on (1280x720 -> 1920x1080)"
    var summary: String {
        let d = Int(duration.rounded())
        let fields = Dictionary(uniqueKeysWithValues: header.split(separator: " ").compactMap { kv -> (String, String)? in
            let p = kv.split(separator: "=", maxSplits: 1); return p.count == 2 ? (String(p[0]), String(p[1])) : nil })
        let boost = fields["upscale"] == "1" ? "Boost on (\(fields["in"] ?? "?") -> \(fields["out"] ?? "?"))" : "Boost off"
        return String(format: "%.1f avg FPS, %.1f 1%% low, %.1f ms median, %d min %02d s; D3DMetal %@, %@",
                      avgFPS, lowFPS, medianMs, d / 60, d % 60, fields["d3dmetal"] ?? "unknown", boost)
    }

    /// Header line then one frame interval (ms) per line. nil when it is not a bench file or has nothing after the first 5 s.
    static func parse(_ text: String, skipSeconds: Double = 5) -> BenchRun? {
        let lines = text.split(separator: "\n")
        guard let first = lines.first, first.hasPrefix("# wynix-bench v1 ") else { return nil }
        var all = lines.dropFirst().compactMap { Double($0) }.filter { $0 > 0 }
        let total = all.reduce(0, +) / 1000
        var skipped = 0.0
        while let f = all.first, skipped < skipSeconds * 1000 { skipped += f; all.removeFirst() }
        guard !all.isEmpty else { return nil }
        return BenchRun(header: String(first.dropFirst("# wynix-bench v1 ".count)), intervals: all, duration: total)
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

enum GameProcess {
    /// True when any process command line contains `marker` (e.g. `common\\Game`).
    static func isRunning(_ marker: String) -> Bool {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-axo", "command="]
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).contains(marker)
    }
}
