import SwiftUI

struct EntitiesView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        let groups = store.groupedEntities

        VStack(spacing: 0) {
            header
            if groups.isEmpty {
                ContentUnavailableView {
                    Label(store.processing ? "Analyse läuft …" : "Keine Treffer", systemImage: store.processing ? "hourglass" : "checkmark.circle")
                } description: {
                    Text(store.processing ? "Die ersten Personen und Begriffe erscheinen, sobald das erste Dokument fertig ist."
                                          : "Für diese Auswahl gibt es nichts zu prüfen.")
                }
            } else {
                List(selection: $store.selectedEntityKey) {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.rows) { row in
                                EntityRowView(row: row)
                                    .tag(row.entity.key)
                                    .contextMenu { contextMenu(row) }
                            }
                        } header: {
                            HStack {
                                Label(group.kind.label, systemImage: group.kind.symbol)
                                Spacer()
                                Text("\(group.rows.count)").monospacedDigit()
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds(.enabled)
                .onChange(of: store.selectedEntityKey) { _, key in
                    if key != nil { store.showInspector = true }
                }
            }
        }
    }

    private var header: some View {
        @Bindable var store = store
        let rows = store.activeRows
        let pending = rows.filter { $0.entity.decision == .pending }.count
        let redact = rows.filter { $0.entity.decision == .redact }.count
        let findings = rows.filter { $0.entity.decision != .keep }.reduce(0) { $0 + $1.stat.hits }

        return HStack(alignment: .bottom, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Personen & Begriffe")
                    .font(.title2.weight(.semibold))
                Text("Eine Entscheidung gilt für alle Fundstellen in allen Dokumenten.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatTile(value: "\(pending)", label: "offen", tint: pending > 0 ? .orange : .secondary)
            StatTile(value: "\(redact)", label: "werden geschwärzt")
            StatTile(value: "\(findings)", label: "Fundstellen")
            VStack(alignment: .trailing, spacing: 6) {
                Picker("Filter", selection: $store.decisionFilter) {
                    ForEach(DecisionFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
                Menu("Alle offenen …") {
                    Button("… schwärzen") {
                        store.setDecision(keys: rows.filter { $0.entity.decision == .pending }.map(\.entity.key), .redact)
                    }
                    Button("… behalten") {
                        store.setDecision(keys: rows.filter { $0.entity.decision == .pending }.map(\.entity.key), .keep)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(pending == 0)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func contextMenu(_ row: EntityRow) -> some View {
        Button("Schwärzen") { store.setDecision(row.entity.key, .redact) }
        Button("Behalten") { store.setDecision(row.entity.key, .keep) }
        Divider()
        Button("Zur Nie-Liste hinzufügen") { store.addNever(row.entity.display) }
        Button("Zur Immer-Liste hinzufügen") { store.addAlways(row.entity.display) }
    }
}

struct EntityRowView: View {
    @Environment(AppStore.self) private var store
    let row: EntityRow

    var body: some View {
        let e = row.entity
        HStack(spacing: 12) {
            DecisionDot(decision: e.decision, locked: e.locked)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.display)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(e.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 180, alignment: .leading)
            Spacer(minLength: 8)
            if let role = e.role, e.kind == .name || e.kind == .company {
                Tag(text: role.label, tint: role.tint)
            } else {
                Tag(text: e.kind.shortLabel, tint: e.kind.tint)
            }
            Text(e.replacement ?? "█████")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(e.replacement == nil ? .tertiary : .primary)
                .frame(width: 120, alignment: .leading)
                .lineLimit(1)
            Text("\(row.stat.hits) in \(row.stat.files.count) Dok.")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            DecisionPicker(decision: e.decision, locked: e.locked, lockReason: e.lockReason) { d in
                store.setDecision(e.key, d)
            }
        }
        .padding(.vertical, 3)
    }
}
