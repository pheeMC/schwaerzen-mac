import SwiftUI

struct DropZoneView: View {
    @Environment(AppStore.self) private var store
    let targeted: Bool

    var body: some View {
        // In einer ScrollView, damit die Mindestgröße nicht vom Textumbruch abhängt (sonst Layout-Schleife im Fenster).
        ScrollView {
            content
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var content: some View {
        VStack(spacing: 26) {
            VStack(spacing: 18) {
                Text("ORDNER ODER DATEIEN")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .tracking(3)
                    .foregroundStyle(.tertiary)
                Text(targeted ? "Loslassen zum Hinzufügen" : "Hierher ziehen. Alles bleibt auf dem Mac.")
                    .font(.system(size: 32, weight: .medium, design: .rounded))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .contentTransition(.opacity)
                Text("Word, Excel und PowerPoint wandelt Office um. PDFs und Scans werden per Texterkennung gelesen. Die Ordnerstruktur bleibt erhalten.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(width: 520)
                HStack(spacing: 12) {
                    Button {
                        store.chooseFiles()
                    } label: {
                        Label("Ordner oder Dateien wählen …", systemImage: "folder.badge.plus")
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)

                    Button {
                        store.showProfile = true
                    } label: {
                        Label("Personalliste & Profil", systemImage: "slider.horizontal.3")
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 56)
            .padding(.vertical, 44)
            .frame(width: 640)
            .glassEffect(.regular.tint(targeted ? Color.accentColor.opacity(0.18) : Color.clear), in: .rect(cornerRadius: 28))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(targeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.separator),
                                  style: StrokeStyle(lineWidth: targeted ? 1.6 : 1, dash: targeted ? [] : [6, 5]))
            )
            .scaleEffect(targeted ? 1.015 : 1)
            .animation(.smooth(duration: 0.2), value: targeted)

            tips
        }
        .padding(.horizontal, 32)
    }

    private var tips: some View {
        HStack(alignment: .top, spacing: 18) {
            tip("person.text.rectangle", "Personalliste zuerst", "Mit Personalnummern werden Namen sicher erkannt und zu Kürzeln wie MA-0417.")
            tip("checklist", "Pro Person entscheiden", "Eine Entscheidung gilt für alle Fundstellen in allen Dokumenten.")
            tip("lock.shield", "Gesundheitsdaten bleiben draußen", "Krankmeldungen, BEM und Ähnliches werden gar nicht exportiert.")
        }
        .frame(width: 760)
    }

    private func tip(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .frame(width: 240, alignment: .leading)
    }
}
