import SwiftUI

struct InspectorView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            if let key = store.selectedEntityKey, let e = store.current?.entities[key] {
                EntityInspector(entity: e)
                    .id(key)
            } else {
                ContentUnavailableView {
                    Label("Nichts ausgewählt", systemImage: "cursorarrow.click.2")
                } description: {
                    Text("Wähle eine Person oder einen Begriff, um Fundstellen, Ersetzung und Rolle zu sehen.")
                }
            }
        }
    }
}

struct EntityInspector: View {
    @Environment(AppStore.self) private var store
    let entity: Entity
    @State private var replacement: String = ""

    var body: some View {
        let stat = store.stats[entity.key] ?? EntityStat()
        let findings = store.findings(for: entity.key, limit: 25)

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        if let role = entity.role, entity.kind == .name || entity.kind == .company {
                            Tag(text: role.label, tint: role.tint)
                        } else {
                            Tag(text: entity.kind.shortLabel, tint: entity.kind.tint)
                        }
                        Text(entity.sources.sorted().joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if entity.confidence > 0 && entity.confidence < 1 && entity.sources.contains("KI") {
                            Text("Sicherheit \(entity.confidence, format: .number.precision(.fractionLength(2)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(entity.display)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                    Text("\(stat.hits) Stellen in \(stat.files.count) Dokumenten")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let hint = hint {
                    Label {
                        Text(hint).font(.callout)
                    } icon: {
                        Image(systemName: "info.circle").foregroundStyle(Color.accentColor)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if entity.kind == .name || entity.kind == .company {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Rolle").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Picker("Rolle", selection: Binding(
                            get: { entity.role ?? .unknown },
                            set: { store.setRole(entity.key, $0) }
                        )) {
                            ForEach(Role.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Ersetzung im Balken und im Dateinamen").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TextField("leer = nur schwarzer Balken", text: $replacement)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit { store.setReplacement(entity.key, replacement) }
                        .onChange(of: replacement) { _, new in
                            if new != (entity.replacement ?? "") { store.setReplacement(entity.key, new) }
                        }
                }

                VStack(spacing: 8) {
                    if entity.locked {
                        Label(entity.lockReason.isEmpty ? "Feste Regel" : entity.lockReason, systemImage: "lock.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Button {
                            store.setDecision(entity.key, .redact)
                        } label: {
                            Label("Überall schwärzen", systemImage: "rectangle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.black)
                        .controlSize(.large)

                        Button {
                            store.setDecision(entity.key, .keep)
                        } label: {
                            Label("Überall behalten", systemImage: "eye")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                    }
                    HStack {
                        Button("Nie schwärzen") { store.addNever(entity.display) }
                        Spacer()
                        if entity.kind != .term {
                            Button("Immer schwärzen") { store.addAlways(entity.display) }
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Fundstellen").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(findings) { f in
                        Button {
                            store.viewerPage = f.page
                            store.viewerFileID = f.fileID
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(store.current?.file(f.fileID)?.fileName ?? "")
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Text("S. \(f.page + 1)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                SnippetText(before: f.before, matched: f.matched, after: f.after,
                                            redacted: entity.decision == .redact && !f.suppressed,
                                            replacement: entity.replacement, tint: entity.kind.tint)
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
                            .opacity(f.suppressed ? 0.5 : 1)
                        }
                        .buttonStyle(.plain)
                    }
                    if stat.hits > findings.count {
                        Text("… und \(stat.hits - findings.count) weitere")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(18)
        }
        .onAppear { replacement = entity.replacement ?? "" }
    }

    private var hint: String? {
        if !entity.note.isEmpty && entity.sources.contains("Regel") {
            return "Erkannt durch feste Regel: \(entity.note)."
        }
        if entity.role == .employee { return "Steht in der Personalliste. Vor- und Nachname, Nachname allein und Initialen werden zugeordnet." }
        if entity.kind == .name && entity.sources == ["KI"] {
            return "Von der KI erkannt, nicht in einer Liste. Rolle prüfen: Vermieter, Vertragspartner, Amtsträger …"
        }
        if entity.kind == .address { return "Anschriften von Objekten und Betriebsstätten bleiben meist sichtbar, Privatanschriften nicht." }
        return nil
    }
}
