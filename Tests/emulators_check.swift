// Self-check for emulator settings logic. Run: bash Tests/emulators_check.sh [--install]
import Foundation

@main struct Check {
    static func expect(_ ok: Bool, _ what: String) { if !ok { print("FAIL: \(what)"); exit(1) } }

    static func main() async {
        // JSON merge keeps user keys and turns the pipeline cache on.
        let user: [String: Any] = ["Vulkan": ["gpu_id": 1, "pipeline_cache_enabled": false], "GPU": ["full_screen": true]]
        let m = EmulatorConfig.merge(user, EmulatorConfig.shadPS4Patch)
        let vk = m["Vulkan"] as? [String: Any]
        expect(vk?["pipeline_cache_enabled"] as? Bool == true, "pipeline cache on")
        expect(vk?["gpu_id"] as? Int == 1, "merge keeps sibling keys")
        expect((m["GPU"] as? [String: Any])?["full_screen"] as? Bool == true, "merge keeps other sections")

        // INI edits.
        var ini = EmulatorConfig.setINI("", section: "version_manager", key: "versionSelected", value: "/a b/shadps4")
        expect(ini == "[version_manager]\nversionSelected=/a b/shadps4\n", "new ini")
        ini = EmulatorConfig.setINI("[general_settings]\nx=1\n\n[version_manager]\nversionSelected=old\n", section: "version_manager", key: "versionSelected", value: "new")
        expect(ini.contains("versionSelected=new") && !ini.contains("old") && ini.contains("x=1"), "replace key")
        ini = EmulatorConfig.setINI("[general_settings]\nx=1\n\n[other]\ny=2\n", section: "general_settings", key: "z", value: "3")
        expect(ini == "[general_settings]\nx=1\nz=3\n\n[other]\ny=2\n", "insert into existing section")
        expect(EmulatorConfig.getINI(ini, section: "other", key: "y") == "2", "get ini")
        expect(EmulatorConfig.getINI(ini, section: "other", key: "x") == nil, "get ini is per section")

        expect(EmulatorConfig.isWynixCore("/v/WYNIX 0.20.0/shadps4", versionsDir: "/v"), "own core detected")
        expect(!EmulatorConfig.isWynixCore("/v/Pre-release-x/shadps4", versionsDir: "/v"), "user core left alone")

        // versions.json entry added once.
        let once = EmulatorConfig.addVersion([], name: "n", path: "/p", date: "d")
        expect(EmulatorConfig.addVersion(once, name: "n", path: "/p", date: "d").count == 1, "no duplicate version")

        // Every download is pinned to a SHA-256 over HTTPS.
        for e in Emulator.all { for d in e.downloads {
            expect(d.url.hasPrefix("https://") && d.sha256.count == 64, "\(e.id) download pinned")
        } }

        guard CommandLine.arguments.contains("--install") else { print("PASS: emulator logic"); return }
        // Real download into a throwaway HOME (network, ~250 MB).
        let home = URL(fileURLWithPath: CommandLine.arguments.last!)
        Emulator.home = home
        for e in Emulator.all {
            do { try EmulatorStore.installBlocking(e) } catch { expect(false, "\(e.id) install: \(error)") }
            expect(e.installedVersion == e.version, "\(e.id) version recorded")
            expect(FileManager.default.fileExists(atPath: e.appURL.appendingPathComponent("Contents/Info.plist").path), "\(e.id) app present")
        }
        let ps4 = Emulator.all.first { $0.id == "ps4" }!
        // Update path: an older WYNIX core is selected and the user turned the cache off.
        let fm = FileManager.default
        let versions = ps4.coreDir.deletingLastPathComponent()
        let old = versions.appendingPathComponent("WYNIX 0.20.0")
        try! fm.createDirectory(at: old, withIntermediateDirectories: true)
        try! Data().write(to: old.appendingPathComponent("shadps4"))
        let iniURL = Emulator.shadLauncherDir.appendingPathComponent("qt_ui.ini")
        try! EmulatorConfig.setINI("", section: "version_manager", key: "versionSelected", value: old.appendingPathComponent("shadps4").path).write(to: iniURL, atomically: true, encoding: .utf8)
        let cfgURL = Emulator.shadUserDir.appendingPathComponent("config.json")
        try! #"{"Vulkan":{"pipeline_cache_enabled":false}}"#.write(to: cfgURL, atomically: true, encoding: .utf8)
        do { try EmulatorStore.installBlocking(ps4) } catch { expect(false, "ps4 reinstall: \(error)") }
        expect(!fm.fileExists(atPath: old.path), "old WYNIX core removed on update")
        let cfg = try! String(contentsOf: cfgURL, encoding: .utf8)
        expect(cfg.contains("false"), "user's own setting kept after first install")
        let ini2 = try! String(contentsOf: Emulator.shadLauncherDir.appendingPathComponent("qt_ui.ini"), encoding: .utf8)
        expect(EmulatorConfig.getINI(ini2, section: "version_manager", key: "versionSelected") == ps4.coreDir.appendingPathComponent("shadps4").path, "core selected")
        await MainActor.run {
            let store = EmulatorStore()
            for e in Emulator.all { store.uninstall(e) }
            expect(store.installed.isEmpty, "uninstall")
        }
        expect(FileManager.default.fileExists(atPath: Emulator.shadUserDir.appendingPathComponent("config.json").path), "settings kept on uninstall")
        print("PASS: emulator install/uninstall")
    }
}
