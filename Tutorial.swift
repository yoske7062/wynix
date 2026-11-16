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
            TutorialStep(icon: "bag.fill", title: "Game Stores",
                         text: "Home lists Steam, Epic, GOG, Battle.net, EA and Ubisoft. Press Set Up Steam once, then Open. Sign in with your normal account.",
                         section: .management),
            TutorialStep(icon: "gamecontroller.fill", title: "Games",
                         text: "Everything you install shows up here. Press Play. That's it.",
                         section: .games),
            TutorialStep(icon: "shippingbox.fill", title: "Bottles",
                         text: "A bottle is a separate Windows space for a set of games or apps. Open one to turn on Boost, the FPS counter or Mac keyboard shortcuts.",
                         section: steamBottle.map { .bottle($0) } ?? .management),
            TutorialStep(icon: "plus.app.fill", title: "Install from File",
                         text: "Got any Windows .exe or .msi? Games, tools, mod managers, old apps. Install it from the sidebar and it opens like a Mac app.",
                         section: nil),
            TutorialStep(icon: "bolt.fill", title: "Optimize and New Bottle",
                         text: "Optimize applies the best settings for you in one click. New Bottle makes a separate setup if a game needs different settings.",
                         section: nil),
            TutorialStep(icon: "gearshape.fill", title: "You're set",
                         text: "Games with kernel anti-cheat won't run, everything else is worth a try. You can replay this tour from Settings.",
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
