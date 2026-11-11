import SwiftUI

/// Rename a project (its folder and session together) and edit its description.
struct ProjectEditor: View {
    let store: Store
    let running: Bool
    // Both change as parts of a save succeed, so saving again after an error picks up from there.
    @State private var project: String // path under ~/Dev, e.g. "todo-app" or "games/tetris"
    @State private var original: String
    @State private var name = ""
    @State private var text = ""
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(store: Store, project: String, original: String, running: Bool) {
        self.store = store
        self.running = running
        _project = State(initialValue: project)
        _original = State(initialValue: original)
    }

    private var currentName: String { (project as NSString).lastPathComponent }
    private var parent: String {
        let p = (project as NSString).deletingLastPathComponent
        return p.isEmpty ? "~/Dev/" : "~/Dev/\(p)/"
    }
    private var newName: String { name.trimmingCharacters(in: .whitespaces) }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var describing: Bool { store.describing.contains(project) }
    private var nameValid: Bool { ProjectName.isValid(newName) }
    // Not while saving: the list refreshes during a rename and already has the folder's new name.
    // The whole path is compared (the project may be in a subfolder), without case, as the Mac's
    // file system does; changing only the case of the name is fine.
    private var nameTaken: Bool {
        let folder = (project as NSString).deletingLastPathComponent
        let target = (folder.isEmpty ? newName : folder + "/" + newName).lowercased()
        return !saving && target != project.lowercased()
            && (store.overview?.projects.contains { $0.name.lowercased() == target } ?? false)
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
                            do {
                                // Saved on the Mac already, as Claude's: not something Save has to keep.
                                text = try await store.regenerateDescription(project)
                                original = text
                                error = nil
                            } catch {
                                self.error = error.localizedDescription
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
                } header: {
                    Text("Description")
                } footer: {
                    Text("A description you write is kept: the daily `hangar describe` doesn't replace it. One from Claude is saved as soon as it is written.")
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
                if newName != currentName {
                    project = try await store.rename(project, to: newName)
                    name = currentName
                }
                if trimmed != original {
                    try await store.saveDescription(project, trimmed)
                    original = trimmed
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
