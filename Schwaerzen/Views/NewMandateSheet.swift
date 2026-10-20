import SwiftUI
import AppKit

struct NewMandateSheet: View {
    @Environment(AppStore.self) private var store
    @State private var name = ""
    @State private var caseNumber = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Neues Mandat").font(.title2.weight(.semibold))
            Form {
                TextField("Schuldnerin / Gesellschaft", text: $name, prompt: Text("z. B. Nordlicht Logistik GmbH"))
                    .focused($focused)
                TextField("Aktenzeichen", text: $caseNumber, prompt: Text("z. B. 34 IN 112/26"))
            }
            .formStyle(.grouped)
            Text("Der Name der Gesellschaft kommt automatisch auf die Nie-Liste und bleibt in den Dokumenten sichtbar.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Abbrechen") { store.showNewMandate = false }
                    .keyboardShortcut(.cancelAction)
                Button("Anlegen") {
                    store.createMandate(name: name, caseNumber: caseNumber)
                    store.showNewMandate = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear { focused = true }
    }
}

struct SettingsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Form {
            Section("KI-Modell") {
                ModelStatusView()
                LabeledContent("Modell", value: AIDetector.repoID)
                LabeledContent("Verarbeitung", value: "lokal auf diesem Mac (MLX)")
                Button("Erneut suchen") { Task { await store.ai.locateAndLoad() } }
            }
            Section("Speicherort") {
                LabeledContent("Mandate & Arbeitsdateien") {
                    Text(Paths.support.path(percentEncoded: false))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([Paths.support]) }
            }
            Section("Über") {
                Text("Schwärzen 0.1 · baut auf HideMyData (GPL-3.0) und OpenMedKit auf. Alle Daten bleiben auf diesem Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 420)
    }
}
