// Self-check for Windows binary parsing. Run: bash Tests/bottles_check.sh
import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32) { self.init(white: Double(hex & 0xFF) / 255) }
    static let steamyAccent = Color.blue, onSteamyAccent = Color.white
}
extension ShapeStyle where Self == Color { static var steamyAccent: Color { .blue } }
extension Font { static func app(_ style: Font.TextStyle) -> Font { .system(style) } }

enum L10n { static func string(_ k: String) -> String { k }; static func format(_ k: String, _ a: CVarArg...) -> String { k } }
@MainActor final class InstallerModel { static func taskEnvironment() -> [String: String] { [:] } }

@main struct Check {
    static func main() {
        // Pure regression checks (close-everything polling).
        var n = 0
        precondition(BottleStore.waitUntil(timeout: 1, step: 0.01) { n += 1; return n >= 3 })
        precondition(!BottleStore.waitUntil(timeout: 0.05, step: 0.01) { false })
        precondition(BottleStore.waitUntil(timeout: 0, step: 0.01) { true })
        let same = GameModeSafety.stillSame(["10:5", "11:6", "12:7", "bad"]) { [10: 5, 11: 99][$0] }
        precondition(same == [10], "pid reuse guard")
        precondition(GameModeSafety.startTime(getpid()) != nil && GameModeSafety.startTime(getpid()) == GameModeSafety.startTime(getpid()))
        let modes: [(w: Int, h: Int, hz: Double)] = [(2560, 1440, 120), (2560, 1440, 60), (1920, 1080, 60), (2560, 1440, 59.94)]
        precondition(GameModeSafety.mode60Index(current: (2560, 1440, 120), modes: modes) == 1)
        precondition(GameModeSafety.mode60Index(current: (2560, 1440, 60), modes: modes) == nil)
        precondition(GameModeSafety.mode60Index(current: (3000, 2000, 120), modes: modes) == nil)
        // Benchmark stats: 100 frames of 10 ms then 100 of 20 ms; first 5 s dropped (none here: skip 0 keeps all).
        let text = "# wynix-bench v1 in=1280x720 out=1920x1080 upscale=1 d3dmetal=4.0b3\n" + (Array(repeating: "10.0", count: 100) + Array(repeating: "20.0", count: 100)).joined(separator: "\n") + "\n"
        let b = BenchRun.parse(text, skipSeconds: 0)!
        precondition(abs(b.avgFPS - 200 * 1000 / 3000.0) < 0.01 && abs(b.lowFPS - 50) < 0.01 && b.medianMs == 20, "bench stats")
        precondition(b.summary.contains("66.7 avg FPS, 50.0 1% low") && b.summary.contains("D3DMetal 4.0b3, Boost on (1280x720 -> 1920x1080)") && b.summary.contains("0 min 03 s"), b.summary)
        // 5 s skip: 500 x 10 ms (= 5 s) dropped, the 100 x 20 ms remain.
        let skipped = BenchRun.parse("# wynix-bench v1 upscale=0\n" + (Array(repeating: "10", count: 500) + Array(repeating: "20", count: 100)).joined(separator: "\n"))!
        precondition(skipped.frames == 100 && skipped.medianMs == 20 && skipped.summary.contains("Boost off"), "bench skip")
        precondition(BenchRun.parse("nope\n1\n2") == nil && BenchRun.parse("# wynix-bench v1 x\n10\n") == nil)
        let app = (try? String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)) ?? ""
        let src = (try? String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8)) ?? ""
        precondition(src.contains("completion?(-1, \"\")"), "launcher missing-bottle guard must call completion")
        precondition(src.contains("if list != bottles"), "reload must not republish an unchanged list")
        precondition(app.contains("pendingPlay = game") && app.contains("self?.play(next, renderer"), "queued play missing")
        let setup = (try? String(contentsOfFile: CommandLine.arguments[2].replacingOccurrences(of: "MacSteamSetupApp.swift", with: "Resources/setup.sh"), encoding: .utf8)) ?? ""
        precondition(app.contains("watchdog") && app.contains("error.taskTimedOut"), "run() watchdog missing")
        precondition(!app.contains("if finished.terminationStatus == 0 { self?.play(next) }"), "queued play must run after failures too")
        precondition(setup.contains("with_timeout 5 /usr/sbin/lsof") && setup.contains("with_timeout 20 \"$WRAPPER"), "play path must bound lsof and wine reg")
        let opt = src.components(separatedBy: "func optimizeForGaming")[1].components(separatedBy: "func optimizeAll")[0]
        precondition(opt.contains("EmulateModeset"), "Optimize must set EmulateModeset (display-mode fix)")
        let prog = WinProgram(name: "setup.exe", path: "/x/setup.exe")
        precondition(BottleStore.displayName(prog, overrides: [:]) == "setup.exe", "display name default")
        precondition(BottleStore.displayName(prog, overrides: ["WynixDisplayNames": ["/x/setup.exe": " My Game "]]) == "My Game", "display name override")
        precondition(BottleStore.displayName(prog, overrides: ["WynixDisplayNames": ["/y": "Z", "/x/setup.exe": " "]]) == "setup.exe", "blank override ignored")
        let locked = LockedData()
        DispatchQueue.concurrentPerform(iterations: 50) { _ in locked.append(Data(count: 10)) }
        precondition(locked.data.count == 500, "LockedData lost bytes")
        let drainable = LockedData()
        drainable.append(Data("stale".utf8))
        precondition(String(data: drainable.drain(), encoding: .utf8) == "stale" && drainable.data.isEmpty,
                     "LockedData drain must be atomic")
        let store = (try? String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8)) ?? ""
        precondition(store.contains(".wynix/\\(name)/wynix_upscale.dylib") && !store.contains("space in its folder path"), "bottles with a space in their path must get the helper dylib outside the bottle")
        precondition(store.contains("guard bottleExists(bottle) else { completion?(); return }") && store.contains("fileExists(atPath: bottle.url.path) else { return false }"), "optimize/dxmt.conf must not recreate a deleted bottle")
        precondition(store.contains("readabilityHandler") && store.contains("is no longer in the Sikarugir folder"), "spawn drain / missing-bottle guard missing")
        // D3DMetal 3.0 -> 4 -> 3.0 swap on a fake renderer dir.
        do {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("wynix-d3dm-\(UUID().uuidString)")
            func make(_ dir: URL, _ v: String) {
                let r = dir.appendingPathComponent("external/D3DMetal.framework/Versions/A/Resources")
                try! fm.createDirectory(at: r, withIntermediateDirectories: true)
                try! (["CFBundleShortVersionString": v] as NSDictionary).write(to: r.appendingPathComponent("Info.plist"))
            }
            let renderer = root.appendingPathComponent("renderer"), staged = root.appendingPathComponent("staged")
            make(renderer.appendingPathComponent("d3dmetal"), "3.0"); make(staged, "4.0b3")
            for (d, e) in [("x86_64-unix", "so"), ("x86_64-windows", "dll")] {
                let w = staged.appendingPathComponent("wine/\(d)")
                try! fm.createDirectory(at: w, withIntermediateDirectories: true)
                try! Data().write(to: w.appendingPathComponent("nvngx-on-metalfx.\(e)"))
            }
            let ver = { D3DMetalSwap.version(renderer: renderer) }
            try! D3DMetalSwap.swap(renderer: renderer, staged: staged, to4: true)
            precondition(ver() == "4.0b3" && fm.fileExists(atPath: renderer.appendingPathComponent("d3dmetal-3.0").path), "swap to 4 keeps backup")
            precondition(fm.fileExists(atPath: renderer.appendingPathComponent("d3dmetal/wine/x86_64-unix/nvngx.so").path)
                && fm.fileExists(atPath: renderer.appendingPathComponent("d3dmetal/wine/x86_64-windows/nvngx.dll").path)
                && fm.fileExists(atPath: staged.appendingPathComponent("wine/x86_64-unix/nvngx-on-metalfx.so").path), "nvngx renamed on the copy only")
            try! D3DMetalSwap.swap(renderer: renderer, staged: staged, to4: true)  // idempotent
            try! D3DMetalSwap.swap(renderer: renderer, staged: staged, to4: false)
            precondition(ver() == "3.0" && !fm.fileExists(atPath: renderer.appendingPathComponent("d3dmetal-3.0").path), "swap back to 3.0")
            try! D3DMetalSwap.swap(renderer: renderer, staged: staged, to4: true)
            precondition(ver() == "4.0b3", "second swap to 4")
            try? fm.removeItem(at: root)
        }
        // D3DMetal download verification: pinned hash accepts only matching bytes.
        do {
            let f = FileManager.default.temporaryDirectory.appendingPathComponent("wynix-sha-\(UUID().uuidString)")
            try! Data("abc".utf8).write(to: f)
            let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
            precondition(D3DMetalSwap.verify(f, expected: abc), "sha256 match")
            precondition(!D3DMetalSwap.verify(f, expected: String(abc.reversed())), "sha256 mismatch rejected")
            precondition(!D3DMetalSwap.verify(f), "wrong file does not match pinned hash")
            precondition(D3DMetalSwap.expectedSHA256.count == 64, "pinned hash shape")
            try? FileManager.default.removeItem(at: f)
        }
        // Per-game DirectX detector on fake folders.
        let fm = FileManager.default
        func fake(_ files: [String: String]) -> URL {
            let d = fm.temporaryDirectory.appendingPathComponent("wynix-api-\(UUID().uuidString)")
            for (name, text) in files {
                let f = d.appendingPathComponent(name)
                try! fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
                try! Data(text.utf8).write(to: f)
            }
            return d
        }
        precondition(GameAPI.detect(folder: fake(["re_config.ini": "[x]\r\nTargetPlatform = DirectX12\r\n", "g.exe": "d3d11.dll"])) == .dx12, "RE Engine dx12")
        precondition(GameAPI.detect(folder: fake(["re_config.ini": "TargetPlatform=DirectX11\n", "g.exe": "d3d12.dll"])) == .dx11, "RE Engine dx11")
        precondition(GameAPI.detect(folder: fake(["Game_Data/boot.config": "x=1\n", "UnityPlayer.dll": "d3d12.dll"])) == .dx11, "Unity dx11")
        precondition(GameAPI.detect(folder: fake(["Game_Data/boot.config": "-force-d3d12\n"])) == .dx12, "Unity forced dx12")
        precondition(GameAPI.detect(folder: fake(["g.exe": "xxD3D12.dllxx d3d11.dll"])) == .dx12, "exe dx12")
        precondition(GameAPI.detect(folder: fake(["g.exe": "d3d11.dll"])) == .dx11, "exe dx11")
        precondition(GameAPI.detect(folder: fake(["a.dll": "d3d12.dll"])) == .unknown, "dlls ignored")
        let empty = fm.temporaryDirectory.appendingPathComponent("wynix-api-empty-\(UUID().uuidString)")
        try! fm.createDirectory(at: empty, withIntermediateDirectories: true)
        precondition(GameAPI.detect(folder: empty) == .unknown, "empty unknown")
        let playBlock = setup.components(separatedBy: "== \"play\" ]]").last?.components(separatedBy: "== \"create-shortcut\" ]]").first ?? ""
        precondition(playBlock.contains("steam_is_running") && !playBlock.contains("steam_stalled_cleanup_failed"), "stalled wrapper branch must not stop Steam")
        precondition(playBlock.contains("game_may_be_running") && setup.contains("rm -f \"$renderer_mark\""), "renderer switch guard / marker clear missing")
        precondition(app.contains("applyAndPlay") && !app.contains("Optimize before playing?"), "auto profile prompt missing")
        precondition(!app.contains("Label(\"DXMT\"") && !app.contains("Boost is on: in each"), "games toolbar DXMT control/banner must be gone")
        precondition(src.contains("\"DirectX 11 compatibility mode\"") && src.contains("run worse with the default."), "bottle DXMT wording")
        precondition(app.contains("watchGameEnd") && app.contains("6 * 3600") && app.contains("5_000_000_000") && app.contains("benchGame = nil"), "benchmark must follow game exit (5 s poll, 6 h cap, show once)")
        precondition(GameProcess.isRunning("bottles_check") && !GameProcess.isRunning("zz-no-such-process-\(getpid())-x"), "GameProcess.isRunning")
        // Wine 11 engine variants: a link into any path under an engine dir matches that engine.
        let eroot = fm.temporaryDirectory.appendingPathComponent("wynix-eng-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: eroot) }
        func put(_ rel: String, _ text: String = "x", exec: Bool = false) {
            let u = eroot.appendingPathComponent(rel)
            try! fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! text.write(to: u, atomically: true, encoding: .utf8)
            if exec { try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path) }
        }
        let e11 = BottleStore.Engine(id: "wine-11.19", title: "Wine 11 (beta)", url: eroot.appendingPathComponent("Engines/wine-11.19/wine"))
        let eOld = BottleStore.Engine(id: "steamy-wine-11.0", title: "old", url: eroot.appendingPathComponent("Engines/steamy-wine-11.0/wine"))
        let ee = [eOld, e11]
        let e11dir = eroot.appendingPathComponent("Engines/wine-11.19").path
        precondition(BottleStore.matchEngine(link: e11dir + "/wine", in: ee) == e11, "engine own wine")
        precondition(BottleStore.matchEngine(link: e11dir + "/variants/dxmt/wine", in: ee) == e11, "dxmt variant")
        precondition(BottleStore.matchEngine(link: e11dir + "/variants/d3dmetal/wine/", in: ee) == e11, "d3dmetal variant")
        precondition(BottleStore.matchEngine(link: e11dir + "-x/wine", in: ee) == nil, "sibling dir with same prefix")
        precondition(BottleStore.matchEngine(link: "/Volumes/SSD/wynix-tmp/w-dxmt", in: ee) == nil, "foreign path")
        // setEngine target: variant for the renderer when the engine has variants, else its wine folder.
        put("Engines/wine-11.19/variants/dxmt/wine/bin/wine", exec: true)
        put("Engines/wine-11.19/variants/d3dmetal/wine/bin/wine", exec: true)
        precondition(BottleStore.linkTarget(for: e11, dxmt: true)?.path == e11dir + "/variants/dxmt/wine", "dxmt target")
        precondition(BottleStore.linkTarget(for: e11, dxmt: false)?.path == e11dir + "/variants/d3dmetal/wine", "d3dmetal target")
        precondition(BottleStore.linkTarget(for: eOld, dxmt: true)?.path == eOld.url?.path, "no variants: engine wine")
        precondition(BottleStore.linkTarget(for: BottleStore.bundledEngine, dxmt: true) == nil, "bundled has no link")
        // buildEngineVariants with fake files: each variant gets its renderer folder of the bottle.
        let bdir = eroot.appendingPathComponent("build/wine-11.19")
        func putB(_ rel: String, _ text: String) {
            let u = bdir.appendingPathComponent(rel)
            try! fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! text.write(to: u, atomically: true, encoding: .utf8)
        }
        putB("wine/bin/wine", "w"); try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bdir.appendingPathComponent("wine/bin/wine").path)
        putB("wine/lib/wine/x86_64-windows/d3d11.dll", "stock"); putB("wine/lib/wine/x86_64-unix/winemetal.so", "stock-so")
        putB("wine/lib/wine/i386-windows/d3d11.dll", "stock32")
        let rend = eroot.appendingPathComponent("build/renderer")
        for (rel, t) in [("dxmt/wine/x86_64-windows/d3d11.dll", "dxmt64"), ("dxmt/wine/x86_64-unix/winemetal.so", "dxmt-so"),
                         ("d3dmetal/wine/x86_64-windows/d3d12.dll", "d3dm"), ("d3dmetal/wine/x86_64-unix/libd3dshared.so", "u"), ("d3dmetal/external/libd3dshared.dylib", "dylib")] {
            let u = rend.appendingPathComponent(rel)
            try! fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! t.write(to: u, atomically: true, encoding: .utf8)
        }
        try! BottleStore.buildEngineVariants(engineDir: bdir, renderer: rend)
        func read(_ rel: String) -> String? { try? String(contentsOf: bdir.appendingPathComponent(rel), encoding: .utf8) }
        precondition(read("variants/dxmt/wine/lib/wine/x86_64-windows/d3d11.dll") == "dxmt64" && read("variants/dxmt/wine/lib/wine/x86_64-unix/winemetal.so") == "dxmt-so", "dxmt files")
        precondition(read("variants/d3dmetal/wine/lib/wine/x86_64-unix/winemetal.so") == "stock-so" && read("variants/d3dmetal/wine/lib/wine/x86_64-windows/d3d11.dll") == "stock", "variants isolated")
        precondition(read("variants/d3dmetal/wine/lib/wine/x86_64-windows/d3d12.dll") == "d3dm" && read("variants/d3dmetal/wine/lib/external/libd3dshared.dylib") == "dylib", "d3dmetal files")
        precondition(read("wine/lib/wine/x86_64-windows/d3d11.dll") == "stock", "pristine engine untouched")
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
