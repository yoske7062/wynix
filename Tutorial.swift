import SwiftUI

/// First-run guided tour. Shown once (`tutorialDone`), skippable, replayable from Settings.
/// Each step moves the app to the screen it talks about, so the user sees the real thing.
struct TutorialStep {
    let icon: String
    let title: String
    let text: String
    let section: AppSection?   // nil = stay where we are
}

enum Tutorial {
    static let doneKey = "tutorialDone"

    static func steps(steamBottle: String?) -> [TutorialStep] {
        [
            TutorialStep(icon: "hand.wave.fill", title: "Welcome to WYNIX",
                         text: "Run Windows games and apps on your Mac. No Windows license, no virtual machine. This quick tour takes a minute.",
                         section: .management),
            TutorialStep(icon: "bag.fill", title: "Set up Steam once",
                         text: "Home lists Steam, Epic, GOG, Battle.net, EA and Ubisoft. Press Set Up Steam once and sign in with your normal account. WYNIX also starts Steam quietly in the background so games open faster (you can turn that off in Settings).",
                         section: .management),
            TutorialStep(icon: "gamecontroller.fill", title: "Press Play",
                         text: "Everything you install shows up in Games. Press Play. WYNIX detects DirectX 11 or 12 and shows \"Recommended: ...\" with Apply and Play or Play without changes. You never pick graphics modes yourself.",
                         section: .games),
            TutorialStep(icon: "sparkles", title: "Boost (MetalFX)",
                         text: "In the game, pick a lower resolution with your screen's shape (1280×720 or 1600×900) and MetalFX sharpens it up to 1080p. DirectX 12 games are capped at 60 FPS so fanless Macs stay cool. D3DMetal 4 downloads by itself; 3.0 stays as a compatibility option.",
                         section: nil),
            TutorialStep(icon: "shippingbox.fill", title: "Bottles and FPS",
                         text: "A bottle is a separate Windows space for a set of games or apps. Open one to turn on Show FPS or advanced stats in game, or Record performance: play, close the game and get a card with average FPS and 1% low (last 10 runs are kept).",
                         section: steamBottle.map { .bottle($0) } ?? .management),
            TutorialStep(icon: "plus.app.fill", title: "Install Software",
                         text: "Got a Windows .exe or .msi? Drop it into the Install Software window and pick a bottle. It opens like a Mac app. Right click any program tile and choose Rename... to give it your own name.",
                         section: nil),
            TutorialStep(icon: "gearshape.fill", title: "You're set",
                         text: "Games with kernel anti-cheat won't run, everything else is worth a try. New Bottle makes a separate setup if a game needs different settings. You can replay this tour from Settings.",
                         section: nil),
        ]
    }
}

struct TutorialOverlay: View {
    let steps: [TutorialStep]
    @Binding var selection: AppSection?
    let finish: () -> Void
    @State private var index = 0

    var body: some View {
        let step = steps[index]
        ZStack(alignment: .bottomTrailing) {
            Color.black.opacity(0.25).ignoresSafeArea().allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: step.icon).font(.app(.title2)).foregroundStyle(Color.steamyAccent)
                    Text(step.title).font(.app(.title3)).bold()
                    Spacer()
                    Text("\(index + 1) of \(steps.count)").font(.app(.caption)).foregroundStyle(.secondary)
                }
                Text(step.text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Skip tour", action: finish).buttonStyle(.plain).foregroundStyle(.secondary)
                    Spacer()
                    if index > 0 { Button("Back") { go(index - 1) } }
                    Button(index == steps.count - 1 ? "Start playing" : "Next") {
                        index == steps.count - 1 ? finish() : go(index + 1)
                    }
                    .buttonStyle(.borderedProminent).tint(.steamyAccent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 380)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 24)
            .padding(24)
        }
        .onAppear { go(0) }
    }

    private func go(_ i: Int) {
        withAnimation(.snappy) {
            index = i
            if let s = steps[i].section { selection = s }
        }
    }
}
