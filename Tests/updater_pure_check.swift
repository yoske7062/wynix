import Foundation

@main
struct UpdaterPureCheck {
    static func main() {
        precondition(Updater.isNewerBuild(28, than: 27), "higher build must be newer")
        precondition(!Updater.isNewerBuild(27, than: 27), "equal build must not be newer")
        precondition(!Updater.isNewerBuild(26, than: 27), "lower build must not be newer")

        precondition(Updater.isTrusted(URL(string: "https://wynix.app/WYNIX.dmg")!), "trusted HTTPS download")
        precondition(!Updater.isTrusted(URL(string: "http://wynix.app/WYNIX.dmg")!), "HTTP download must be rejected")
        precondition(!Updater.isTrusted(URL(string: "https://example.com/WYNIX.dmg")!), "foreign host must be rejected")
        precondition(!Updater.isTrusted(URL(string: "https://user@wynix.app/WYNIX.dmg")!), "embedded credentials must be rejected")
        precondition(!Updater.isTrusted(URL(string: "https://wynix.app:8443/WYNIX.dmg")!), "custom port must be rejected")

        print("updater pure helper ok")
    }
}
