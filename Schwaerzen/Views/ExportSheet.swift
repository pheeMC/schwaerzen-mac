import SwiftUI
import AppKit

struct ExportSheet: View {
    @Environment(AppStore.self) private var store
    @State private var outputFolder: URL?
    @State private var protocolFolder: URL?
    @State private var redactPending = true

    var body: some View {
        let m = store.current
        let exportable = m?.files.filter { $0.status == .done && $0.docType != .excluded }.count ?? 0
        let excluded = m?.files.filter { $0.docType == .excluded }.count ?? 0
        let problems = m?.files.filter { $0.status == .failed || $0.status == .unsupported }.count ?? 0
        let pending = store.pendingCount
        let p = m?.profile ?? Profile()

        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Freigeben").font(.title.weight(.semibold))
                HStack(spacing: 14) {
                    Text("**\(exportable)** Dokumente")
                    Text("**\(excluded)** ausgeschlossen")
                    if problems > 0 { Text("**\(problems)** mit Fehlern").foregroundStyle(.orange) }
                    if pending == 0 {
                        Label("nichts mehr offen", systemImage: "checkmark").foregroundStyle(.green)
                    } else {
                        Label("\(pending) noch offen", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                    }
                }
                .font(.callout)
            }

            if let result = store.exportResult {
                resultView(result)
            } else {
                GroupBox("Ziel") {
                    VStack(alignment: .leading, spacing: 10) {
                        folderRow(title: "Ordner für den Datenraum", url: outputFolder) { pick(output: true) }
                        Divider()
                        HStack(spacing: 10) {
                            Image(systemName: "server.rack").foregroundStyle(.secondary).frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Direkt in den Datenraum hochladen")
                                Text("folgt in einer späteren Version").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: .constant(false)).labelsHidden().disabled(true)
                        }
                    }
                    .padding(6)
                }

                GroupBox("Optionen") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Kürzel in die Balken schreiben", isOn: Binding(
                            get: { p.labelsInBars }, set: { v in store.mutate { $0.profile.labelsInBars = v } }))
                        Toggle("Durchsuchbare Textebene neu erzeugen (langsamer)", isOn: Binding(
                            get: { p.rebuildTextLayer }, set: { v in store.mutate { $0.profile.rebuildTextLayer = v } }))
                        Toggle("Metadaten entfernen", isOn: Binding(
                            get: { p.removeMetadata }, set: { v in store.mutate { $0.profile.removeMetadata = v } }))
                        if pending > 0 {
                            Toggle("Offene Treffer sicherheitshalber schwärzen", isOn: $redactPending)
                        }
                        Divider()
                        folderRow(title: "Prüfprotokoll & Zuordnungsliste (nur lokal)", url: protocolFolder) {
                            pick(output: false)
                        }
                    }
                    .padding(6)
                }

                Text("Alle Seiten werden neu aufgebaut. Der Originaltext ist danach nicht mehr enthalten, auch nicht unter den Balken. Die Zuordnungsliste gehört nicht in den Datenraum.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if store.exportRunning {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: store.exportProgress)
                        Text(store.exportText).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }

            HStack {
                Spacer()
                if store.exportResult != nil {
                    Button("Schließen") {
                        store.exportResult = nil
                        store.showExport = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                } else {
                    Button("Abbrechen") { store.showExport = false }
                        .keyboardShortcut(.cancelAction)
                        .disabled(store.exportRunning)
                    Button("Freigeben") { start() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.glassProminent)
                        .disabled(store.exportRunning || exportable == 0)
                }
            }
        }
        .padding(26)
        .frame(width: 620)
        .onAppear {
            if outputFolder == nil { outputFolder = defaultOutput }
            if protocolFolder == nil { protocolFolder = defaultProtocol }
        }
    }

    private var safeName: String {
        let name = store.current?.name ?? "Mandat"
        return Renamer.sanitize(name.isEmpty ? "Mandat" : name)
    }

    private var defaultOutput: URL {
        if let last = store.current?.lastExportPath, !last.isEmpty { return URL(fileURLWithPath: last) }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Schwärzen/\(safeName)_Datenraum", isDirectory: true)
    }

    private var defaultProtocol: URL {
        (outputFolder ?? defaultOutput).deletingLastPathComponent()
            .appendingPathComponent("\(safeName)_Protokoll_NICHT_WEITERGEBEN", isDirectory: true)
    }

    private func folderRow(title: String, url: URL?, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder").foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(url?.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "–")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Ändern …", action: action)
        }
    }

    private func pick(output: Bool) {
        let suggested = output ? (outputFolder ?? defaultOutput) : (protocolFolder ?? defaultProtocol)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Wählen"
        panel.directoryURL = suggested.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if output {
            outputFolder = url.appendingPathComponent("\(safeName)_Datenraum", isDirectory: true)
            protocolFolder = url.appendingPathComponent("\(safeName)_Protokoll_NICHT_WEITERGEBEN", isDirectory: true)
        } else {
            protocolFolder = url
        }
    }

    private func start() {
        guard let out = outputFolder else { return }
        let p = store.current?.profile ?? Profile()
        store.runExport(ExportSettings(outputFolder: out,
                                       protocolFolder: protocolFolder ?? defaultProtocol,
                                       labelsInBars: p.labelsInBars,
                                       rebuildTextLayer: p.rebuildTextLayer,
                                       removeMetadata: p.removeMetadata,
                                       redactPending: redactPending))
    }

    private func resultView(_ r: ExportResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("\(r.exported) Dokumente mit \(r.boxes) Schwärzungen exportiert", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            if !r.problems.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(r.problems.prefix(8), id: \.self) { Text($0).font(.caption) }
                }
                .foregroundStyle(.orange)
            }
            HStack {
                Button("Datenraum-Ordner zeigen") { NSWorkspace.shared.activateFileViewerSelecting([r.outputFolder]) }
                    .buttonStyle(.glass)
                Button("Protokoll zeigen") { NSWorkspace.shared.activateFileViewerSelecting([r.protocolFolder]) }
                    .buttonStyle(.glass)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
