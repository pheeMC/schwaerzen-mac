import SwiftUI
import PDFKit
import AppKit

enum ViewerMode: String, CaseIterable, Identifiable {
    case view, add, remove
    var id: String { rawValue }
    var label: String {
        switch self {
        case .view: "Ansehen"
        case .add: "Bereich schwärzen"
        case .remove: "Stelle ausnehmen"
        }
    }
    var symbol: String {
        switch self {
        case .view: "eye"
        case .add: "plus.rectangle"
        case .remove: "minus.rectangle"
        }
    }
}

struct ViewerMark {
    var findingID: UUID
    var pageRect: CGRect
    var style: MarkAnnotation.Style
    var label: String?
}

struct DocumentViewer: View {
    @Environment(AppStore.self) private var store
    @State private var mode: ViewerMode = .view

    var body: some View {
        Group {
            if let fid = store.viewerFileID, let m = store.current, let file = m.file(fid) {
                VStack(spacing: 0) {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.fileName).font(.headline).lineLimit(1).truncationMode(.middle)
                            Text("\(file.docType.label) · \(file.pageCount) Seiten · \(store.redactionsByFile[fid] ?? 0) Schwärzungen")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("Modus", selection: $mode) {
                            ForEach(ViewerMode.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 420)
                        Spacer()
                        legend
                        Button("Fertig") { store.viewerFileID = nil }
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.glassProminent)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    Divider()
                    RedactionPDFView(url: Paths.workPDF(m.id, fid),
                                     marks: marks(m, file: file),
                                     mode: mode,
                                     startPage: store.viewerPage,
                                     onAdd: { page, rect in addBox(file: file, page: page, pageRect: rect, pdfURL: Paths.workPDF(m.id, fid)) },
                                     onToggle: { id in store.toggleFinding(id) })
                    Divider()
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
                .frame(minWidth: 980, idealWidth: 1100, minHeight: 720, idealHeight: 860)
            } else {
                ContentUnavailableView("Dokument nicht verfügbar", systemImage: "doc.questionmark")
                    .frame(width: 500, height: 300)
            }
        }
    }

    private var hint: String {
        switch mode {
        case .view: "Schwarz = wird geschwärzt · Orange = offen · Blau gestrichelt = bleibt sichtbar"
        case .add: "Bereich mit der Maus aufziehen, z. B. für Unterschriften oder Stempel."
        case .remove: "Auf eine Markierung klicken, um nur diese Stelle auszunehmen (bzw. wieder einzuschließen)."
        }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5).fill(Color.redactBlack).frame(width: 16, height: 8)
            RoundedRectangle(cornerRadius: 1.5).strokeBorder(Color.orange, lineWidth: 1.5).frame(width: 16, height: 8)
            RoundedRectangle(cornerRadius: 1.5).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.2, dash: [3, 2])).frame(width: 16, height: 8)
        }
        .help("Schwarz: wird geschwärzt · Orange: offen · Blau: bleibt sichtbar")
    }

    private func marks(_ m: Mandate, file: SourceFile) -> [Int: [ViewerMark]] {
        guard let doc = PDFDocument(url: Paths.workPDF(m.id, file.id)) else { return [:] }
        var transforms: [Int: CGAffineTransform] = [:]
        var out: [Int: [ViewerMark]] = [:]
        for f in m.findings where f.fileID == file.id {
            guard let e = m.entities[f.entityKey], m.profile.isEnabled(e.kind, for: file.docType) else { continue }
            if transforms[f.page] == nil, let page = doc.page(at: f.page) {
                transforms[f.page] = PageGeometry.displayTransform(for: page).inverted()
            }
            guard let inv = transforms[f.page] else { continue }
            let style: MarkAnnotation.Style
            if f.suppressed || e.decision == .keep {
                style = .keep
            } else if e.decision == .redact {
                style = .redact
            } else {
                style = .pending
            }
            for r in f.rects {
                out[f.page, default: []].append(ViewerMark(findingID: f.id, pageRect: r.cg.applying(inv).standardized,
                                                           style: style, label: m.profile.labelsInBars ? e.replacement : nil))
            }
        }
        return out
    }

    private func addBox(file: SourceFile, page: Int, pageRect: CGRect, pdfURL: URL) {
        guard let doc = PDFDocument(url: pdfURL), let p = doc.page(at: page) else { return }
        let display = pageRect.applying(PageGeometry.displayTransform(for: p)).standardized
        store.addManualBox(file: file.id, page: page, box: Box(display))
    }
}

// MARK: - PDFKit

final class MarkAnnotation: PDFAnnotation {
    enum Style { case redact, pending, keep }

    var style: Style = .pending
    var findingID: UUID?
    var label: String?

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        let r = bounds
        context.saveGState()
        switch style {
        case .redact:
            context.setFillColor(NSColor.black.cgColor)
            context.fill(r)
            if let label, !label.isEmpty, r.height >= 7 {
                let size = min(r.height * 0.6, 14)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: size, weight: .medium),
                    .foregroundColor: NSColor.white
                ]
                let text = NSAttributedString(string: label, attributes: attrs)
                let ts = text.size()
                if ts.width < r.width - 2 {
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                    text.draw(at: CGPoint(x: r.midX - ts.width / 2, y: r.midY - ts.height / 2))
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
        case .pending:
            context.setFillColor(NSColor.systemOrange.withAlphaComponent(0.22).cgColor)
            context.fill(r)
            context.setStrokeColor(NSColor.systemOrange.cgColor)
            context.setLineWidth(1)
            context.stroke(r)
        case .keep:
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(0.9)
            context.setLineDash(phase: 0, lengths: [3, 2])
            context.stroke(r)
        }
        context.restoreGState()
    }
}

struct RedactionPDFView: NSViewRepresentable {
    let url: URL
    let marks: [Int: [ViewerMark]]
    let mode: ViewerMode
    let startPage: Int
    let onAdd: (Int, CGRect) -> Void
    let onToggle: (UUID) -> Void

    func makeNSView(context: Context) -> InteractivePDFView {
        let view = InteractivePDFView()
        view.displayMode = .singlePageContinuous
        view.autoScales = true
        view.backgroundColor = NSColor.windowBackgroundColor
        view.document = PDFDocument(url: url)
        if let page = view.document?.page(at: startPage) {
            DispatchQueue.main.async { view.go(to: page) }
        }
        return view
    }

    func updateNSView(_ view: InteractivePDFView, context: Context) {
        view.mode = mode
        view.onAdd = onAdd
        view.onToggle = onToggle
        view.apply(marks)
    }
}

final class InteractivePDFView: PDFView {
    var mode: ViewerMode = .view
    var onAdd: ((Int, CGRect) -> Void)?
    var onToggle: ((UUID) -> Void)?

    private var placed: [(PDFPage, PDFAnnotation)] = []
    private var dragStart: CGPoint?
    private var dragPage: PDFPage?
    private var preview: PDFAnnotation?

    func apply(_ marks: [Int: [ViewerMark]]) {
        for (page, ann) in placed { page.removeAnnotation(ann) }
        placed.removeAll()
        guard let doc = document else { return }
        for (index, list) in marks {
            guard let page = doc.page(at: index) else { continue }
            for mark in list {
                let ann = MarkAnnotation(bounds: mark.pageRect, forType: .square, withProperties: nil)
                ann.style = mark.style
                ann.findingID = mark.findingID
                ann.label = mark.label
                ann.border = nil
                page.addAnnotation(ann)
                placed.append((page, ann))
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        guard let page = page(for: loc, nearest: true) else { super.mouseDown(with: event); return }
        let point = convert(loc, to: page)
        switch mode {
        case .view:
            super.mouseDown(with: event)
        case .remove:
            if let ann = page.annotations.reversed().first(where: { ($0 as? MarkAnnotation) != nil && $0.bounds.insetBy(dx: -2, dy: -2).contains(point) }) as? MarkAnnotation,
               let id = ann.findingID {
                onToggle?(id)
            }
        case .add:
            dragStart = point
            dragPage = page
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .add, let start = dragStart, let page = dragPage else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(convert(event.locationInWindow, from: nil), to: page)
        let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
        if let preview { page.removeAnnotation(preview) }
        let p = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
        p.color = NSColor.systemRed.withAlphaComponent(0.8)
        p.interiorColor = NSColor.black.withAlphaComponent(0.35)
        page.addAnnotation(p)
        preview = p
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil
            dragPage = nil
            preview = nil
        }
        guard mode == .add, let start = dragStart, let page = dragPage, let doc = document else {
            super.mouseUp(with: event)
            return
        }
        if let preview { page.removeAnnotation(preview) }
        let point = convert(convert(event.locationInWindow, from: nil), to: page)
        let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
        if rect.width > 3 && rect.height > 3 {
            onAdd?(doc.index(for: page), rect)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        switch mode {
        case .add: addCursorRect(bounds, cursor: .crosshair)
        case .remove: addCursorRect(bounds, cursor: .pointingHand)
        case .view: break
        }
    }
}
