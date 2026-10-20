import SwiftUI
import AppKit

struct PageMark: Hashable {
    var box: Box
    var decision: Decision
}

struct PageRef: Identifiable, Hashable {
    var file: SourceFile
    var page: Int
    var width: Double
    var height: Double
    var id: String { "\(file.id.uuidString)-\(page)" }
}

struct PagesView: View {
    @Environment(AppStore.self) private var store

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 18)]

    var body: some View {
        @Bindable var store = store
        let files = store.filteredFiles.filter { $0.status == .done && $0.docType != .excluded }
        let marks = buildMarks()
        let pages = buildPages(files)

        VStack(spacing: 0) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stichprobe")
                        .font(.title2.weight(.semibold))
                    Text("So sehen die Seiten nach dem Export aus. Doppelklick öffnet das Dokument.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Alle Seiten", isOn: $store.showPagesAll)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                legend
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)

            if pages.isEmpty {
                ContentUnavailableView("Keine Seiten", systemImage: "doc.on.doc", description: Text("Für diese Auswahl gibt es noch keine analysierten Dokumente."))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(pages) { ref in
                            PageThumb(ref: ref, marks: marks[ref.id] ?? [])
                                .onTapGesture(count: 2) {
                                    store.viewerPage = ref.page
                                    store.viewerFileID = ref.file.id
                                }
                        }
                    }
                    .padding(24)
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.redactBlack).frame(width: 18, height: 9)
                Text("wird geschwärzt")
            }
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1.5).strokeBorder(Color.orange, lineWidth: 1.5).frame(width: 18, height: 9)
                Text("offen")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, 12)
    }

    private func buildMarks() -> [String: [PageMark]] {
        guard let m = store.current else { return [:] }
        var types: [UUID: DocType] = [:]
        for f in m.files { types[f.id] = f.docType }
        var out: [String: [PageMark]] = [:]
        for f in m.findings where !f.suppressed {
            guard let e = m.entities[f.entityKey], let t = types[f.fileID], m.profile.isEnabled(e.kind, for: t), e.decision != .keep else { continue }
            let key = "\(f.fileID.uuidString)-\(f.page)"
            for r in f.rects { out[key, default: []].append(PageMark(box: r, decision: e.decision)) }
        }
        return out
    }

    private func buildPages(_ files: [SourceFile]) -> [PageRef] {
        guard let mid = store.currentID else { return [] }
        var out: [PageRef] = []
        _ = mid
        for f in files {
            let count = store.showPagesAll ? max(f.pageCount, 1) : 1
            for p in 0..<count {
                let size = f.pageSize(p)
                out.append(PageRef(file: f, page: p, width: Double(size.width), height: Double(size.height)))
            }
            if out.count > 600 { break }
        }
        return out
    }
}

struct PageThumb: View {
    @Environment(AppStore.self) private var store
    let ref: PageRef
    let marks: [PageMark]
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(.white)
                        .aspectRatio(CGFloat(ref.width / max(ref.height, 1)), contentMode: .fit)
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .overlay {
                GeometryReader { geo in
                    let pw = displayWidth
                    let ph = displayHeight
                    let s = min(geo.size.width / pw, geo.size.height / ph)
                    let ox = (geo.size.width - pw * s) / 2
                    let oy = (geo.size.height - ph * s) / 2
                    ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                        let r = mark.box.cg
                        let frame = CGRect(x: ox + r.minX * s, y: oy + (ph - r.maxY) * s,
                                           width: max(r.width * s, 2), height: max(r.height * s, 1.5))
                        Group {
                            if mark.decision == .redact {
                                Rectangle().fill(Color.redactBlack)
                            } else {
                                Rectangle().fill(Color.orange.opacity(0.25))
                                    .overlay(Rectangle().strokeBorder(Color.orange, lineWidth: 1))
                            }
                        }
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.separator))
            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)

            Text(ref.page == 0 ? ref.file.fileName : "\(ref.file.fileName) · S. \(ref.page + 1)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .help(ref.file.relativePath)
        .task(id: ref.id) {
            image = await store.thumbnail(file: ref.file.id, page: ref.page, size: CGSize(width: 420, height: 594))
        }
    }

    private var displayWidth: CGFloat { CGFloat(ref.width) }

    private var displayHeight: CGFloat { CGFloat(ref.height) }
}
