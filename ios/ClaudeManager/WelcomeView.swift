import SwiftUI
import UIKit

/// First run: how to set up the Mac, then pair.
struct WelcomeView: View {
    let store: Store
    @State private var showPair = false
    @State private var copied: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    HangarMark().fill(Theme.accent).frame(width: 52, height: 52)
                    Text("Hangar")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Text("Start, stop and open the Claude Code sessions on your Mac, from here.")
                        .foregroundStyle(Theme.secondary)
                }
                .padding(.top, 40)

                Card {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("ON YOUR MAC").font(.caption.weight(.semibold)).tracking(1.5).foregroundStyle(Theme.secondary)
                        stepRow(1, "Install hangar", command: "brew install semenov/tap/hangar")
                        stepRow(2, "Set it up: it checks Claude Code, starts in the background and shows a code",
                                command: "hangar setup")
                        stepRow(3, "Scan the code with the iPhone camera, or here", command: nil)
                    }
                }

                Button { showPair = true } label: {
                    Label("Scan the code", systemImage: "qrcode.viewfinder")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.accent, in: .rect(cornerRadius: 16, style: .continuous))
                        .foregroundStyle(Theme.bgBottom)
                }

                Button { store.startDemo() } label: {
                    Text("Try the demo first").frame(maxWidth: .infinity)
                }
                .foregroundStyle(Theme.accentSoft)

                Text("Needs Claude Code on the Mac, signed in with a Pro, Max, Team or Enterprise plan. The Mac and the app connect through an end-to-end encrypted relay; the Mac opens no ports.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 40)
        }
        .background(Background())
        .sheet(isPresented: $showPair) { PairView(store: store) }
    }

    private func stepRow(_ n: Int, _ text: String, command: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .frame(width: 26, height: 26)
                .background(Theme.accent.opacity(0.18), in: Circle())
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 8) {
                Text(text).foregroundStyle(Theme.text)
                if let command {
                    Button {
                        UIPasteboard.general.string = command
                        copied = command
                    } label: {
                        HStack {
                            Text(command).font(.callout.monospaced()).foregroundStyle(Theme.text)
                            Spacer()
                            Image(systemName: copied == command ? "checkmark" : "doc.on.doc")
                                .foregroundStyle(Theme.accentSoft)
                        }
                        .padding(10)
                        .background(Color.black.opacity(0.25), in: .rect(cornerRadius: 10))
                    }
                }
            }
        }
    }
}
