// Checks version.json decodes and the "newer build" rule. Run: swift Tests/updater_check.swift
import Foundation
struct Release: Decodable { let version: String; let build: Int; let url: URL; let notes: String? }
let data = try! Data(contentsOf: URL(fileURLWithPath: "site/version.json"))
let r = try! JSONDecoder().decode(Release.self, from: data)
let plist = NSDictionary(contentsOfFile: "Info.plist")!
let current = Int(plist["CFBundleVersion"] as! String)!
assert(r.build >= current, "version.json build is older than the app")
assert(!(r.build > current), "feed must not offer an update to the build it describes")
assert(14 < r.build, "older builds must see the update")
assert(r.url.scheme == "https" && r.url.host == "wynix.app", "feed url must pass Updater.isTrusted or the app hides the update")
print("updater ok: feed \(r.version) (\(r.build)), app \(current)")
