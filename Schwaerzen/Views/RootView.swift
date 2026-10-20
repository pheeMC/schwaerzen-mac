import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var store = store

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            DetailView(dropTargeted: $dropTargeted)
        }
        .sheet(isPresented: $store.showNewMandate) {
            NewMandateSheet()
        }
        .sheet(isPresented: $store.showProfile) {
            ProfileView()
        }
        .sheet(isPresented: $store.showExport) {
            ExportSheet()
        }
        .sheet(isPresented: Binding(
            get: { store.viewerFileID != nil },
            set: { if !$0 { store.viewerFileID = nil } }
        )) {
            DocumentViewer()
        }
        .alert("Hinweis", isPresented: Binding(
            get: { store.alertMessage != nil },
            set: { if !$0 { store.alertMessage = nil } }
        )) {
            Button("OK") { store.alertMessage = nil }
        } message: {
            Text(store.alertMessage ?? "")
        }
    }
}

struct DetailView: View {
    @Environment(AppStore.self) private var store
    @Binding var dropTargeted: Bool

    var body: some View {
        @Bindable var store = store

        Group {
            if let m = store.current {
                if m.files.isEmpty {
                    DropZoneView(targeted: dropTargeted)
                } else {
                    content
                }
            } else {
                ContentUnavailableView {
                    Label("Kein Mandat", systemImage: "folder.badge.plus")
                } description: {
                    Text("Lege ein Mandat an und ziehe dann die Unterlagen hinein.")
                } actions: {
                    Button("Neues Mandat …") { store.showNewMandate = true }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                }
            }
        }
        .navigationTitle(store.current?.name ?? "Schwärzen")
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .searchable(text: $store.search, placement: .toolbar, prompt: "Name oder Begriff")
        .inspector(isPresented: $store.showInspector) {
            InspectorView()
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
        .safeAreaInset(edge: .bottom) {
            if store.processing {
                ProgressPill(text: store.progressText, value: store.progressValue)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: store.processing)
        .dropDestination(for: URL.self) { urls, _ in
            guard store.current != nil else { return false }
            store.addFiles(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var subtitle: String {
        guard let m = store.current else { return "" }
        var parts: [String] = []
        if !m.caseNumber.isEmpty { parts.append(m.caseNumber) }
        switch store.sidebarItem {
        case .all: parts.append("Alle Dokumente")
        case .type(let t): parts.append(t.label)
        case .problems: parts.append("Fehler")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        switch store.mode {
        case .entities: EntitiesView()
        case .unsure: UnsureView()
        case .pages: PagesView()
        case .files: FilesView()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        @Bindable var store = store
        ToolbarItem(placement: .principal) {
            Picker("Ansicht", selection: $store.mode) {
                ForEach(ReviewMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(store.current == nil)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                store.chooseFiles()
            } label: {
                Label("Dateien hinzufügen", systemImage: "plus")
            }
            .help("Ordner oder Dateien hinzufügen (⌘O)")
            .disabled(store.current == nil)

            Button {
                store.showProfile = true
            } label: {
                Label("Mandatsprofil", systemImage: "slider.horizontal.3")
            }
            .help("Was wird geschwärzt? Listen, Regeln, Dateinamen")
            .disabled(store.current == nil)

            Button {
                store.showInspector.toggle()
            } label: {
                Label("Details", systemImage: "sidebar.trailing")
            }
            .help("Details ein-/ausblenden")
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Freigeben …") { store.showExport = true }
                .buttonStyle(.borderedProminent)
                .disabled(store.current == nil || store.processing || (store.current?.files.isEmpty ?? true))
                .help("Geschwärzte PDFs exportieren (⌘E)")
        }
    }
}
