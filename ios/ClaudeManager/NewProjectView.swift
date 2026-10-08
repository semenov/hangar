import SwiftUI

/// Creates ~/Dev/<name> and starts a session in it.
struct NewProjectView: View {
    let store: Store
    let onStarted: (Session) -> Void
    @State private var name = ""
    @State private var openWhenReady = true
    @State private var working = false
    @State private var error: String?
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    /// "Todo App" → "todo-app"
    private var slug: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let s = name.lowercased().trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: "-")
        return String(s.unicodeScalars.filter { allowed.contains($0) && $0.isASCII })
    }

    private var exists: Bool { store.overview?.projects.contains { $0.name == slug } ?? false }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("todo-app", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit(create)
                } header: {
                    Text("Name")
                } footer: {
                    if exists {
                        Text("~/Dev/\(slug) already exists. Start it from the list.").foregroundStyle(Theme.amber)
                    } else if !slug.isEmpty {
                        Text("Creates ~/Dev/\(slug) and starts a session named \(slug).")
                    }
                }
                Section {
                    Toggle("Open in Claude when ready", isOn: $openWhenReady)
                }
                if let error {
                    Section { Text(error).foregroundStyle(Theme.red) }
                }
            }
            .navigationTitle("New project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Create", action: create).bold().disabled(slug.isEmpty || exists)
                    }
                }
            }
            .onAppear { focused = true }
            .interactiveDismissDisabled(working)
        }
        .tint(Theme.peach)
        .presentationDetents([.medium])
    }

    private func create() {
        guard !slug.isEmpty, !exists, !working else { return }
        working = true
        Task {
            do {
                let s = try await API.start(name: slug, create: true)
                await store.refresh()
                dismiss()
                if openWhenReady { onStarted(s) }
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}
