import Foundation
import CoreXLSX

/// Liest Personal-, Kreditoren- und Debitorenlisten aus Excel (.xlsx) oder CSV.
enum ListImporter {
    static func readTable(_ url: URL) throws -> [[String]] {
        switch url.pathExtension.lowercased() {
        case "xlsx", "xlsm":
            return try readXLSX(url)
        case "csv", "txt", "tsv":
            return try readCSV(url)
        default:
            throw AppError("Bitte eine Excel- (.xlsx) oder CSV-Datei wählen")
        }
    }

    private static func readXLSX(_ url: URL) throws -> [[String]] {
        guard let file = XLSXFile(filepath: url.path) else { throw AppError("Excel-Datei konnte nicht geöffnet werden") }
        let shared = try file.parseSharedStrings()
        for workbook in try file.parseWorkbooks() {
            for (_, path) in try file.parseWorksheetPathsAndNames(workbook: workbook) {
                let sheet = try file.parseWorksheet(at: path)
                var rows: [[String]] = []
                for row in sheet.data?.rows ?? [] {
                    var cells: [Int: String] = [:]
                    for cell in row.cells {
                        let col = columnIndex(cell.reference.column.value)
                        var value = ""
                        if let shared, let s = cell.stringValue(shared) {
                            value = s
                        } else if let inline = cell.inlineString?.text {
                            value = inline
                        } else {
                            value = cell.value ?? ""
                        }
                        cells[col] = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    let width = (cells.keys.max() ?? -1) + 1
                    rows.append((0..<max(width, 0)).map { cells[$0] ?? "" })
                }
                if rows.contains(where: { $0.contains { !$0.isEmpty } }) { return rows }
            }
        }
        return []
    }

    private static func columnIndex(_ letters: String) -> Int {
        var n = 0
        for ch in letters.uppercased() {
            guard let a = ch.asciiValue, a >= 65, a <= 90 else { continue }
            n = n * 26 + Int(a - 64)
        }
        return max(n - 1, 0)
    }

    private static func readCSV(_ url: URL) throws -> [[String]] {
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first = lines.first else { return [] }
        let delimiter: Character = first.contains(";") ? ";" : (first.contains("\t") ? "\t" : ",")
        return lines.map { parseLine($0, delimiter: delimiter) }
    }

    private static func parseLine(_ line: String, delimiter: Character) -> [String] {
        var out: [String] = []
        var current = ""
        var quoted = false
        var iterator = line.makeIterator()
        while let ch = iterator.next() {
            if ch == "\"" {
                quoted.toggle()
            } else if ch == delimiter && !quoted {
                out.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        out.append(current.trimmingCharacters(in: .whitespaces))
        return out
    }

    // MARK: - Personal

    static func employees(from rows: [[String]]) -> [PersonRecord] {
        guard !rows.isEmpty else { return [] }
        let headerIndex = rows.prefix(10).firstIndex { row in
            row.contains { h in
                let k = Norm.key(h)
                return k.contains("name") || k.contains("mitarbeiter") || k.contains("personal")
            }
        }
        var lastCol: Int? = nil
        var firstCol: Int? = nil
        var numberCol: Int? = nil
        var fullCol: Int? = nil
        var start = 0

        if let hi = headerIndex {
            start = hi + 1
            for (i, h) in rows[hi].enumerated() {
                let k = Norm.key(h)
                if k.contains("vorname") { firstCol = firstCol ?? i }
                else if k.contains("nachname") || k.contains("familienname") || k == "name" { lastCol = lastCol ?? i }
                else if k.contains("personalnummer") || k.contains("pers nr") || k.contains("persnr") || k.contains("personal nr")
                            || k == "nr" || k == "nummer" || k == "id" || k.contains("mitarbeiternummer") || k.contains("ma nr") {
                    numberCol = numberCol ?? i
                } else if k.contains("mitarbeiter") || k.contains("vollstandiger name") || k.contains("name") {
                    fullCol = fullCol ?? i
                }
            }
            if lastCol != nil && firstCol == nil && fullCol == nil {
                fullCol = lastCol
                lastCol = nil
            }
        } else {
            fullCol = 0
            numberCol = rows.first.map { $0.count > 1 ? 1 : nil } ?? nil
        }

        var out: [PersonRecord] = []
        var seen = Set<String>()
        for row in rows.dropFirst(start) {
            func cell(_ i: Int?) -> String { guard let i, i < row.count else { return "" }; return row[i] }
            var first = cell(firstCol)
            var last = cell(lastCol)
            if last.isEmpty, let _ = fullCol {
                let full = cell(fullCol)
                if full.contains(",") {
                    let parts = full.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    last = parts.first ?? ""
                    first = parts.count > 1 ? parts[1] : ""
                } else {
                    var parts = full.split(separator: " ").map(String.init)
                    last = parts.popLast() ?? ""
                    first = parts.joined(separator: " ")
                }
            }
            var number = cell(numberCol)
            if number.hasSuffix(".0") { number = String(number.dropLast(2)) }
            guard !last.isEmpty, last.rangeOfCharacter(from: .letters) != nil else { continue }
            let record = PersonRecord(firstName: first, lastName: last, number: number)
            if seen.insert(record.id).inserted { out.append(record) }
        }
        return out
    }

    // MARK: - Firmen

    static func companies(from rows: [[String]]) -> [CompanyRecord] {
        guard !rows.isEmpty else { return [] }
        let headerIndex = rows.prefix(10).firstIndex { row in
            row.contains { h in
                let k = Norm.key(h)
                return k.contains("name") || k.contains("firma") || k.contains("bezeichnung") || k.contains("kreditor") || k.contains("debitor")
            }
        }
        var nameCol = 0
        var numberCol: Int? = nil
        var start = 0
        if let hi = headerIndex {
            start = hi + 1
            var nameSet = false
            for (i, h) in rows[hi].enumerated() {
                let k = Norm.key(h)
                if !nameSet && (k.contains("name") || k.contains("firma") || k.contains("bezeichnung")) {
                    nameCol = i; nameSet = true
                } else if numberCol == nil && (k.contains("nr") || k.contains("nummer") || k.contains("konto")) {
                    numberCol = i
                }
            }
        }
        var out: [CompanyRecord] = []
        var seen = Set<String>()
        for row in rows.dropFirst(start) {
            guard nameCol < row.count else { continue }
            let name = row[nameCol].trimmingCharacters(in: .whitespaces)
            guard name.count >= 3, name.rangeOfCharacter(from: .letters) != nil else { continue }
            var number = (numberCol.flatMap { $0 < row.count ? row[$0] : nil }) ?? ""
            if number.hasSuffix(".0") { number = String(number.dropLast(2)) }
            if seen.insert(Norm.key(name)).inserted { out.append(CompanyRecord(name: name, number: number)) }
        }
        return out
    }
}
