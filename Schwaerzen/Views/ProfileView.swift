import SwiftUI

enum ProfileSection: Hashable {
    case lists
    case output
    case type(DocType)
}

struct ProfileView: View {
    @Environment(AppStore.self) private var store
    @State private var section: ProfileSection? = .lists

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                List(selection: $section) {
                    Section("Allgemein") {
                        Label("Listen & Begriffe", systemImage: "list.bullet.rectangle").tag(ProfileSection.lists)
                        Label("Ausgabe & KI", systemImage: "gearshape").tag(ProfileSection.output)
                    }
                    Section("Dokumenttypen") {
                        ForEach(DocType.reviewable) { t in
                            Label {
                                Text(t.label)
                            } icon: {
                                Image(systemName: t.symbol).foregroundStyle(t.tint)
                            }
                            .tag(ProfileSection.type(t))
                        }
                    }
                    Section("Schutz") {
                        Label {
                            Text("Ausschließen")
                        } icon: {
                            Image(systemName: "nosign").foregroundStyle(.red)
                        }
                        .tag(ProfileSection.type(.excluded))
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 250)

                Divider()

                ScrollView {
                    Group {
                        switch section ?? .lists {
                        case .lists: ListsSection()
                        case .output: OutputSection()
                        case .type(let t): TypeSection(type: t)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 680, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            HStack {
                Text("Änderungen an Regeln wirken sofort. Neue Listen werden mit „Erneut analysieren“ auf alle Dokumente angewendet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Fertig") { store.showProfile = false }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
            }
            .padding(14)
        }
        .frame(width: 960, height: 660)
    }
}

// MARK: - Dokumenttyp

private struct TypeSection: View {
    @Environment(AppStore.self) private var store
    let type: DocType

    var body: some View {
        let profile = store.current?.profile ?? Profile()
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(type.label).font(.largeTitle.weight(.semibold))
                Text(type == .excluded
                     ? "Diese Unterlagen werden gar nicht übernommen, auch nicht geschwärzt. Sie stehen nur im Prüfprotokoll."
                     : "Bleibt sichtbar: \(type.keepHint).")
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                Label("Erkannt an: \(type.detectHint)", systemImage: "magnifyingglass")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
            }

            if type != .excluded {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Schwärzen").font(.headline)
                    VStack(spacing: 0) {
                        ForEach(Array(Kind.configurable.enumerated()), id: \.element) { index, kind in
                            if index > 0 { Divider() }
                            HStack(spacing: 12) {
                                Image(systemName: kind.symbol)
                                    .foregroundStyle(kind.tint)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(kind.label)
                                    Text(kind.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if kind.locked {
                                    Text("immer").font(.caption).foregroundStyle(.secondary)
                                }
                                Toggle(kind.label, isOn: Binding(
                                    get: { profile.isEnabled(kind, for: type) },
                                    set: { on in store.mutate { $0.profile.set(kind, on, for: type) } }
                                ))
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .disabled(kind.locked)
                            }
                            .padding(.vertical, 9)
                            .padding(.horizontal, 12)
                        }
                    }
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                if type.isPersonal {
                    Label("In diesem Dokumenttyp schwärzt die App KI-Treffer ab der eingestellten Sicherheit automatisch.", systemImage: "sparkles")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Label("KI-Treffer ohne Listenbezug landen hier unter „Unsicher“ und werden nicht automatisch geschwärzt.", systemImage: "questionmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(["Krankmeldungen & AU-Bescheinigungen", "BEM- & Arztunterlagen, Atteste", "Schwerbehindertennachweise",
                             "Bewerbungsunterlagen & Lebensläufe", "Arbeitszeugnisse, Beurteilungen, Personalgespräche", "Führungszeugnisse"], id: \.self) { item in
                        Label(item, systemImage: "nosign").foregroundStyle(.primary)
                    }
                }
                Text("Grund: Gesundheitsdaten und andere besondere Kategorien nach Art. 9 DSGVO sollen in der Due Diligence nicht ausgetauscht werden. Einzelne Dateien kannst du unter „Dateien“ von Hand einem anderen Typ zuordnen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Listen

private struct ListsSection: View {
    @Environment(AppStore.self) private var store
    @State private var newNever = ""
    @State private var newAlways = ""

    var body: some View {
        let m = store.current
        VStack(alignment: .leading, spacing: 22) {
            Text("Listen & Begriffe").font(.largeTitle.weight(.semibold))
            Text("Mit Listen werden Namen sicher erkannt und durchnummeriert. Was hier steht, gilt für alle Dokumenttypen.")
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                listRow(title: "Personalliste", detail: m?.employeesSource.isEmpty == false
                        ? "\(m?.employees.count ?? 0) Personen · \(m?.employeesSource ?? "")"
                        : "Excel oder CSV mit Spalten Name, Vorname, Personalnummer",
                        filled: !(m?.employees.isEmpty ?? true)) { store.importList(.employees) }
                Divider()
                listRow(title: "Kreditorenliste (Lieferanten)", detail: m?.suppliersSource.isEmpty == false
                        ? "\(m?.suppliers.count ?? 0) Firmen · \(m?.suppliersSource ?? "")"
                        : "Firmen werden durchnummeriert (Lieferant 001 …)",
                        filled: !(m?.suppliers.isEmpty ?? true)) { store.importList(.suppliers) }
                Divider()
                listRow(title: "Debitorenliste (Kunden)", detail: m?.customersSource.isEmpty == false
                        ? "\(m?.customers.count ?? 0) Firmen · \(m?.customersSource ?? "")"
                        : "Nur nötig, wenn Kunden geschwärzt werden (z. B. Clean Team)",
                        filled: !(m?.customers.isEmpty ?? true)) { store.importList(.customers) }
            }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if let people = m?.employees, !people.isEmpty {
                DisclosureGroup("Vorschau Personalliste (\(people.count))") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(people.prefix(12)) { p in
                            HStack {
                                Text(p.fullName)
                                Spacer()
                                Text(p.number.isEmpty ? "ohne Nr." : "\(m?.profile.employeePrefix ?? "MA-")\(p.number)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if people.count > 12 { Text("…").foregroundStyle(.secondary) }
                    }
                    .padding(.top, 6)
                }
            }

            TermsEditor(title: "Nie schwärzen", hint: "z. B. Schuldnerin, Insolvenzverwalter, Gericht, Berater",
                        terms: m?.neverTerms ?? [], filled: false, text: $newNever,
                        onAdd: { store.addNever($0) }, onRemove: { store.removeNever($0) })

            TermsEditor(title: "Immer schwärzen", hint: "z. B. Projektname, Name eines Bieters, Kfz-Kennzeichen",
                        terms: m?.alwaysTerms ?? [], filled: true, text: $newAlways,
                        onAdd: { store.addAlways($0) }, onRemove: { store.removeAlways($0) })
        }
    }

    private func listRow(title: String, detail: String, filled: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: filled ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(filled ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(filled ? "Ersetzen …" : "Importieren …", action: action)
                .buttonStyle(.glass)
        }
        .padding(12)
    }
}

private struct TermsEditor: View {
    let title: String
    let hint: String
    let terms: [String]
    let filled: Bool
    @Binding var text: String
    let onAdd: (String) -> Void
    let onRemove: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            FlowLayout(spacing: 6) {
                ForEach(terms, id: \.self) { t in
                    HStack(spacing: 4) {
                        Text(t)
                        Button {
                            onRemove(t)
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(t) entfernen")
                    }
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .foregroundStyle(filled ? Color.white : Color.primary)
                    .background(filled ? AnyShapeStyle(Color.redactBlack) : AnyShapeStyle(.quaternary), in: Capsule())
                }
            }
            HStack {
                TextField(hint, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add() }
                Button("Hinzufügen") { add() }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func add() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        onAdd(t)
        text = ""
    }
}

// MARK: - Ausgabe & KI

private struct OutputSection: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let p = store.current?.profile ?? Profile()
        VStack(alignment: .leading, spacing: 22) {
            Text("Ausgabe & KI").font(.largeTitle.weight(.semibold))

            VStack(alignment: .leading, spacing: 10) {
                Text("Namen in Datei- und Ordnernamen").font(.headline)
                Picker("Ersetzung", selection: Binding(
                    get: { p.filenameMode },
                    set: { v in store.mutate { $0.profile.filenameMode = v } }
                )) {
                    ForEach(FilenameMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack(spacing: 10) {
                    Text("Arbeitsvertrag_Hans-Mueller.docx").strikethrough().foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Text(p.filenameMode.example).fontWeight(.semibold)
                }
                .font(.system(.callout, design: .monospaced))
                Text(p.filenameMode.hint).font(.callout).foregroundStyle(.secondary)
                HStack {
                    Text("Präfix für Mitarbeiter")
                    TextField("MA-", text: Binding(
                        get: { p.employeePrefix },
                        set: { v in store.mutate { $0.profile.employeePrefix = v } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Export").font(.headline)
                Toggle("Kürzel in den Schwärzungsbalken schreiben (z. B. MA-0417)", isOn: Binding(
                    get: { p.labelsInBars }, set: { v in store.mutate { $0.profile.labelsInBars = v } }))
                Toggle("Durchsuchbare Textebene nach dem Schwärzen neu erzeugen", isOn: Binding(
                    get: { p.rebuildTextLayer }, set: { v in store.mutate { $0.profile.rebuildTextLayer = v } }))
                Toggle("PDF-Metadaten entfernen (Autor, Firma, Kommentare)", isOn: Binding(
                    get: { p.removeMetadata }, set: { v in store.mutate { $0.profile.removeMetadata = v } }))
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("KI-Erkennung (lokal)").font(.headline)
                Toggle("Namen, Anschriften und Kontaktdaten zusätzlich per KI erkennen", isOn: Binding(
                    get: { p.useAI }, set: { v in store.mutate { $0.profile.useAI = v } }))
                HStack {
                    Text("Automatisch schwärzen ab Sicherheit")
                    Slider(value: Binding(get: { p.autoThreshold }, set: { v in store.mutate { $0.profile.autoThreshold = v } }),
                           in: 0.6...0.99)
                        .frame(width: 220)
                    Text(p.autoThreshold, format: .number.precision(.fractionLength(2)))
                        .monospacedDigit()
                        .frame(width: 40)
                }
                .disabled(!p.useAI)
                Text("Gilt nur für Personalunterlagen und Lohnabrechnungen. Alles darunter landet unter „Unsicher“.")
                    .font(.callout).foregroundStyle(.secondary)
                ModelStatusView()
            }
        }
    }
}

// MARK: - Fließlayout für Begriffe

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 600
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
