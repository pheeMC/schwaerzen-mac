import Foundation
import AppKit
import PDFKit

/// Wandelt Office-, iWork-, Text- und Bilddateien lokal in PDF um.
enum Converter {
    static let pdfTypes: Set<String> = ["pdf"]
    static let imageTypes: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]
    static let wordTypes: Set<String> = ["doc", "docx", "docm", "dot", "dotx", "rtf", "odt", "txt"]
    static let excelTypes: Set<String> = ["xls", "xlsx", "xlsm", "xlsb", "csv", "ods"]
    static let powerPointTypes: Set<String> = ["ppt", "pptx", "pptm", "pps", "ppsx", "odp"]
    static let iWorkTypes: [String: String] = ["pages": "Pages", "numbers": "Numbers", "key": "Keynote"]
    static let ignoredNames: Set<String> = [".DS_Store", "Thumbs.db", "desktop.ini"]

    static func isSupported(_ ext: String) -> Bool {
        let e = ext.lowercased()
        return pdfTypes.contains(e) || imageTypes.contains(e) || wordTypes.contains(e)
            || excelTypes.contains(e) || powerPointTypes.contains(e) || iWorkTypes[e] != nil
    }

    static func shouldIgnore(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return ignoredNames.contains(name) || name.hasPrefix("~$") || name.hasPrefix("._")
    }

    /// Liefert eine kurze Beschreibung des Weges, z. B. „Word“.
    static func convert(_ src: URL, to dest: URL) async throws -> String {
        let ext = src.pathExtension.lowercased()
        let fm = FileManager.default
        try? fm.removeItem(at: dest)

        if pdfTypes.contains(ext) {
            try fm.copyItem(at: src, to: dest)
            guard PDFDocument(url: dest) != nil else { throw AppError("PDF ist beschädigt oder verschlüsselt") }
            return "Bereits PDF"
        }
        if imageTypes.contains(ext) {
            try imageToPDF(src, dest)
            return "Bild"
        }
        if wordTypes.contains(ext) {
            if officeInstalled("com.microsoft.Word") {
                do {
                    try await viaOffice(src, dest, script: wordScript)
                    return "Word"
                } catch {
                    if ext == "txt" || ext == "rtf" {
                        try await MainActor.run { try textToPDF(src, dest) }
                        return "macOS (Text)"
                    }
                    throw error
                }
            }
            try await MainActor.run { try textToPDF(src, dest) }
            return "macOS (Text)"
        }
        if excelTypes.contains(ext) {
            guard officeInstalled("com.microsoft.Excel") else { throw AppError("Microsoft Excel nicht gefunden") }
            try await viaOffice(src, dest, script: excelScript)
            return "Excel"
        }
        if powerPointTypes.contains(ext) {
            guard officeInstalled("com.microsoft.Powerpoint") else { throw AppError("Microsoft PowerPoint nicht gefunden") }
            try await viaOffice(src, dest, script: powerPointScript)
            return "PowerPoint"
        }
        if let app = iWorkTypes[ext] {
            try await viaIWork(src, dest, app: app)
            return app
        }
        throw AppError("Dateityp .\(ext) wird nicht unterstützt")
    }

    // MARK: - Office über AppleScript

    static func officeInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    private static func viaOffice(_ src: URL, _ dest: URL, script: String) async throws {
        let staging = Paths.officeStaging
        let token = UUID().uuidString
        let stagedIn = staging.appendingPathComponent("\(token).\(src.pathExtension)")
        let stagedOut = staging.appendingPathComponent("\(token).pdf")
        let fm = FileManager.default
        try fm.copyItem(at: src, to: stagedIn)
        defer {
            try? fm.removeItem(at: stagedIn)
            try? fm.removeItem(at: stagedOut)
        }
        _ = try await Task.detached(priority: .userInitiated) {
            try runAppleScript(script, args: [stagedIn.path, stagedOut.path], timeout: 240)
        }.value
        guard fm.fileExists(atPath: stagedOut.path) else {
            throw AppError("Office hat kein PDF erzeugt")
        }
        try fm.moveItem(at: stagedOut, to: dest)
        guard PDFDocument(url: dest) != nil else { throw AppError("Erzeugtes PDF ist nicht lesbar") }
    }

    private static func viaIWork(_ src: URL, _ dest: URL, app: String) async throws {
        let staging = Paths.ensure(FileManager.default.temporaryDirectory.appendingPathComponent("Schwaerzen-iWork", isDirectory: true))
        let out = staging.appendingPathComponent("\(UUID().uuidString).pdf")
        let script = """
        on run argv
            set inFile to POSIX file (item 1 of argv)
            set outFile to POSIX file (item 2 of argv)
            tell application "\(app)"
                set theDoc to open inFile
                delay 0.5
                export theDoc to outFile as PDF
                close theDoc saving no
            end tell
            return "ok"
        end run
        """
        _ = try await Task.detached(priority: .userInitiated) {
            try runAppleScript(script, args: [src.path, out.path], timeout: 240)
        }.value
        guard FileManager.default.fileExists(atPath: out.path) else { throw AppError("\(app) hat kein PDF erzeugt") }
        try FileManager.default.moveItem(at: out, to: dest)
    }

    static let wordScript = """
    on run argv
        set inFile to POSIX file (item 1 of argv)
        set outHFS to (POSIX file (item 2 of argv)) as text
        tell application "Microsoft Word"
            open inFile
            delay 0.5
            set theDoc to active document
            save as theDoc file name outHFS file format format PDF
            close theDoc saving no
        end tell
        return "ok"
    end run
    """

    static let excelScript = """
    on run argv
        set inFile to POSIX file (item 1 of argv)
        set outHFS to (POSIX file (item 2 of argv)) as text
        tell application "Microsoft Excel"
            open inFile
            delay 0.5
            set wb to active workbook
            save workbook as wb filename outHFS file format PDF file format
            close wb saving no
        end tell
        return "ok"
    end run
    """

    static let powerPointScript = """
    on run argv
        set inFile to POSIX file (item 1 of argv)
        set outHFS to (POSIX file (item 2 of argv)) as text
        tell application "Microsoft PowerPoint"
            open inFile
            delay 1
            set pres to active presentation
            save pres in outHFS as save as PDF
            close pres
        end tell
        return "ok"
    end run
    """

    static func runAppleScript(_ source: String, args: [String], timeout: TimeInterval) throws -> String {
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("schwaerzen-\(UUID().uuidString).applescript")
        try source.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [scriptURL.path] + args
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            process.terminate()
            throw AppError("Zeitüberschreitung bei der Umwandlung")
        }
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let outText = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let cleaned = errText.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.contains("-1743") {
                throw AppError("Keine Erlaubnis, Office zu steuern. Systemeinstellungen → Datenschutz & Sicherheit → Automation → Schwärzen erlauben.")
            }
            throw AppError(cleaned.isEmpty ? "Umwandlung fehlgeschlagen" : cleaned)
        }
        return outText
    }

    // MARK: - Ohne Office

    private static func imageToPDF(_ src: URL, _ dest: URL) throws {
        guard let image = NSImage(contentsOf: src), let page = PDFPage(image: image) else {
            throw AppError("Bild konnte nicht gelesen werden")
        }
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        guard doc.write(to: dest) else { throw AppError("PDF konnte nicht geschrieben werden") }
    }

    @MainActor
    static func textToPDF(_ src: URL, _ dest: URL) throws {
        let attributed = try NSAttributedString(url: src, options: [:], documentAttributes: nil)
        let paper = NSSize(width: 595, height: 842)
        let margin: CGFloat = 56
        let width = paper.width - 2 * margin

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 200))
        textView.textStorage?.setAttributedString(attributed)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        if let container = textView.textContainer, let layout = textView.layoutManager {
            container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            container.widthTracksTextView = true
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            textView.frame = NSRect(x: 0, y: 0, width: width, height: max(used.height + 24, 200))
        }

        let info = NSPrintInfo(dictionary: [NSPrintInfo.AttributeKey.jobSavingURL: dest])
        info.jobDisposition = .save
        info.paperSize = paper
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic

        let op = NSPrintOperation(view: textView, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run(), FileManager.default.fileExists(atPath: dest.path) else {
            throw AppError("Text konnte nicht in PDF umgewandelt werden")
        }
    }
}
