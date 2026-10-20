import SwiftUI

struct FilesView: View {
    @Environment(AppStore.self) private var store
    @State private var selection = Set<UUID>()

    var body: some View {
        let files = store.filteredFiles
        let m = store.current

        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dateien").font(.title2.weight(.semibold))
                    Text("Dokumenttyp per Menü ändern. Doppelklick öffnet das Dokument.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatTile(value: "\(m?.files.count ?? 0)", label: "Dateien")
                StatTile(value: "\(m?.files.filter { $0.status == .done && $0.docType != .excluded }.count ?? 0)", label: "analysiert")
                StatTile(value: "\(m?.files.filter { $0.docType == .excluded }.count ?? 0)", label: "ausgeschlossen", tint: .red)
                StatTile(value: "\(m?.files.filter { $0.status == .failed || $0.status == .unsupported }.count ?? 0)", label: "brauchen dich", tint: .orange)
                Button {
                    store.reanalyze()
                } label: {
                    Label("Erneut analysieren", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .disabled(store.processing)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)

            Table(files, selection: $selection) {
                TableColumn("Datei") { f in
                    HStack(spacing: 8) {
                        Image(systemName: icon(for: f.ext))
                            .foregroundStyle(.secondary)
                        Text(f.relativePath)
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .help(f.relativePath)
                }
                .width(min: 260, ideal: 460)

                TableColumn("Dokumenttyp") { f in
                    Picker("Typ", selection: Binding(
                        get: { f.docType },
                        set: { store.setDocType(f.id, $0) }
                    )) {
                        ForEach(DocType.allCases) { t in
                            Label(t.label, systemImage: t.symbol).tag(t)
                        }
                    }
                    .labelsHidden()
                    .disabled(f.status != .done && f.status != .failed)
                }
                .width(min: 170, ideal: 210)

                TableColumn("Umwandlung") { f in
                    Text(f.method.isEmpty ? "–" : f.method).foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 110)

                TableColumn("Seiten") { f in
                    Text(f.pageCount > 0 ? "\(f.pageCount)" : "–").monospacedDigit()
                }
                .width(56)

                TableColumn("Schwärzungen") { f in
                    Text("\(store.redactionsByFile[f.id] ?? 0)").monospacedDigit()
                }
                .width(92)

                TableColumn("Status") { f in
                    statusView(f)
                }
                .width(min: 140, ideal: 220)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first, ids.count == 1 {
                    Button("Dokument öffnen") { store.viewerPage = 0; store.viewerFileID = id }
                    Button("Original im Finder zeigen") { store.revealSource(id) }
                }
                Button("Erneut analysieren") { store.reanalyze(Array(ids)) }
                Menu("Dokumenttyp") {
                    ForEach(DocType.allCases) { t in
                        Button(t.label) { ids.forEach { store.setDocType($0, t) } }
                    }
                }
                Divider()
                Button("Aus dem Mandat entfernen", role: .destructive) { store.removeFiles(ids) }
            } primaryAction: { ids in
                if let id = ids.first, store.current?.file(id)?.status == .done {
                    store.viewerPage = 0
                    store.viewerFileID = id
                }
            }
        }
    }

    @ViewBuilder
    private func statusView(_ f: SourceFile) -> some View {
        switch f.status {
        case .done where f.docType == .excluded:
            Label(f.excludedReason.isEmpty ? "Ausgeschlossen" : f.excludedReason, systemImage: "nosign")
                .foregroundStyle(.red)
                .help("Wird nicht exportiert")
        case .done:
            Label("Fertig", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .converting, .analyzing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(f.status.label)
            }
            .foregroundStyle(Color.accentColor)
        case .queued:
            Text("Wartet").foregroundStyle(.secondary)
        case .failed, .unsupported:
            Label(f.message.isEmpty ? f.status.label : f.message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(2)
                .help(f.message)
        }
    }

    private func icon(for ext: String) -> String {
        if Converter.wordTypes.contains(ext) { return "doc.richtext" }
        if Converter.excelTypes.contains(ext) { return "tablecells" }
        if Converter.powerPointTypes.contains(ext) { return "rectangle.on.rectangle" }
        if Converter.imageTypes.contains(ext) { return "photo" }
        if ext == "pdf" { return "doc.text" }
        return "doc"
    }
}
