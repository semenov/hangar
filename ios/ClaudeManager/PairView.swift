import SwiftUI
import VisionKit

/// Pairs with a Mac: scan the code `hangar pair` shows, paste its link, or arrive with one
/// (the system camera opens hangar:// links in the app).
struct PairView: View {
    let store: Store
    var link: PairLink? = nil
    @State private var pasted = ""
    @State private var pairing: PairLink?
    @State private var error: String?
    @State private var done = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let pairing {
                    progress(pairing)
                } else {
                    if DataScannerViewController.isSupported {
                        QRScanner { code in
                            if let l = PairLink(code) { start(l) }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.1)))
                        .frame(maxHeight: 360)
                        Text("Point the camera at the code `hangar pair` shows on the Mac.")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondary)
                            .multilineTextAlignment(.center)
                    }
                    HStack {
                        TextField("…or paste the hangar://pair link", text: $pasted)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.footnote.monospaced())
                            .padding(12)
                            .background(Theme.card, in: .rect(cornerRadius: 12))
                        Button("Pair") { if let l = PairLink(pasted) { start(l) } else { error = "That isn't a hangar://pair link." } }
                            .disabled(pasted.isEmpty)
                    }
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(Theme.red).multilineTextAlignment(.center)
                }
                Spacer()
            }
            .padding(20)
            .background(Background())
            .navigationTitle("Add a Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear { if let link, pairing == nil { start(link) } }
        }
        .tint(Theme.accentSoft)
        .preferredColorScheme(.dark)
    }

    private func progress(_ l: PairLink) -> some View {
        VStack(spacing: 14) {
            HangarMark().fill(Theme.accent).frame(width: 56, height: 56).padding(.top, 40)
            if done {
                Label("Paired with \(l.name)", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(Theme.accent)
            } else if error == nil {
                ProgressView()
                Text("Connecting to \(l.name)…").foregroundStyle(Theme.text)
            } else {
                Button("Try again") { start(l) }
            }
        }
    }

    private func start(_ l: PairLink) {
        guard pairing == nil || error != nil else { return }
        pairing = l
        error = nil
        Task {
            do {
                try await store.pair(l)
                done = true
                try? await Task.sleep(for: .seconds(0.8))
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// VisionKit's live scanner, reporting QR payloads.
struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                           qualityLevel: .balanced, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let b) in items {
                if let s = b.payloadStringValue { onCode(s) }
            }
        }
    }
}
