import Foundation
import PDFKit
import AppKit
import CoreText
@preconcurrency import OpenMedKit

/// Selbsttest ohne Oberfläche: `Schwaerzen --selftest <ordner>`.
/// Erzeugt Test-PDFs, führt Erkennung und Export aus und prüft, dass im Ergebnis keine Klarnamen mehr stehen.
enum SelfTest {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--selftest") else { return }
        let dir = i + 1 < args.count ? URL(fileURLWithPath: args[i + 1]) : FileManager.default.temporaryDirectory.appendingPathComponent("schwaerzen-selftest")
        let sem = DispatchSemaphore(value: 0)
        let result = ResultBox()
        Task.detached {
            result.code = await run(in: dir)
            sem.signal()
        }
        sem.wait()
        exit(result.code)
    }

    static let page1 = """
    Arbeitsvertrag

    zwischen der Nordlicht Logistik GmbH, Hafenstraße 4, 20457 Hamburg (Arbeitgeber)
    und Herrn Hans Müller, geboren am 14.03.1979, wohnhaft Lindenweg 12, 22303 Hamburg.

    § 1 Beginn: Das Arbeitsverhältnis beginnt am 01.04.2019. Herr Müller wird als Disponent eingestellt.
    § 4 Vergütung: 4.250,00 EUR brutto auf das Konto IBAN DE89 3704 0044 0532 0130 00.
    § 9 Steuer-ID: 12 345 678 901, Sozialversicherungsnummer 65 140379 M 512.
    Konfession: rk   Steuerklasse: III   Krankenkasse: AOK Rheinland/Hamburg
    Lohnpfändung Gläubiger Nordwest Inkasso GmbH
    E-Mail hans.mueller@example.de, Telefon 040 123 45678
    """

    static let page2 = """
    Nachtrag (Scan)

    Herr Hans Müller erhält ab 01.01.2025 eine Zulage.
    Unterschrift: H. Müller
    """

    static func run(in dir: URL) async -> Int32 {
        var failures: [String] = []
        func check(_ ok: Bool, _ label: String) {
            print((ok ? "OK    " : "FEHLER ") + label)
            if !ok { failures.append(label) }
        }
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // 1. Regeln kompilieren
        check(GermanRules.rules.count >= 17, "Regeln geladen: \(GermanRules.rules.count)")
        check(GermanRules.isValidIBAN("DE89 3704 0044 0532 0130 00"), "IBAN-Prüfziffer gültig")
        check(!GermanRules.isValidIBAN("DE00 1234 5678 9012 3456 78"), "IBAN-Prüfziffer ungültig erkannt")

        // 2. Test-PDF erzeugen (Seite 1 mit Text, Seite 2 nur als Bild → Texterkennung)
        let pdfURL = dir.appendingPathComponent("Arbeitsvertrag_Hans-Mueller.pdf")
        guard makeTestPDF(at: pdfURL) else {
            print("FEHLER Test-PDF konnte nicht erzeugt werden")
            return 1
        }
        check(PDFDocument(url: pdfURL)?.pageCount == 2, "Test-PDF mit 2 Seiten")

        // 3. Mandat mit Personalliste
        var mandate = Mandate(name: "Nordlicht Logistik GmbH", caseNumber: "34 IN 112/26")
        mandate.employees = [PersonRecord(firstName: "Hans", lastName: "Müller", number: "0417")]
        mandate.suppliers = [CompanyRecord(name: "Nordwest Inkasso GmbH", number: "70001")]
        var file = SourceFile(sourcePath: pdfURL.path, relativePath: "Personal/Müller, Hans/Arbeitsvertrag_Hans-Mueller.pdf")
        file.status = .done
        mandate.files = [file]

        let work = Paths.workPDF(mandate.id, file.id)
        try? fm.removeItem(at: work)
        do {
            let method = try await Converter.convert(pdfURL, to: work)
            check(method == "Bereits PDF", "Umwandlung: \(method)")
        } catch {
            check(false, "Umwandlung: \(error.localizedDescription)")
            return 1
        }

        // 4. Text lesen
        let pages: [PageData]
        do {
            pages = try await TextExtractor.extract(pdfURL: work)
        } catch {
            check(false, "Text lesen: \(error.localizedDescription)")
            return 1
        }
        check(pages.count == 2, "Seiten gelesen: \(pages.count)")
        check(pages.first?.isOCR == false, "Seite 1 als Text")
        check(pages.last?.isOCR == true, "Seite 2 per Texterkennung")
        check(pages.last?.text.localizedCaseInsensitiveContains("Müller") == true || pages.last?.text.localizedCaseInsensitiveContains("Muller") == true,
              "Texterkennung liest den Namen: \(pages.last?.text.replacingOccurrences(of: "\n", with: " | ").prefix(120) ?? "")")
        Storage.savePages(pages, mandate: mandate.id, file: file.id)

        // 5. Klassifizierung
        let cls = Classifier.classify(fileName: file.fileName, folderPath: "Personal/Müller, Hans", pages: pages)
        check(cls.type == .personal, "Dokumenttyp: \(cls.type.label)")
        mandate.files[0].docType = cls.type
        let au = Classifier.classify(fileName: "AU_Bescheinigung_2025.pdf", folderPath: "Personal", pages: [])
        check(au.type == .excluded, "AU-Bescheinigung ausgeschlossen: \(au.excludedReason)")

        // 6. Erkennung
        let matcher = ListMatcher(mandate: mandate)
        let mentions = Analyzer.ruleAndListMentions(pages: pages, matcher: matcher)
        let located = Analyzer.locate(mentions, pdfURL: work, pages: pages)
        print("       \(mentions.count) Treffer, \(located.count) mit Position")
        for m in located.prefix(40) {
            print("       · S\(m.page + 1) \(m.source) \(m.kind.rawValue): \(m.surface) [\(m.rects.count) Rechteck(e)]")
        }
        mandate.ingest(located, fileID: file.id)
        let kinds = Set(located.map(\.kind))
        for k in [Kind.name, .bank, .identifier, .religion, .family, .insurer, .birthdate, .contact] {
            check(kinds.contains(k), "erkannt: \(k.label)")
        }
        check(mandate.entities["ma:0417"] != nil, "Mitarbeiter aus Personalliste zugeordnet")
        check(mandate.entities["ma:0417"]?.replacement == "MA-0417", "Ersetzung MA-0417")
        let onPage2 = located.contains { $0.page == 1 && $0.presetKey == "ma:0417" }
        check(onPage2, "Name auch auf der gescannten Seite gefunden")

        // 7. Übertragung
        let extra = Analyzer.propagate(mandateID: mandate.id, files: mandate.files, targets: mandate.propagationTargets(),
                                       existingRanges: mandate.rangeIndex(),
                                       keysPerFile: [file.id: Set(mandate.findings.map(\.entityKey))])
        mandate.findings += extra
        print("       Übertragung: \(extra.count) zusätzliche Fundstellen")

        // 7b. KI-Modell (nur mit --ai, lädt das Modell bei Bedarf)
        if CommandLine.arguments.contains("--ai") {
            do {
                let started = Date()
                let modelDir = try await OpenMedModelStore.downloadMLXModel(repoID: AIDetector.repoID, cacheDirectory: Paths.ownModelCache)
                print("       Modell bereit nach \(Int(Date().timeIntervalSince(started))) s")
                let model = try OpenMed(backend: .mlx(modelDirectoryURL: modelDir))
                let t0 = Date()
                let entities = try model.extractPII(pages[0].text, confidenceThreshold: 0.4, useSmartMerging: false)
                print("       KI: \(entities.count) Treffer in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
                for e in entities.prefix(25) {
                    print("       · \(e.label) \(String(format: "%.2f", e.confidence)): \(e.text)")
                }
                let spans = entities.map { AISpan(label: $0.label, text: $0.text, start: $0.start, end: $0.end, confidence: Double($0.confidence)) }
                let alone = Analyzer.aiMentions(spans, page: pages[0], existing: [], matcher: matcher, includeDates: false)
                for m in alone { print("       → \(m.kind.rawValue) \(m.surface) \(m.presetKey ?? "")") }
                check(alone.contains { $0.kind == .name }, "KI erkennt Namen")
                check(alone.contains { $0.presetKey == "ma:0417" }, "KI-Name der Personalliste zugeordnet")
                let extraAI = Analyzer.aiMentions(spans, page: pages[0], existing: mentions, matcher: matcher, includeDates: false)
                let locatedAI = Analyzer.locate(mentions + extraAI, pdfURL: work, pages: pages)
                mandate.ingest(locatedAI, fileID: file.id)
                print("       KI ergänzt \(extraAI.count) Treffer")
            } catch {
                check(false, "KI-Modell: \(error.localizedDescription)")
            }
        }

        // 8. Dateinamen
        let renamer = Renamer(mandate: mandate)
        let renamed = renamer.rename(file.relativePath)
        check(!renamed.localizedCaseInsensitiveContains("Mueller") && !renamed.localizedCaseInsensitiveContains("Müller"), "Dateiname: \(renamed)")

        // 9. Export
        for (k, var e) in Array(mandate.entities) where e.decision == .pending {
            e.decision = .redact
            mandate.entities[k] = e
        }
        let out = dir.appendingPathComponent("Export", isDirectory: true)
        let proto = dir.appendingPathComponent("Protokoll", isDirectory: true)
        do {
            let result = try await Exporter.export(mandate: mandate,
                                                   settings: ExportSettings(outputFolder: out, protocolFolder: proto, labelsInBars: true,
                                                                            rebuildTextLayer: true, removeMetadata: true, redactPending: true),
                                                   progress: { _, _ in })
            check(result.exported == 1, "Export: \(result.exported) Datei, \(result.boxes) Schwärzungen")
            let files = (fm.enumerator(at: out, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "pdf" }
            check(files.count == 1, "Exportdatei: \(files.first?.path.replacingOccurrences(of: out.path, with: "") ?? "keine")")
            if let f = files.first, let doc = PDFDocument(url: f) {
                check(doc.pageCount == 2, "Export hat 2 Seiten")
                let text = (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: " ")
                print("       Textebene: \(text.replacingOccurrences(of: "\n", with: " ").prefix(300))")
                check(!text.isEmpty, "Textebene vorhanden (durchsuchbar)")
                for secret in ["Hans Müller", "Lindenweg", "DE89", "3704", "12 345 678", "140379", "hans.mueller"] {
                    check(!text.localizedCaseInsensitiveContains(secret), "nicht mehr enthalten: \(secret)")
                }
                check(text.contains("MA-0417") && !text.contains("MA-MA"), "Kürzel MA-0417 sauber in der Textebene")
                check(text.localizedCaseInsensitiveContains("Nordlicht"), "Schuldnerin bleibt sichtbar")
                check(text.contains("4.250") || text.contains("4250"), "Gehalt bleibt sichtbar")
                let attrs = doc.documentAttributes ?? [:]
                check(attrs[PDFDocumentAttribute.authorAttribute] == nil, "keine Autor-Metadaten")
            }
            check(fm.fileExists(atPath: proto.appendingPathComponent("Zuordnung_Namen_Kuerzel.csv").path), "Protokoll geschrieben")
        } catch {
            check(false, "Export: \(error.localizedDescription)")
        }

        // 10. KI-Modell-Bibliothek vorhanden?
        let metallib = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")
        let libs = (fm.enumerator(at: Bundle.main.bundleURL, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "metallib" }
        _ = metallib
        check(!libs.isEmpty, "Metal-Bibliothek für das KI-Modell im Paket: \(libs.map(\.lastPathComponent).joined(separator: ", "))")

        print(failures.isEmpty ? "\nSELBSTTEST BESTANDEN" : "\nSELBSTTEST: \(failures.count) Fehler")
        return failures.isEmpty ? 0 : 2
    }

    // MARK: - Test-PDF

    private static func makeTestPDF(at url: URL) -> Bool {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return false }

        ctx.beginPDFPage(nil)
        drawText(page1, in: box.insetBy(dx: 56, dy: 70), ctx: ctx, size: 11)
        ctx.endPDFPage()

        // Seite 2: Text als Bild (simuliert einen Scan)
        let scale: CGFloat = 2
        if let bmp = CGContext(data: nil, width: Int(box.width * scale), height: Int(box.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            bmp.setFillColor(NSColor.white.cgColor)
            bmp.fill(CGRect(x: 0, y: 0, width: box.width * scale, height: box.height * scale))
            bmp.scaleBy(x: scale, y: scale)
            drawText(page2, in: box.insetBy(dx: 56, dy: 70), ctx: bmp, size: 14)
            if let img = bmp.makeImage() {
                ctx.beginPDFPage(nil)
                ctx.draw(img, in: box)
                ctx.endPDFPage()
            }
        }
        ctx.closePDF()
        return true
    }

    private static func drawText(_ text: String, in rect: CGRect, ctx: CGContext, size: CGFloat) {
        let font = NSFont(name: "Helvetica", size: size) ?? NSFont.systemFont(ofSize: size)
        let attr = NSAttributedString(string: text, attributes: [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.black.cgColor
        ])
        let setter = CTFramesetterCreateWithAttributedString(attr)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        ctx.textMatrix = .identity
        CTFrameDraw(frame, ctx)
    }
}

final class ResultBox: @unchecked Sendable {
    var code: Int32 = 1
}
