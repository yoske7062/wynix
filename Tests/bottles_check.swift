// Self-check for Windows binary parsing. Run: bash Tests/bottles_check.sh
import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32) { self.init(white: Double(hex & 0xFF) / 255) }
    static let steamyAccent = Color.blue, onSteamyAccent = Color.white
}
extension ShapeStyle where Self == Color { static var steamyAccent: Color { .blue } }
extension Font { static func app(_ style: Font.TextStyle) -> Font { .system(style) } }

enum L10n { static func string(_ k: String) -> String { k } }
@MainActor final class InstallerModel { static func taskEnvironment() -> [String: String] { [:] } }

@main struct Check {
    static func main() {
        // Pure regression checks (close-everything polling).
        var n = 0
        precondition(BottleStore.waitUntil(timeout: 1, step: 0.01) { n += 1; return n >= 3 })
        precondition(!BottleStore.waitUntil(timeout: 0.05, step: 0.01) { false })
        precondition(BottleStore.waitUntil(timeout: 0, step: 0.01) { true })
        let app = (try? String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)) ?? ""
        precondition(app.contains("pendingPlay = game") && app.contains("self?.play(next)"), "queued play missing")
        let path = CommandLine.arguments[1]
        guard FileManager.default.fileExists(atPath: path) else { print("SKIP: no bottle at \(path)"); return }
        let root = URL(fileURLWithPath: path)
        let bottle = Bottle(url: root)
        assert(bottle.windowsPath(bottle.driveC.appendingPathComponent("Program Files/x.exe")) == "C:\\Program Files\\x.exe")
        assert(bottle.unixURL(windowsPath: "C:\\a\\b.exe")?.path == bottle.driveC.appendingPathComponent("a/b.exe").path)
        let programs = BottleStore.findPrograms(in: bottle)
        for p in programs { print(p.name, p.iconData.map { "icon \($0.count) bytes" } ?? "NO ICON") }
        print("windows:", RegistryFile.windowsVersion(bottle))
        print("dll overrides:", RegistryFile.section(bottle.prefix.appendingPathComponent("user.reg"), "Software\\Wine\\DllOverrides"))
        assert(!programs.isEmpty, "expected Start Menu programs")
        assert(programs.allSatisfy { $0.iconData.flatMap(NSImage.init(data:)) != nil }, "expected decodable icons")
        print("PASS")
    }
}
