import Foundation
import PDFKit
import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

struct ExportSettings {
    var outputFolder: URL
    var protocolFolder: URL
    var labelsInBars: Bool
    var rebuildTextLayer: Bool
    var removeMetadata: Bool
    var redactPending: Bool
}

struct ExportResult {
    var exported: Int
    var skipped: Int
    var boxes: Int
    var outputFolder: URL
    var protocolFolder: URL
    var problems: [String]
}

/// Schreibt die geschwärzten PDFs: Seiten werden neu aufgebaut, der Originaltext unter den Balken ist danach nicht mehr enthalten.
enum Exporter {
    struct Mark {
        var rect: CGRect
        var label: String?
    }

    static func export(mandate: Mandate, settings: ExportSettings,
                       progress: @escaping @Sendable (Double, String) -> Void) async throws -> ExportResult {
        let fm = FileManager.default
        try fm.createDirectory(at: settings.outputFolder, withIntermediateDirectories: true)
        try fm.createDirectory(at: settings.protocolFolder, withIntermediateDirectories: true)

        let renamer = Renamer(mandate: mandate)
        let files = mandate.files.filter { $0.status == .done && $0.docType != .excluded }
        var usedPaths = Set<String>()
        var exported = 0
        var boxes = 0
        var problems: [String] = []
        var fileRows: [[String]] = [["Original", "Export", "Dokumenttyp", "Seiten", "Schwärzungen", "Hinweis"]]

        var byFile: [UUID: [Finding]] = [:]
        for f in mandate.findings where !f.suppressed { byFile[f.fileID, default: []].append(f) }

        for (i, file) in files.enumerated() {
            progress(Double(i) / Double(max(files.count, 1)), file.fileName)
            let src = Paths.workPDF(mandate.id, file.id)
            guard let doc = PDFDocument(url: src) else {
                problems.append("\(file.relativePath): Arbeitsdatei fehlt")
                continue
            }

            var marks: [Int: [Mark]] = [:]
            for f in byFile[file.id] ?? [] {
                guard let e = mandate.entities[f.entityKey] else { continue }
                guard mandate.profile.isEnabled(e.kind, for: file.docType) else { continue }
                let redact = e.decision == .redact || (e.decision == .pending && settings.redactPending)
                guard redact else { continue }
                let label = settings.labelsInBars ? e.replacement : nil
                for r in f.rects { marks[f.page, default: []].append(Mark(rect: r.cg, label: label)) }
            }

            var rel = renamer.rename(file.relativePath)
            rel = (rel as NSString).deletingPathExtension + ".pdf"
            rel = unique(rel, used: &usedPaths)
            let dest = settings.outputFolder.appendingPathComponent(rel)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

            do {
                let count = try await writeRedacted(doc: doc, marks: marks, to: dest, settings: settings)
                boxes += count
                exported += 1
                fileRows.append([file.relativePath, rel, file.docType.label, "\(doc.pageCount)", "\(count)", ""])
            } catch {
                problems.append("\(file.relativePath): \(error.localizedDescription)")
                fileRows.append([file.relativePath, "", file.docType.label, "\(doc.pageCount)", "", error.localizedDescription])
            }
        }

        for file in mandate.files where file.docType == .excluded {
            fileRows.append([file.relativePath, "", "Ausgeschlossen", "\(file.pageCount)", "", file.excludedReason])
        }
        for file in mandate.files where file.status == .failed || file.status == .unsupported {
            fileRows.append([file.relativePath, "", file.status.label, "", "", file.message])
        }

        try writeProtocol(mandate: mandate, fileRows: fileRows, renamer: renamer, folder: settings.protocolFolder)
        progress(1, "Fertig")
        return ExportResult(exported: exported, skipped: mandate.files.count - exported, boxes: boxes,
                            outputFolder: settings.outputFolder, protocolFolder: settings.protocolFolder, problems: problems)
    }

    private static func unique(_ path: String, used: inout Set<String>) -> String {
        var candidate = path
        var n = 2
        let base = (path as NSString).deletingPathExtension
        let ext = (path as NSString).pathExtension
        while used.contains(candidate.lowercased()) {
            candidate = "\(base) (\(n)).\(ext)"
            n += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    // MARK: - PDF neu aufbauen

    private static func writeRedacted(doc: PDFDocument, marks: [Int: [Mark]], to dest: URL,
                                      settings: ExportSettings) async throws -> Int {
        var aux: [CFString: Any] = [kCGPDFContextCreator: "Schwärzen" as CFString]
        if !settings.removeMetadata, let attrs = doc.documentAttributes {
            if let t = attrs[PDFDocumentAttribute.titleAttribute] as? String { aux[kCGPDFContextTitle] = t as CFString }
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(dest as CFURL, mediaBox: &mediaBox, aux as CFDictionary) else {
            throw AppError("PDF konnte nicht angelegt werden")
        }
        let scale: CGFloat = 2.5
        var count = 0

        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let size = PageGeometry.displaySize(for: page)
            let pageMarks = marks[i] ?? []
            count += pageMarks.count

            guard let raster = rasterize(page: page, size: size, scale: scale, marks: pageMarks, labels: settings.labelsInBars),
                  let jpeg = jpegImage(raster) else {
                throw AppError("Seite \(i + 1) konnte nicht aufgebaut werden")
            }

            var box = CGRect(origin: .zero, size: size)
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
            ctx.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            ctx.draw(jpeg, in: box)

            if settings.rebuildTextLayer {
                if let ocr = try? await OCREngine.recognize(raster) {
                    drawInvisibleText(ocr.lines, in: ctx, size: size)
                }
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return count
    }

    private static func rasterize(page: PDFPage, size: CGSize, scale: CGFloat, marks: [Mark], labels: Bool) -> CGImage? {
        let w = Int((size.width * scale).rounded())
        let h = Int((size.height * scale).rounded())
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        ctx.interpolationQuality = .high
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()

        for mark in marks {
            let r = CGRect(x: mark.rect.minX * scale, y: mark.rect.minY * scale,
                           width: mark.rect.width * scale, height: mark.rect.height * scale).insetBy(dx: -2, dy: -2)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(r)
            if labels, let label = mark.label, !label.isEmpty {
                drawLabel(label, in: r, ctx: ctx)
            }
        }
        return ctx.makeImage()
    }

    private static func drawLabel(_ label: String, in rect: CGRect, ctx: CGContext) {
        var fontSize = min(rect.height * 0.62, 30)
        guard fontSize >= 7 else { return }
        var font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
        var attr = NSAttributedString(string: label, attributes: [.font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.white.cgColor])
        var line = CTLineCreateWithAttributedString(attr)
        var width = CTLineGetTypographicBounds(line, nil, nil, nil)
        if width > Double(rect.width - 6) {
            fontSize = fontSize * CGFloat(Double(rect.width - 6) / width)
            guard fontSize >= 7 else { return }
            font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
            attr = NSAttributedString(string: label, attributes: [.font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.white.cgColor])
            line = CTLineCreateWithAttributedString(attr)
            width = CTLineGetTypographicBounds(line, nil, nil, nil)
        }
        ctx.saveGState()
        ctx.textMatrix = .identity
        let x = rect.minX + (rect.width - CGFloat(width)) / 2
        let y = rect.minY + (rect.height - fontSize * 0.72) / 2
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private static func jpegImage(_ image: CGImage) -> CGImage? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(dest),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Unsichtbare Textebene, damit das PDF durchsuchbar bleibt (aus dem bereits geschwärzten Bild erkannt).
    private static func drawInvisibleText(_ lines: [OCRLineResult], in ctx: CGContext, size: CGSize) {
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        for line in lines where !line.text.isEmpty {
            let r = CGRect(x: line.box.minX * size.width, y: line.box.minY * size.height,
                           width: line.box.width * size.width, height: line.box.height * size.height)
            guard r.width > 1, r.height > 1 else { continue }
            let fontSize = max(r.height * 0.85, 2)
            let font = NSFont(name: "Helvetica", size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
            let attr = NSAttributedString(string: line.text, attributes: [.font: font])
            let ctLine = CTLineCreateWithAttributedString(attr)
            let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            guard width > 0 else { continue }
            ctx.saveGState()
            ctx.translateBy(x: r.minX, y: r.minY + r.height * 0.18)
            ctx.scaleBy(x: r.width / CGFloat(width), y: 1)
            ctx.textMatrix = .identity
            ctx.textPosition = .zero
            CTLineDraw(ctLine, ctx)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    // MARK: - Protokoll (nur lokal)

    private static func writeProtocol(mandate: Mandate, fileRows: [[String]], renamer: Renamer, folder: URL) throws {
        var stats: [String: (Int, Set<UUID>)] = [:]
        for f in mandate.findings where !f.suppressed {
            var s = stats[f.entityKey] ?? (0, [])
            s.0 += 1
            s.1.insert(f.fileID)
            stats[f.entityKey] = s
        }
        var rows: [[String]] = [["Art", "Rolle", "Name / Begriff", "Ersetzung", "Personalnummer", "Entscheidung", "Fundstellen", "Dokumente", "Quelle"]]
        for e in mandate.entities.values.sorted(by: { ($0.kind.groupOrder, $0.display) < ($1.kind.groupOrder, $1.display) }) {
            let s = stats[e.key] ?? (0, [])
            rows.append([e.kind.shortLabel, e.role?.label ?? "", e.display, e.replacement ?? "", e.personNumber ?? "",
                         e.decision.label, "\(s.0)", "\(s.1.count)", e.sources.sorted().joined(separator: ", ")])
        }
        try csv(rows).write(to: folder.appendingPathComponent("Zuordnung_Namen_Kuerzel.csv"), atomically: true, encoding: .utf8)
        try csv(fileRows).write(to: folder.appendingPathComponent("Dateien.csv"), atomically: true, encoding: .utf8)

        let readme = """
        Prüfprotokoll – \(mandate.name) \(mandate.caseNumber)
        Erstellt: \(Date().formatted(date: .long, time: .shortened))

        Dieser Ordner enthält die Zuordnung von Klarnamen zu Kürzeln.
        NICHT in den Datenraum hochladen und nicht weitergeben.

        Profil: KI-Erkennung \(mandate.profile.useAI ? "an" : "aus"), Kürzel in Balken \(mandate.profile.labelsInBars ? "an" : "aus"),
        Dateinamen: \(mandate.profile.filenameMode.label)
        """
        try readme.write(to: folder.appendingPathComponent("LIESMICH.txt"), atomically: true, encoding: .utf8)
    }

    private static func csv(_ rows: [[String]]) -> String {
        let body = rows.map { row in
            row.map { v in
                let escaped = v.replacingOccurrences(of: "\"", with: "\"\"")
                return escaped.contains(";") || escaped.contains("\"") || escaped.contains("\n") ? "\"\(escaped)\"" : escaped
            }.joined(separator: ";")
        }.joined(separator: "\r\n")
        return "\u{FEFF}" + body
    }
}

// MARK: - Datei- und Ordnernamen

struct Renamer {
    private var rules: [(NSRegularExpression, String)] = []

    init(mandate: Mandate) {
        var employeeByKey: [String: PersonRecord] = [:]
        for p in mandate.employees {
            employeeByKey["ma:" + (p.number.isEmpty ? Norm.compact(p.fullName) : p.number)] = p
        }
        let sortedEmployees = mandate.employees.sorted { ($0.lastName, $0.firstName) < ($1.lastName, $1.firstName) }
        var sequence: [String: Int] = [:]
        for (i, p) in sortedEmployees.enumerated() { sequence[p.id] = i + 1 }

        let joiner = "[\\s_\\-.,]+"
        var collected: [(NSRegularExpression, String, Int)] = []

        for e in mandate.entities.values where e.decision != .keep {
            guard e.kind == .name || e.kind == .company || e.kind == .term else { continue }
            var replacement = Renamer.sanitize(e.replacement ?? "XX")
            var phrases: [String] = []

            if let p = employeeByKey[e.key] {
                switch mandate.profile.filenameMode {
                case .personnelNumber:
                    replacement = Renamer.sanitize(e.replacement ?? (mandate.profile.employeePrefix + p.number))
                case .sequential:
                    replacement = "P-" + String(format: "%03d", sequence[p.id] ?? 0)
                case .initials:
                    replacement = p.initials
                }
                if !p.firstName.isEmpty {
                    phrases.append(p.firstName + " " + p.lastName)
                    phrases.append(p.lastName + " " + p.firstName)
                }
                if p.lastName.count >= 4 { phrases.append(p.lastName) }
            } else {
                phrases.append(contentsOf: e.surfaces.isEmpty ? [e.display] : e.surfaces)
                if e.kind == .name {
                    let tokens = e.display.split(separator: " ").map(String.init)
                    if tokens.count == 2 { phrases.append(tokens[1] + " " + tokens[0]) }
                }
            }
            for phrase in Set(phrases) where phrase.count >= 3 {
                if let re = SearchPattern.regex(for: phrase, joiner: joiner) {
                    collected.append((re, replacement, phrase.count))
                }
            }
        }
        // Längere Treffer zuerst, damit „Hans Müller“ vor „Müller“ ersetzt wird.
        rules = collected.sorted { $0.2 > $1.2 }.map { ($0.0, $0.1) }
    }

    static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return s.components(separatedBy: bad).joined().replacingOccurrences(of: " ", with: "-")
    }

    func renameComponent(_ name: String) -> String {
        var out = name
        for (re, replacement) in rules {
            let ns = out as NSString
            out = re.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: ns.length),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
        }
        return out
    }

    func rename(_ relativePath: String) -> String {
        let parts = relativePath.split(separator: "/").map(String.init)
        return parts.enumerated().map { i, part in
            if i == parts.count - 1 {
                let base = (part as NSString).deletingPathExtension
                let ext = (part as NSString).pathExtension
                let renamed = renameComponent(base)
                return ext.isEmpty ? renamed : renamed + "." + ext
            }
            return renameComponent(part)
        }.joined(separator: "/")
    }
}
