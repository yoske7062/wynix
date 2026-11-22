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
                         text: "Play Windows games on your Mac. You don't need Windows or anything else. This tour takes a minute.",
                         section: .management),
            TutorialStep(icon: "bag.fill", title: "1. Add a store",
                         text: "On Home, pick a store: Steam, Epic, GOG, EA, Battle.net or Ubisoft. WYNIX installs it for you. Any other Windows app works too.",
                         section: .management),
            TutorialStep(icon: "person.crop.circle.fill", title: "2. Sign in and get a game",
                         text: "The store opens in its own window. Sign in with your normal account and install a game, like on a PC.",
                         section: .management),
            TutorialStep(icon: "gamecontroller.fill", title: "3. Press Play",
                         text: "Your games show up in Games. Press Play. WYNIX picks the best settings for each game by itself.",
                         section: .games),
            TutorialStep(icon: "shippingbox.fill", title: "Windows spaces",
                         text: "Each store lives in its own Windows space, so one broken game can't break the others. Open one to show FPS while you play or to install other Windows programs.",
                         section: steamBottle.map { .bottle($0) } ?? .management),
            TutorialStep(icon: "gearshape.fill", title: "You're set",
                         text: "Games with kernel anti-cheat (many online shooters) won't run. Everything else is worth a try. You can see this tour again in Settings.",
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
                    .buttonStyle(.borderedProminent).tint(.wynixFill)
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
