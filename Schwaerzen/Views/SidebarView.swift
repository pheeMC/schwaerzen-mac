import SwiftUI

struct SidebarView: View {
    @Environment(AppStore.self) private var store
    @State private var expanded: Set<UUID> = []
    @State private var confirmDelete: Mandate?

    var body: some View {
        @Bindable var store = store

        List(selection: $store.selection) {
            Section("Mandate") {
                ForEach(store.mandates) { m in
                    DisclosureGroup(isExpanded: Binding(
                        get: { expanded.contains(m.id) || store.currentID == m.id },
                        set: { open in
                            if open { expanded.insert(m.id) } else { expanded.remove(m.id) }
                        }
                    )) {
                        if store.currentID == m.id {
                            filterRows(for: m)
                        }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.name).lineLimit(1)
                                if !m.caseNumber.isEmpty {
                                    Text(m.caseNumber).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        } icon: {
                            Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                        }
                        .tag(SidebarSelection(mandate: m.id, item: .all))
                        .contextMenu {
                            Button("Mandat löschen …", role: .destructive) { confirmDelete = m }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                ModelStatusView()
                Button {
                    store.showNewMandate = true
                } label: {
                    Label("Neues Mandat", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 86, maxHeight: 86, alignment: .topLeading)
        }
        .confirmationDialog("Mandat löschen?", isPresented: Binding(
            get: { confirmDelete != nil },
            set: { if !$0 { confirmDelete = nil } }
        ), presenting: confirmDelete) { m in
            Button("„\(m.name)“ löschen", role: .destructive) { store.deleteMandate(m.id) }
        } message: { _ in
            Text("Entscheidungen und Arbeitsdateien werden gelöscht. Deine Originaldateien bleiben unverändert.")
        }
    }

    @ViewBuilder
    private func filterRows(for m: Mandate) -> some View {
        Label("Alle Dokumente", systemImage: "tray.full")
            .badge(store.fileCount(.all))
            .tag(SidebarSelection(mandate: m.id, item: .all))

        ForEach(DocType.reviewable) { t in
            let n = store.fileCount(.type(t))
            if n > 0 {
                Label {
                    Text(t.label)
                } icon: {
                    Image(systemName: t.symbol).foregroundStyle(t.tint)
                }
                .badge(n)
                .tag(SidebarSelection(mandate: m.id, item: .type(t)))
            }
        }

        let excluded = store.fileCount(.type(.excluded))
        if excluded > 0 {
            Label {
                Text("Ausgeschlossen")
            } icon: {
                Image(systemName: DocType.excluded.symbol).foregroundStyle(.red)
            }
            .badge(excluded)
            .tag(SidebarSelection(mandate: m.id, item: .type(.excluded)))
        }

        let problems = store.fileCount(.problems)
        if problems > 0 {
            Label {
                Text("Fehler")
            } icon: {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            .badge(problems)
            .tag(SidebarSelection(mandate: m.id, item: .problems))
        }
    }
}

struct ModelStatusView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let ai = store.ai
        HStack(alignment: .top, spacing: 8) {
            switch ai.phase {
            case .ready:
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            case .checking, .loading, .downloading:
                ProgressView().controlSize(.mini)
            case .missing, .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(ai.statusText)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if ai.isReady && !ai.sourceDescription.isEmpty {
                    Text(ai.sourceDescription).font(.caption2).foregroundStyle(.secondary)
                }
                if ai.phase == .missing {
                    Button("Modell laden (ca. 1,5 GB)") {
                        Task { await ai.download() }
                    }
                    .font(.caption)
                    .buttonStyle(.link)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 40, alignment: .topLeading)
    }
}
