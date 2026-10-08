import SwiftUI

/// Rename a project (its folder and session together) and edit its description.
struct ProjectEditor: View {
    let store: Store
    let project: String // path under ~/Dev, e.g. "todo-app" or "games/tetris"
    let original: String
    let running: Bool
    @State private var name = ""
    @State private var text = ""
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    private var currentName: String { (project as NSString).lastPathComponent }
    private var parent: String {
        let p = (project as NSString).deletingLastPathComponent
        return p.isEmpty ? "~/Dev/" : "~/Dev/\(p)/"
    }
    private var newName: String { name.trimmingCharacters(in: .whitespaces) }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var describing: Bool { store.describing.contains(project) }
    private var nameValid: Bool {
        !newName.isEmpty && newName.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil
    }
    private var nameTaken: Bool {
        newName != currentName && (store.overview?.projects.contains { $0.name == newName } ?? false)
    }
    private var changed: Bool { newName != currentName || trimmed != original }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 0) {
                        Text(parent).foregroundStyle(Theme.secondary)
                        TextField(currentName, text: $name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .font(.body.monospaced())
                } header: {
                    Text("Name")
                } footer: {
                    if !nameValid && !newName.isEmpty {
                        Text("Letters, digits, '-', '_' and '.' only.").foregroundStyle(Theme.amber)
                    } else if nameTaken {
                        Text("\(parent)\(newName) already exists.").foregroundStyle(Theme.amber)
                    } else if newName != currentName {
                        Text("Renames the folder and its session. " +
                             (running ? "The session restarts under the new name and continues its conversation. " : "") +
                             "Anything else that points at the old path (homebase, scripts) won't follow.")
                    }
                }

                Section {
                    TextField("What this project is", text: $text, axis: .vertical)
                        .lineLimit(2...6)
                        .disabled(describing)
                    Button {
                        Task {
                            do { text = try await store.regenerateDescription(project) } catch { self.error = error.localizedDescription }
                        }
                    } label: {
                        HStack {
                            Label("Regenerate with Claude", systemImage: "sparkles")
                            Spacer()
                            if describing { ProgressView() }
                        }
                    }
                    .disabled(describing || saving)
                } header: {
                    Text("Description")
                } footer: {
                    Text("A description you write is kept: the daily `hangar describe` doesn't replace it.")
                }

                if let error {
                    Section { Text(error).foregroundStyle(Theme.red) }
                }
            }
            .navigationTitle("Edit project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save", action: save)
                            .bold()
                            .disabled(!changed || !nameValid || nameTaken || describing)
                    }
                }
            }
            .onAppear {
                name = currentName
                text = original
            }
            .interactiveDismissDisabled(describing || saving)
        }
        .tint(Theme.accentSoft)
        .presentationDetents([.large])
    }

    private func save() {
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                var path = project
                if newName != currentName {
                    path = try await store.rename(project, to: newName)
                }
                if trimmed != original {
                    try await store.saveDescription(path, trimmed)
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
