import SwiftUI
import AppKit

@main
struct SchwaerzenApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup("Schwärzen") {
            RootView()
                .environment(store)
                .frame(minWidth: 1080, minHeight: 680)
                .task { await store.bootstrap() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    store.saveNow()
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Neues Mandat …") { store.showNewMandate = true }
                    .keyboardShortcut("n")
                Button("Dateien hinzufügen …") { store.chooseFiles() }
                    .keyboardShortcut("o")
                    .disabled(store.current == nil)
            }
            CommandGroup(after: .saveItem) {
                Button("Freigeben …") { store.showExport = true }
                    .keyboardShortcut("e")
                    .disabled(store.current == nil)
                Button("Mandatsprofil …") { store.showProfile = true }
                    .keyboardShortcut(",", modifiers: [.command, .option])
                    .disabled(store.current == nil)
            }
            CommandMenu("Prüfung") {
                ForEach(Array(ReviewMode.allCases.enumerated()), id: \.element) { index, mode in
                    Button(mode.label) { store.mode = mode }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                }
                Divider()
                Button("Alle offenen schwärzen") {
                    store.setDecision(keys: store.activeRows.filter { $0.entity.decision == .pending }.map(\.entity.key), .redact)
                }
                .disabled(store.pendingCount == 0)
                Button("Alle Dateien erneut analysieren") { store.reanalyze() }
                    .disabled(store.current == nil || store.processing)
            }
        }

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}
