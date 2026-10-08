import SwiftUI

/// Edit a project's description by hand, or have Claude write a new one.
struct DescriptionEditor: View {
    let store: Store
    let project: String
    let original: String
    @State private var text = ""
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    private var describing: Bool { store.describing.contains(project) }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What this project is", text: $text, axis: .vertical)
                        .lineLimit(2...6)
                        .disabled(describing)
                } header: {
                    Text(project)
                } footer: {
                    Text("A description you write is kept: the daily `hangar describe` doesn't replace it.")
                }
                Section {
                    Button {
                        Task {
                            if let t = await store.regenerateDescription(project) {
                                text = t
                                dismiss()
                            } else {
                                error = store.error
                            }
                        }
                    } label: {
                        HStack {
                            Label("Regenerate with Claude", systemImage: "sparkles")
                            Spacer()
                            if describing { ProgressView() }
                        }
                    }
                    .disabled(describing || saving)
                    if !original.isEmpty {
                        Button("Remove description", role: .destructive) { save("") }
                            .disabled(describing || saving)
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(Theme.red) }
                }
            }
            .navigationTitle("Description")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") { save(trimmed) }
                            .bold()
                            .disabled(trimmed.isEmpty || trimmed == original || describing)
                    }
                }
            }
            .onAppear { text = original }
            .interactiveDismissDisabled(describing || saving)
        }
        .tint(Theme.accentSoft)
        .presentationDetents([.medium])
    }

    private func save(_ value: String) {
        saving = true
        Task {
            if await store.saveDescription(project, value) {
                dismiss()
            } else {
                error = store.error
            }
            saving = false
        }
    }
}
