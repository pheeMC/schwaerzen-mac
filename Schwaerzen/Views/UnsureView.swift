import SwiftUI

struct UnsureView: View {
    @Environment(AppStore.self) private var store
    @State private var decidedCount = 0

    var body: some View {
        let queue = store.unsureQueue
        let total = queue.count + decidedCount

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Unsichere Treffer")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Text(queue.isEmpty ? "Fertig" : "\(decidedCount + 1) von \(total)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: total > 0 ? Double(decidedCount) / Double(total) : 1)
                    .progressViewStyle(.linear)

                if let row = queue.first {
                    card(row)
                    if queue.count > 1 {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Als Nächstes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(queue.dropFirst().prefix(4)) { next in
                                HStack(spacing: 10) {
                                    Text(next.entity.display).font(.callout.weight(.semibold))
                                    Text("\(next.entity.kind.shortLabel) · \(next.stat.hits) Stellen")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                        }
                    }
                } else {
                    done
                }
            }
            .padding(28)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
        }
    }

    private func card(_ row: EntityRow) -> some View {
        let e = row.entity
        let findings = store.findings(for: e.key, limit: 3)

        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Tag(text: e.kind.label, tint: e.kind.tint)
                if let role = e.role, e.kind == .name {
                    Tag(text: role.label, tint: role.tint)
                }
                Spacer()
                Text("\(row.stat.hits) Stellen in \(row.stat.files.count) Dokumenten")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(e.display)
                .font(.system(size: 26, weight: .semibold))
                .textSelection(.enabled)

            ForEach(findings) { f in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(store.current?.file(f.fileID)?.relativePath ?? "") · Seite \(f.page + 1)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    SnippetText(before: f.before, matched: f.matched, after: f.after, redacted: false,
                                replacement: nil, tint: e.kind.tint)
                        .font(.system(size: 17, design: .serif))
                }
            }

            Text(question(for: e))
                .font(.callout)
                .foregroundStyle(.secondary)

            if e.kind == .name {
                Picker("Rolle", selection: Binding(
                    get: { e.role ?? .unknown },
                    set: { store.setRole(e.key, $0) }
                )) {
                    ForEach(Role.allCases) { Text($0.label).tag($0) }
                }
                .frame(maxWidth: 320)
            }

            Label("Gilt für alle \(row.stat.hits) Stellen. Einzelne Stellen kannst du im Dokument ausnehmen.", systemImage: "square.stack.3d.up")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    decide(e.key, .keep)
                } label: {
                    Label("Behalten", systemImage: "eye").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.extraLarge)
                .keyboardShortcut("b", modifiers: [])

                Button("Überspringen") {
                    store.skippedUnsure.insert(e.key)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.space, modifiers: [])

                Button {
                    decide(e.key, .redact)
                } label: {
                    Label("Schwärzen", systemImage: "rectangle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(.black)
                .controlSize(.extraLarge)
                .keyboardShortcut("s", modifiers: [])
            }
            Text("Tastatur: S schwärzen · B behalten · Leertaste überspringen")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(26)
        .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.08), radius: 20, y: 8)
    }

    private var done: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("Alle unsicheren Treffer entschieden")
                .font(.title3.weight(.semibold))
            Text(store.skippedUnsure.isEmpty ? "Als Nächstes: Stichprobe in der Seitenansicht."
                                             : "\(store.skippedUnsure.count) übersprungen.")
                .foregroundStyle(.secondary)
            HStack {
                if !store.skippedUnsure.isEmpty {
                    Button("Übersprungene erneut zeigen") { store.skippedUnsure = [] }
                        .buttonStyle(.glass)
                }
                Button("Stichprobe ansehen") { store.mode = .pages }
                    .buttonStyle(.glassProminent)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(48)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func decide(_ key: String, _ d: Decision) {
        store.setDecision(key, d)
        decidedCount += 1
    }

    private func question(for e: Entity) -> String {
        switch e.kind {
        case .name:
            return e.role == .employee ? "Mitarbeiter laut Personalliste." : "Name ohne Treffer in einer Liste. Privatperson, Vertragspartner oder Amtsträger?"
        case .address: return "Privatanschrift schwärzen? Objekt- und Betriebsadressen bleiben meist sichtbar."
        case .contact: return "Persönliche Kontaktdaten oder allgemeine Firmenadresse (info@, Zentrale)?"
        case .family: return "Merkmal zur privaten Lebenssituation (Steuerklasse, Kinder, Pfändung)."
        case .insurer: return "Krankenkasse einer Person."
        default: return "Schwärzen oder sichtbar lassen?"
        }
    }
}
