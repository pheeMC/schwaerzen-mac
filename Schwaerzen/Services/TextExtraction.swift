import Foundation
import PDFKit
import Vision
import AppKit

struct OCRLineResult {
    var text: String
    /// normalisiert (0…1), Ursprung unten links
    var box: CGRect
}

struct OCRResult {
    var text: String
    var words: [OCRWord]
    var lines: [OCRLineResult]
}

/// Texterkennung mit Apple Vision (lokal).
enum OCREngine {
    static func recognize(_ image: CGImage) async throws -> OCRResult {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let observations = try await request.perform(on: image)
        var text = ""
        var words: [OCRWord] = []
        var lines: [OCRLineResult] = []
        var lineIndex = 0

        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let s = candidate.string
            if s.isEmpty { continue }
            if !text.isEmpty { text += "\n" }
            let base = (text as NSString).length
            text += s
            lines.append(OCRLineResult(text: s, box: observation.boundingBox.cgRect))

            var idx = s.startIndex
            while idx < s.endIndex {
                while idx < s.endIndex, s[idx].isWhitespace { idx = s.index(after: idx) }
                guard idx < s.endIndex else { break }
                var end = idx
                while end < s.endIndex, !s[end].isWhitespace { end = s.index(after: end) }
                let range = idx..<end
                if let region = candidate.boundingBox(for: range) {
                    let ns = NSRange(range, in: s)
                    words.append(OCRWord(start: base + ns.location,
                                         end: base + ns.location + ns.length,
                                         line: lineIndex,
                                         box: Box(region.boundingBox.cgRect)))
                }
                idx = end
            }
            lineIndex += 1
        }
        return OCRResult(text: text, words: words, lines: lines)
    }
}

enum PageGeometry {
    /// Transformation von PDF-Seitenkoordinaten in Anzeigekoordinaten (Drehung, Ursprung 0/0).
    static func displayTransform(for page: PDFPage) -> CGAffineTransform {
        let box = page.bounds(for: .mediaBox)
        let t = page.transform(for: .mediaBox)
        let rotated = box.applying(t).standardized
        return t.concatenating(CGAffineTransform(translationX: -rotated.minX, y: -rotated.minY))
    }

    static func displaySize(for page: PDFPage) -> CGSize {
        let box = page.bounds(for: .mediaBox)
        let r = box.applying(page.transform(for: .mediaBox)).standardized
        return r.size
    }

    /// Rendert die Seite so, wie sie angezeigt wird, als Bitmap.
    static func render(_ page: PDFPage, scale: CGFloat) -> CGImage? {
        let size = displaySize(for: page)
        let w = Int((size.width * scale).rounded())
        let h = Int((size.height * scale).rounded())
        guard w > 0, h > 0 else { return nil }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.interpolationQuality = .high
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }
}

enum TextExtractor {
    /// Liest den Text jeder Seite. Seiten ohne verwertbaren Text werden per Texterkennung gelesen.
    static func extract(pdfURL: URL) async throws -> [PageData] {
        guard let doc = PDFDocument(url: pdfURL) else { throw AppError("PDF konnte nicht geöffnet werden") }
        if doc.isLocked { throw AppError("PDF ist passwortgeschützt") }
        var pages: [PageData] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let size = PageGeometry.displaySize(for: page)
            let native = page.string ?? ""
            let letters = native.reduce(0) { $0 + ($1.isLetter ? 1 : 0) }
            if letters >= 25 {
                pages.append(PageData(index: i, width: Double(size.width), height: Double(size.height),
                                      isOCR: false, text: native, words: []))
            } else if let image = PageGeometry.render(page, scale: 2.5) {
                let result = try await OCREngine.recognize(image)
                pages.append(PageData(index: i, width: Double(size.width), height: Double(size.height),
                                      isOCR: true, text: result.text, words: result.words))
            } else {
                pages.append(PageData(index: i, width: Double(size.width), height: Double(size.height),
                                      isOCR: false, text: "", words: []))
            }
        }
        return pages
    }
}

/// Rechnet Textstellen in Rechtecke auf der Seite um.
enum Locator {
    static func rects(for range: NSRange, page data: PageData, pdfPage: PDFPage?) -> [Box] {
        guard range.location != NSNotFound, range.length > 0 else { return [] }
        if data.isOCR {
            return ocrRects(for: range, data: data)
        }
        guard let pdfPage, let selection = pdfPage.selection(for: range) else { return [] }
        let t = PageGeometry.displayTransform(for: pdfPage)
        var out: [Box] = []
        for line in selection.selectionsByLine() {
            let b = line.bounds(for: pdfPage)
            if b.width > 0.5, b.height > 0.5 {
                out.append(Box(b.applying(t).standardized.insetBy(dx: -0.8, dy: -0.8)))
            }
        }
        return out
    }

    private static func ocrRects(for range: NSRange, data: PageData) -> [Box] {
        let lo = range.location
        let hi = range.location + range.length
        var perLine: [Int: CGRect] = [:]
        for word in data.words where word.end > lo && word.start < hi {
            let r = CGRect(x: word.box.x * data.width, y: word.box.y * data.height,
                           width: word.box.w * data.width, height: word.box.h * data.height)
            perLine[word.line] = perLine[word.line].map { $0.union(r) } ?? r
        }
        return perLine.keys.sorted().compactMap { perLine[$0] }.map { Box($0.insetBy(dx: -1.5, dy: -1.5)) }
    }

    static func snippet(_ text: String, range: NSRange, radius: Int = 48) -> (String, String, String) {
        let ns = text as NSString
        guard range.location != NSNotFound, range.location + range.length <= ns.length else { return ("", "", "") }
        let start = max(0, range.location - radius)
        let end = min(ns.length, range.location + range.length + radius)
        func clean(_ s: String) -> String {
            s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
        }
        let before = clean(ns.substring(with: NSRange(location: start, length: range.location - start)))
        let match = clean(ns.substring(with: range))
        let after = clean(ns.substring(with: NSRange(location: range.location + range.length, length: end - range.location - range.length)))
        return ((start > 0 ? "…" : "") + before, match, after + (end < ns.length ? "…" : ""))
    }
}
