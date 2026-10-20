import Foundation
import PDFKit

/// Eine erkannte Textstelle, bevor sie einer Person / einem Begriff zugeordnet wird.
struct Mention {
    var page: Int
    var range: NSRange
    var surface: String
    var kind: Kind
    var role: Role?
    var presetKey: String?
    var personNumber: String?
    var confidence: Double
    var source: String
    var label: String
    var rects: [Box] = []
    var before: String = ""
    var after: String = ""
}

// MARK: - Listen (Personal, Lieferanten, Kunden, Immer-Liste)

struct ListTarget {
    let key: String
    let display: String
    let kind: Kind
    let role: Role?
    let number: String?
    let prefilter: String
    let regexes: [NSRegularExpression]
    let titled: NSRegularExpression?
    let surname: NSRegularExpression?
}

final class ListMatcher {
    let targets: [ListTarget]
    let neverKeys: [String]
    /// Norm.key-Varianten von Mitarbeiternamen → Schlüssel
    let employeeKeys: [String: ListTarget]

    init(mandate: Mandate) {
        var list: [ListTarget] = []
        var byName: [String: ListTarget] = [:]

        for p in mandate.employees where !p.lastName.isEmpty {
            let key = "ma:" + (p.number.isEmpty ? Norm.compact(p.fullName) : p.number)
            var phrases: [String] = [p.lastName]
            if !p.firstName.isEmpty {
                phrases = [p.firstName + " " + p.lastName, p.lastName + ", " + p.firstName, p.lastName + " " + p.firstName]
            }
            var regexes = phrases.compactMap { SearchPattern.regex(for: $0) }
            if let initial = p.firstName.first {
                let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: String(initial))
                    + "\\.\\s?" + p.lastName.split(separator: " ").map { SearchPattern.tokenPattern(String($0)) }.joined(separator: "\\s+")
                    + "(?![\\p{L}\\p{N}])"
                if let re = try? NSRegularExpression(pattern: pattern, options: []) { regexes.append(re) }
            }
            let lastPattern = p.lastName.split(separator: " ").map { SearchPattern.tokenPattern(String($0)) }.joined(separator: "\\s+")
            let titled = try? NSRegularExpression(
                pattern: "(?:Herrn?|Frau|Hr\\.|Fr\\.)\\s+(" + lastPattern + ")(?![\\p{L}\\p{N}])", options: [])
            let surname = p.lastName.count >= 4 ? SearchPattern.regex(for: p.lastName) : nil
            let target = ListTarget(key: key, display: p.fullName, kind: .name, role: .employee,
                                    number: p.number.isEmpty ? nil : p.number,
                                    prefilter: Norm.compact(p.lastName), regexes: regexes,
                                    titled: titled, surname: surname)
            list.append(target)
            if !p.firstName.isEmpty {
                byName[Norm.key(p.firstName + " " + p.lastName)] = target
                byName[Norm.key(p.lastName + " " + p.firstName)] = target
            }
        }

        func companyTargets(_ items: [CompanyRecord], role: Role, prefix: String) -> [ListTarget] {
            items.compactMap { c in
                let name = c.name.trimmingCharacters(in: .whitespaces)
                guard name.count >= 3 else { return nil }
                let core = ListMatcher.coreCompanyName(name)
                var regexes = [SearchPattern.regex(for: name)].compactMap { $0 }
                if core != name, core.count >= 5, let re = SearchPattern.regex(for: core) { regexes.append(re) }
                return ListTarget(key: prefix + Norm.compact(name), display: name, kind: .company, role: role,
                                  number: c.number.isEmpty ? nil : c.number,
                                  prefilter: Norm.compact(core.count >= 3 ? core : name), regexes: regexes,
                                  titled: nil, surname: nil)
            }
        }
        list += companyTargets(mandate.suppliers, role: .supplier, prefix: "lf:")
        list += companyTargets(mandate.customers, role: .customer, prefix: "kd:")

        for term in mandate.alwaysTerms {
            let t = term.trimmingCharacters(in: .whitespaces)
            guard t.count >= 2, let re = SearchPattern.regex(for: t) else { continue }
            list.append(ListTarget(key: "t:" + Norm.compact(t), display: t, kind: .term, role: nil, number: nil,
                                   prefilter: Norm.compact(t), regexes: [re], titled: nil, surname: nil))
        }

        targets = list
        employeeKeys = byName
        neverKeys = mandate.neverTerms.map { Norm.key($0) }.filter { !$0.isEmpty }
    }

    static func coreCompanyName(_ name: String) -> String {
        let forms = ["gmbh & co. kg", "gmbh & co kg", "gmbh", "mbh", "ag & co. kg", "ag", "kg", "ohg", "gbr", "ug (haftungsbeschränkt)",
                     "ug", "e.k.", "e. k.", "e.v.", "e. v.", "se", "ltd.", "ltd", "inc.", "inc", "co. kg", "kgaa"]
        var s = name
        var changed = true
        while changed {
            changed = false
            let lower = s.lowercased()
            for f in forms where lower.hasSuffix(" " + f) {
                s = String(s.dropLast(f.count + 1)).trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
                changed = true
                break
            }
        }
        return s
    }

    func isNever(_ text: String) -> Bool {
        let k = " " + Norm.key(text) + " "
        return neverKeys.contains { k.contains(" " + $0 + " ") }
    }

    func hits(in page: PageData, compact: String) -> [Mention] {
        var out: [Mention] = []
        for t in targets where compact.contains(t.prefilter) {
            var found = false
            for re in t.regexes {
                for r in SearchPattern.matches(re, in: page.text) {
                    out.append(mention(t, page: page, range: r, confidence: 1))
                    found = true
                }
            }
            if let titled = t.titled {
                let ns = page.text as NSString
                for m in titled.matches(in: page.text, range: NSRange(location: 0, length: ns.length)) {
                    let r = m.range(at: 1)
                    if r.location != NSNotFound { out.append(mention(t, page: page, range: r, confidence: 0.97)); found = true }
                }
            }
            _ = found
        }
        return ListMatcher.removeOverlaps(out)
    }

    /// Nachname allein – nur in Dateien, in denen die Person schon sicher gefunden wurde.
    func surnameHits(in page: PageData, compact: String, keys: Set<String>) -> [Mention] {
        var out: [Mention] = []
        for t in targets where keys.contains(t.key) && compact.contains(t.prefilter) {
            guard let re = t.surname else { continue }
            for r in SearchPattern.matches(re, in: page.text) {
                out.append(mention(t, page: page, range: r, confidence: 0.9))
            }
        }
        return out
    }

    private func mention(_ t: ListTarget, page: PageData, range: NSRange, confidence: Double) -> Mention {
        let surface = (page.text as NSString).substring(with: range)
        return Mention(page: page.index, range: range, surface: surface, kind: t.kind, role: t.role,
                       presetKey: t.key, personNumber: t.number, confidence: confidence,
                       source: t.kind == .term ? "Begriff" : "Liste", label: t.display)
    }

    /// Bei Überschneidungen gewinnt der längere Treffer.
    static func removeOverlaps(_ items: [Mention]) -> [Mention] {
        let sorted = items.sorted {
            if $0.page != $1.page { return $0.page < $1.page }
            if $0.range.length != $1.range.length { return $0.range.length > $1.range.length }
            return $0.range.location < $1.range.location
        }
        var kept: [Mention] = []
        for m in sorted {
            let overlaps = kept.contains { k in
                k.page == m.page && NSIntersectionRange(k.range, m.range).length > 0
            }
            if !overlaps { kept.append(m) }
        }
        return kept
    }
}

// MARK: - Analyse einer Datei

enum Analyzer {
    /// Regeln + Listen (ohne KI). Läuft im Hintergrund.
    static func ruleAndListMentions(pages: [PageData], matcher: ListMatcher) -> [Mention] {
        var out: [Mention] = []
        var listKeysInFile = Set<String>()
        var compacts: [Int: String] = [:]

        for page in pages where !page.text.isEmpty {
            let compact = Norm.compact(page.text)
            compacts[page.index] = compact
            let listHits = matcher.hits(in: page, compact: compact)
            listHits.forEach { if let k = $0.presetKey { listKeysInFile.insert(k) } }
            out += listHits

            for hit in GermanRules.hits(in: page.text) {
                if matcher.isNever(hit.text) { continue }
                out.append(Mention(page: page.index, range: hit.range, surface: hit.text, kind: hit.kind, role: nil,
                                   presetKey: nil, personNumber: nil, confidence: hit.confidence,
                                   source: "Regel", label: hit.label))
            }
        }

        if !listKeysInFile.isEmpty {
            for page in pages where !page.text.isEmpty {
                out += matcher.surnameHits(in: page, compact: compacts[page.index] ?? "", keys: listKeysInFile)
            }
        }
        return ListMatcher.removeOverlaps(out)
    }

    /// Wandelt KI-Treffer einer Seite in Mentions um.
    static func aiMentions(_ spans: [AISpan], page: PageData, existing: [Mention], matcher: ListMatcher,
                           includeDates: Bool) -> [Mention] {
        var out: [Mention] = []
        let ns = page.text as NSString
        let taken = existing.filter { $0.page == page.index }.map(\.range)

        // 1. Offsets prüfen (Scalar-Offsets → NSRange), sonst Text suchen
        struct Raw { var kind: Kind; var range: NSRange; var confidence: Double; var label: String }
        var raws: [Raw] = []
        for span in spans {
            guard let kind = AIDetector.kind(for: span.label) else { continue }
            if kind == .date && !includeDates { continue }
            var range = nsRange(scalarStart: span.start, scalarEnd: span.end, in: page.text)
            if let r = range, Norm.key(ns.substring(with: r)) != Norm.key(span.text) { range = nil }
            guard let found = range ?? search(span.text, in: page.text) else { continue }
            raws.append(Raw(kind: kind, range: found, confidence: span.confidence, label: span.label))
        }
        // 2. Benachbarte Teile zusammenfügen („Hans“ + „Müller“ → „Hans Müller“)
        raws.sort { $0.range.location < $1.range.location }
        var merged: [Raw] = []
        for r in raws {
            if var last = merged.last, last.kind == r.kind, last.kind == .name || last.kind == .address {
                let gapStart = last.range.location + last.range.length
                let gapLength = r.range.location - gapStart
                if gapLength >= 0 && gapLength <= 2 {
                    let gap = ns.substring(with: NSRange(location: gapStart, length: gapLength))
                    let allowedGaps: Set<String> = last.kind == .address ? ["", " ", "-", ", "] : ["", " ", "-"]
                    if allowedGaps.contains(gap) {
                        last.range = NSRange(location: last.range.location, length: r.range.location + r.range.length - last.range.location)
                        last.confidence = max(last.confidence, r.confidence)
                        merged[merged.count - 1] = last
                        continue
                    }
                }
            }
            merged.append(r)
        }

        for raw in merged {
            var kind = raw.kind
            var range = raw.range
            var surface = ns.substring(with: range)

            if kind == .name {
                let (stripped, removed) = Norm.stripTitles(surface)
                if removed > 0 {
                    range = NSRange(location: range.location + removed, length: max(0, range.length - removed))
                    surface = stripped
                }
                // Tabellenzeilen: „Müller Robert Straße des Friedens 18“ → „Müller Robert“
                let (kept, leading) = Analyzer.namePrefix(surface)
                if kept.isEmpty { continue }
                range = NSRange(location: range.location + leading, length: (kept as NSString).length)
                surface = kept
                if surface.count < 3 || !(surface.first?.isUppercase ?? false) { continue }
                if surface.split(separator: " ").count == 1 && Norm.isMostlyUppercaseWord(surface) && surface.count <= 5 { continue }
            }
            if kind == .address {
                let cleaned = Analyzer.cleanAddress(surface)
                if cleaned.isEmpty { continue }
                range = NSRange(location: range.location, length: (cleaned as NSString).length)
                surface = cleaned
            }
            if range.length <= 0 { continue }
            if matcher.isNever(surface) { continue }
            if taken.contains(where: { NSIntersectionRange($0, range).length > 0 }) { continue }

            var role: Role? = nil
            var preset: String? = nil
            var number: String? = nil
            if kind == .name {
                if let t = matcher.employeeKeys[Norm.key(surface)] {
                    preset = t.key; role = .employee; number = t.number; kind = .name
                } else {
                    role = .unknown
                }
            }
            out.append(Mention(page: page.index, range: range, surface: surface, kind: kind, role: role,
                               presetKey: preset, personNumber: number, confidence: raw.confidence,
                               source: "KI", label: raw.label))
        }
        return out
    }

    private static let addressCues: Set<String> = [
        "straße", "strasse", "str.", "str", "weg", "allee", "platz", "ring", "gasse", "damm", "ufer", "chaussee",
        "zum", "zur", "am", "an", "auf", "im", "in", "alte", "alter", "neue", "neuer", "hinter", "vor", "unter", "ober",
        "deutsch", "deutschland", "staatsangehörigkeit", "plz", "ort"
    ]
    private static let streetSuffixes = ["straße", "strasse", "str.", "weg", "allee", "platz", "ring", "gasse", "damm",
                                         "ufer", "chaussee", "graben", "bruch", "steig", "pfad", "markt", "hof"]

    /// Schneidet einen erkannten Namen vor dem ersten Adress-Signal ab (Tabellen ohne Zellgrenzen im Text).
    /// Liefert den behaltenen Text und die Zahl der am Anfang übersprungenen UTF-16-Zeichen.
    static func namePrefix(_ s: String) -> (String, Int) {
        let skip = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
        var start = s.startIndex
        while start < s.endIndex, s[start].unicodeScalars.allSatisfy({ skip.contains($0) }) { start = s.index(after: start) }
        let leading = s.utf16.distance(from: s.startIndex, to: start)
        var idx = start
        var lastEnd: String.Index? = nil
        var count = 0
        while idx < s.endIndex {
            while idx < s.endIndex, s[idx].isWhitespace { idx = s.index(after: idx) }
            guard idx < s.endIndex else { break }
            var end = idx
            while end < s.endIndex, !s[end].isWhitespace { end = s.index(after: end) }
            var token = String(s[idx..<end])
            while let last = token.last, last == "," || last == ";" || last == ":" { token.removeLast() }
            let lower = token.lowercased()
            if addressCues.contains(lower) { break }
            if token.contains(where: { $0.isNumber }) { break }
            if count >= 1 && lower.count > 4 && streetSuffixes.contains(where: { lower.hasSuffix($0) }) { break }
            lastEnd = s.index(idx, offsetBy: token.count)
            count += 1
            if count == 4 { break }
            idx = end
        }
        guard let e = lastEnd else { return ("", leading) }
        return (String(s[start..<e]), leading)
    }

    /// Entfernt Staatsangehörigkeit u. Ä. am Ende und verwirft reine Zahlen.
    static func cleanAddress(_ s: String) -> String {
        var tokens = s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;")))
            .split(separator: " ").map(String.init)
        let tail: Set<String> = ["deutsch", "deutschland", "de", "germany", "staatsangehörigkeit"]
        while let last = tokens.last, tail.contains(last.lowercased()) { tokens.removeLast() }
        let joined = tokens.joined(separator: " ")
        let letters = joined.filter { $0.isLetter }.count
        if letters < 3 || joined.count < 6 { return "" }
        return joined
    }

    static func nsRange(scalarStart: Int, scalarEnd: Int, in text: String) -> NSRange? {
        let scalars = text.unicodeScalars
        guard scalarStart >= 0, scalarStart < scalarEnd, scalarEnd <= scalars.count else { return nil }
        let s = scalars.index(scalars.startIndex, offsetBy: scalarStart)
        let e = scalars.index(scalars.startIndex, offsetBy: scalarEnd)
        return NSRange(s..<e, in: text)
    }

    static func search(_ needle: String, in text: String) -> NSRange? {
        let n = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return nil }
        let r = (text as NSString).range(of: n, options: [.caseInsensitive])
        return r.location == NSNotFound ? nil : r
    }

    /// Ergänzt Rechtecke und Textausschnitte.
    static func locate(_ mentions: [Mention], pdfURL: URL, pages: [PageData]) -> [Mention] {
        let doc = PDFDocument(url: pdfURL)
        var byIndex: [Int: PageData] = [:]
        pages.forEach { byIndex[$0.index] = $0 }
        return mentions.compactMap { m in
            guard let data = byIndex[m.page] else { return nil }
            var copy = m
            copy.rects = Locator.rects(for: m.range, page: data, pdfPage: doc?.page(at: m.page))
            let (b, _, a) = Locator.snippet(data.text, range: m.range)
            copy.before = b
            copy.after = a
            return copy.rects.isEmpty ? nil : copy
        }
    }

    // MARK: Übertragung auf alle Dokumente

    struct PropagationTarget {
        let key: String
        let regexes: [NSRegularExpression]
        let prefilters: [String]
        let surname: NSRegularExpression?
        let surnamePrefilter: String
    }

    /// Sucht alle bekannten Personen/Begriffe in allen Dokumenten, damit eine Entscheidung überall gilt.
    static func propagate(mandateID: UUID, files: [SourceFile], targets: [PropagationTarget],
                          existingRanges: [String: [NSRange]], keysPerFile: [UUID: Set<String>]) -> [Finding] {
        var out: [Finding] = []
        var taken = existingRanges
        for file in files where file.status == .done && file.docType != .excluded {
            let pages = Storage.loadPages(mandate: mandateID, file: file.id)
            if pages.isEmpty { continue }
            var doc: PDFDocument?
            let inFile = keysPerFile[file.id] ?? []
            for page in pages where !page.text.isEmpty {
                let compact = Norm.compact(page.text)
                for t in targets {
                    var ranges: [NSRange] = []
                    for (i, re) in t.regexes.enumerated() where compact.contains(t.prefilters[i]) {
                        ranges += SearchPattern.matches(re, in: page.text)
                    }
                    if let s = t.surname, inFile.contains(t.key), compact.contains(t.surnamePrefilter) {
                        ranges += SearchPattern.matches(s, in: page.text)
                    }
                    let pageKey = "\(file.id.uuidString)|\(page.index)"
                    for r in ranges {
                        if (taken[pageKey] ?? []).contains(where: { NSIntersectionRange($0, r).length > 0 }) { continue }
                        if !page.isOCR && doc == nil { doc = PDFDocument(url: Paths.workPDF(mandateID, file.id)) }
                        let rects = Locator.rects(for: r, page: page, pdfPage: doc?.page(at: page.index))
                        if rects.isEmpty { continue }
                        taken[pageKey, default: []].append(r)
                        let (b, mt, a) = Locator.snippet(page.text, range: r)
                        out.append(Finding(entityKey: t.key, fileID: file.id, page: page.index, location: r.location,
                                           length: r.length, rects: rects, before: b, matched: mt, after: a))
                    }
                }
            }
        }
        return out
    }
}

// MARK: - Übernahme in das Mandat

extension Mandate {
    static func findingID(_ f: Finding) -> String { "\(f.fileID.uuidString)|\(f.page)|\(f.location)" }

    /// Belegte Textbereiche je Datei und Seite (für die Übertragung ohne Doppelungen).
    func rangeIndex() -> [String: [NSRange]] {
        var out: [String: [NSRange]] = [:]
        for f in findings where f.length > 0 {
            out["\(f.fileID.uuidString)|\(f.page)", default: []].append(NSRange(location: f.location, length: f.length))
        }
        return out
    }

    func entityKey(for m: Mention) -> String {
        if let k = m.presetKey { return k }
        switch m.kind {
        case .name: return "n:" + Norm.compact(m.surface)
        default: return m.kind.rawValue + ":" + Norm.compact(m.surface)
        }
    }

    func isNeverTerm(_ text: String) -> Bool {
        let k = " " + Norm.key(text) + " "
        return neverTerms.map { Norm.key($0) }.filter { !$0.isEmpty }.contains { k.contains(" " + $0 + " ") }
    }

    private func autoDecision(_ m: Mention, docType: DocType) -> (Decision, Bool, String) {
        if isNeverTerm(m.surface) { return (.keep, true, "Nie-Liste") }
        if m.kind == .term { return (.redact, true, "Immer-Liste") }
        if m.kind.locked { return (.redact, true, "Feste Regel") }
        if m.source == "Liste" { return (.redact, false, "") }
        if docType.isPersonal && m.source == "Regel" && (m.kind == .address || m.kind == .contact) { return (.redact, false, "") }
        if m.source == "Regel" && m.confidence >= 0.9 { return (.redact, false, "") }
        if docType.isPersonal && m.confidence >= profile.autoThreshold { return (.redact, false, "") }
        return (.pending, false, "")
    }

    private mutating func replacement(for m: Mention) -> String? {
        switch m.kind {
        case .name:
            if m.role == .employee {
                if let n = m.personNumber, !n.isEmpty { return profile.employeePrefix + n }
                return nextNumber(for: .employee)
            }
            return nextNumber(for: m.role ?? .unknown)
        case .company:
            return nextNumber(for: m.role ?? .partner)
        default:
            return nil
        }
    }

    /// Ersetzt die Fundstellen einer Datei durch die neue Analyse.
    mutating func ingest(_ mentions: [Mention], fileID: UUID) {
        guard let file = file(fileID) else { return }
        findings.removeAll { $0.fileID == fileID && $0.entityKey != "manual" }
        var seen = Set(findings.filter { $0.fileID == fileID }.map(Mandate.findingID))

        for m in mentions {
            let key = entityKey(for: m)
            let auto = autoDecision(m, docType: file.docType)
            if var e = entities[key] {
                e.sources.insert(m.source)
                e.confidence = max(e.confidence, m.confidence)
                if (m.kind == .name || m.kind == .company || m.kind == .term),
                   !e.surfaces.contains(where: { Norm.key($0) == Norm.key(m.surface) }), e.surfaces.count < 10 {
                    e.surfaces.append(m.surface)
                }
                if !e.userDecided && !e.locked && e.decision == .pending && auto.0 == .redact {
                    e.decision = .redact
                }
                entities[key] = e
            } else {
                let display = m.presetKey != nil && (m.source == "Liste" || m.source == "Begriff") ? m.label : m.surface
                var e = Entity(key: key, display: display, kind: m.kind, role: m.role,
                               replacement: replacement(for: m), decision: auto.0)
                e.locked = auto.1
                e.lockReason = auto.2
                e.sources = [m.source]
                e.confidence = m.confidence
                e.personNumber = m.personNumber
                e.surfaces = (m.kind == .name || m.kind == .company || m.kind == .term) ? [m.surface] : []
                if m.source == "Regel" { e.note = m.label }
                entities[key] = e
            }

            let f = Finding(entityKey: key, fileID: fileID, page: m.page, location: m.range.location,
                            length: m.range.length, rects: m.rects, before: m.before, matched: m.surface, after: m.after)
            let id = Mandate.findingID(f)
            if seen.contains(id) { continue }
            seen.insert(id)
            findings.append(f)
        }
    }

    /// Ziele für die Übertragung auf alle Dokumente.
    func propagationTargets() -> [Analyzer.PropagationTarget] {
        var lastNames: [String: String] = [:]
        for p in employees {
            let key = "ma:" + (p.number.isEmpty ? Norm.compact(p.fullName) : p.number)
            lastNames[key] = p.lastName
        }
        return entities.values.compactMap { e in
            guard e.decision != .keep, e.kind == .name || e.kind == .company || e.kind == .term else { return nil }
            let surfaces = e.surfaces.filter { $0.count >= 4 }
            var regexes: [NSRegularExpression] = []
            var prefilters: [String] = []
            for s in surfaces {
                if let re = SearchPattern.regex(for: s) {
                    regexes.append(re)
                    prefilters.append(Norm.compact(s.split(separator: " ").last.map(String.init) ?? s))
                }
            }
            var surname: NSRegularExpression? = nil
            var surnamePrefilter = ""
            if let last = lastNames[e.key], last.count >= 4 {
                surname = SearchPattern.regex(for: last)
                surnamePrefilter = Norm.compact(last)
            }
            if regexes.isEmpty && surname == nil { return nil }
            return Analyzer.PropagationTarget(key: e.key, regexes: regexes, prefilters: prefilters,
                                              surname: surname, surnamePrefilter: surnamePrefilter)
        }
    }
}
