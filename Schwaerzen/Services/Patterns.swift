import Foundation

// MARK: - Normalisierung

enum Norm {
    private static let locale = Locale(identifier: "de_DE")

    /// Vergleichsschlüssel: klein, ohne Akzente, ä→a/ae→a usw., nur Buchstaben/Ziffern mit Leerzeichen.
    static func key(_ s: String) -> String {
        var t = s.lowercased()
        for (a, b) in [("ä", "a"), ("ö", "o"), ("ü", "u"), ("ß", "ss"), ("ae", "a"), ("oe", "o"), ("ue", "u")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        t = t.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: locale)
        let parts = t.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }

    /// Wie `key`, aber ohne Leerzeichen – für schnelles Vorfiltern.
    static func compact(_ s: String) -> String {
        key(s).replacingOccurrences(of: " ", with: "")
    }

    static let titles: [String] = ["herrn", "herr", "frau", "hr.", "fr.", "dr.", "prof.", "dipl.-ing.", "dipl.", "ing.", "mag."]

    /// Entfernt Anreden und Titel am Anfang. Gibt den bereinigten Text und die Anzahl entfernter UTF-16-Zeichen zurück.
    static func stripTitles(_ s: String) -> (String, Int) {
        var text = s
        var removed = 0
        var changed = true
        while changed {
            changed = false
            let trimmed = text.drop(while: { $0 == " " })
            removed += text.utf16.count - String(trimmed).utf16.count
            text = String(trimmed)
            let lower = text.lowercased()
            for title in titles where lower.hasPrefix(title + " ") || lower.hasPrefix(title + "\n") {
                let cut = title.utf16.count + 1
                removed += cut
                text = String(text.dropFirst(title.count + 1))
                changed = true
                break
            }
        }
        return (text, removed)
    }

    static func isMostlyUppercaseWord(_ s: String) -> Bool {
        let letters = s.filter { $0.isLetter }
        return !letters.isEmpty && letters.allSatisfy { $0.isUppercase }
    }
}

// MARK: - Suchmuster

enum SearchPattern {
    /// Baut einen regulären Ausdruck für eine Wortfolge: Umlaut-Varianten, flexible Leerzeichen, Wortgrenzen.
    static func regex(for phrase: String, joiner: String = "[\\s\\u00A0]+") -> NSRegularExpression? {
        let tokens = phrase.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        let body = tokens.map(tokenPattern).joined(separator: joiner)
        let pattern = "(?<![\\p{L}\\p{N}])" + body + "(?![\\p{L}\\p{N}])"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    static func tokenPattern(_ token: String) -> String {
        let chars = Array(token)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            let lower = Character(c.lowercased())
            if let next, next == "e" || next == "E" {
                switch lower {
                case "a": out += "(?:ä|ae|a\\u0308)"; i += 2; continue
                case "o": out += "(?:ö|oe|o\\u0308)"; i += 2; continue
                case "u": out += "(?:ü|ue|u\\u0308)"; i += 2; continue
                default: break
                }
            }
            switch lower {
            case "ä": out += "(?:ä|ae|a\\u0308)"
            case "ö": out += "(?:ö|oe|o\\u0308)"
            case "ü": out += "(?:ü|ue|u\\u0308)"
            case "ß": out += "(?:ß|ss)"
            case "-": out += "[\\-\\u2010\\u2011\\u2013]\\s?"
            default: out += NSRegularExpression.escapedPattern(for: String(c))
            }
            i += 1
        }
        return out
    }

    static func matches(_ regex: NSRegularExpression, in text: String) -> [NSRange] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { $0.range }
    }
}

// MARK: - Feste Regeln (deutschsprachige Unterlagen)

struct RuleHit {
    var kind: Kind
    var label: String
    var range: NSRange
    var text: String
    var confidence: Double
}

enum GermanRules {
    struct Rule {
        let label: String
        let kind: Kind
        let regex: NSRegularExpression
        let group: Int
        let confidence: Double
        let validate: ((String) -> Bool)?
    }

    static let rules: [Rule] = build()

    private static func rule(_ label: String, _ kind: Kind, _ pattern: String, group: Int = 0,
                             confidence: Double = 0.99, validate: ((String) -> Bool)? = nil) -> Rule? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else {
            print("Regel konnte nicht kompiliert werden: \(label)")
            return nil
        }
        return Rule(label: label, kind: kind, regex: re, group: group, confidence: confidence, validate: validate)
    }

    private static func build() -> [Rule] {
        let list: [Rule?] = [
            rule("IBAN", .bank, #"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){3,7}(?: ?[A-Z0-9]{1,3})?\b"#, validate: isValidIBAN),
            rule("Kontonummer", .bank, #"(?i)\b(?:konto(?:-?nr\.?|nummer)?|kto\.?(?:-?nr\.?)?)\s*[:.]?\s*(\d[\d ]{4,12}\d)\b"#, group: 1),
            rule("Steuer-ID", .identifier, #"(?i)\b(?:steuer-?id(?:ent(?:ifikations)?(?:-?nr\.?|nummer))?|identifikationsnummer|id-?nr\.?|steuerliche\s+id(?:entifikationsnummer)?)\s*[:.]?\s*((?:\d\s?){10}\d)\b"#, group: 1),
            rule("Sozialversicherungsnummer", .identifier, #"\b\d{2}\s?[0-3]\d[01]\d{3}\s?[A-Z]\s?\d{3}\b"#),
            rule("Versicherungsnummer", .identifier, #"(?i)\b(?:sv|rv|sozialversicherungs|rentenversicherungs|versicherungs)-?\s?(?:nr\.?|nummer)\s*[:.]?\s*([0-9A-Z][0-9A-Z ]{8,14}[0-9A-Z])"#, group: 1),
            rule("Ausweisnummer", .identifier, #"(?i)\b(?:personalausweis|ausweis|reisepass)(?:-?nr\.?|nummer)?\s*[:.]?\s*([CFGHJKLMNPRTVWXYZ0-9]{9,10})\b"#, group: 1),
            rule("E-Mail", .contact, #"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#, confidence: 0.95),
            rule("Telefon", .contact, #"(?<![\d,.])(?:\+49|0049|\+43|\+41|0)\s?(?:\(0\)\s?)?[1-9]\d{1,4}(?:[\s/\-]?\d){4,10}(?![\d,.])"#, confidence: 0.8),
            rule("Geburtsdatum", .birthdate, #"(?i)\b(?:geb(?:oren)?\.?(?:\s+am)?|geburtsdatum|geb\.-?datum|geburtstag)\s*[:.]?\s*(\d{1,2}\.\s?\d{1,2}\.\s?(?:19|20)?\d{2})"#, group: 1),
            rule("Geburtsort", .birthdate, #"(?i)\bgeb(?:oren)?\.?\s+(?:am\s+\S+\s+)?in\s+([A-ZÄÖÜ][\wäöüß\-]+(?:\s[A-ZÄÖÜ][\wäöüß\-]+)?)"#, group: 1, confidence: 0.9),
            rule("Konfession", .religion, #"(?i)\b(?:konfession|religion(?:szugehörigkeit)?|kirchensteuermerkmal|kist-?merkmal|rel\.)\s*[:\-]?\s*(römisch-katholisch|katholisch|evangelisch(?:-lutherisch)?|reformiert|altkatholisch|jüdisch|freireligiös|keine|ohne|[a-zäöü]{1,3}\b|--?)"#, group: 1),
            rule("Kirchensteuer", .religion, #"(?i)\b(?:kirchensteuer|kist|ki\.\s?st\.)\b[^\n\d]{0,30}(\d{1,3}(?:\.\d{3})*,\d{2})"#, group: 1),
            rule("Steuerklasse", .family, #"(?i)\b(?:steuerklasse|st\.?\s?kl\.?|stkl\.?)\s*[:.]?\s*([1-6]|VI|IV|V|I{1,3})\b"#, group: 1),
            rule("Kinderfreibeträge", .family, #"(?i)\b(?:kinderfreibetr(?:ag|äge)|kinderfb|kfb|kinderzahl|anzahl\s+kinder)\s*[:.]?\s*(\d{1,2}(?:,\d)?)"#, group: 1),
            rule("Familienstand", .family, #"(?i)\bfamilienstand\s*[:.]?\s*(ledig|verheiratet|geschieden|verwitwet|getrennt\s+lebend|eingetragene\s+lebenspartnerschaft|vh|ld|gs|vw)\b"#, group: 1),
            rule("Pfändung", .family, #"(?i)\b(?:lohnpfändung|pfändung|abtretung)\b\s*[:,\-–]?\s*(?:gläubiger\s*[:,]?\s*)?([A-ZÄÖÜ][^\n]{2,58}?)(?=\s{2,}|\n|$|\s\d)"#, group: 1, confidence: 0.7),
            rule("Krankenkasse", .insurer, #"\b(?:AOK(?:[ \-][A-ZÄÖÜ][\wäöüß\-/]*){0,2}|Techniker Krankenkasse|BARMER|Barmer(?: GEK)?|DAK(?:-Gesundheit)?|IKK(?: [A-ZÄÖÜ][\wäöüß\-]+)?|BKK(?:[ \-][A-ZÄÖÜ][\wäöüß\-]+)?|KKH|HEK|hkk|Knappschaft|Mobil Krankenkasse|VIACTIV|Debeka)\b"#, confidence: 0.95),
            rule("Krankenkasse", .insurer, #"(?i)\b(?:krankenkasse|krankenversicherung|kv-?träger)\s*[:.]?\s*([A-ZÄÖÜ][\wäöüß&\-/. ]{1,40}?)(?=\s{2,}|\n|\t|$)"#, group: 1, confidence: 0.85)
        ]
        return list.compactMap { $0 }
    }

    static func hits(in text: String) -> [RuleHit] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var out: [RuleHit] = []
        for rule in rules {
            for m in rule.regex.matches(in: text, range: full) {
                let r = rule.group == 0 ? m.range : m.range(at: rule.group)
                guard r.location != NSNotFound, r.length > 0 else { continue }
                let value = ns.substring(with: r).trimmingCharacters(in: .whitespaces)
                if value.isEmpty { continue }
                if let validate = rule.validate, !validate(value) { continue }
                out.append(RuleHit(kind: rule.kind, label: rule.label, range: r, text: value, confidence: rule.confidence))
            }
        }
        return out
    }

    /// IBAN-Prüfziffer (ISO 13616, Modulo 97).
    static func isValidIBAN(_ raw: String) -> Bool {
        let s = raw.replacingOccurrences(of: " ", with: "").uppercased()
        guard s.count >= 15, s.count <= 34 else { return false }
        let rearranged = String(s.dropFirst(4)) + String(s.prefix(4))
        var remainder = 0
        for ch in rearranged {
            if let d = ch.wholeNumberValue {
                remainder = (remainder * 10 + d) % 97
            } else if let ascii = ch.asciiValue, ascii >= 65, ascii <= 90 {
                let v = Int(ascii) - 55
                remainder = (remainder * 100 + v) % 97
            } else {
                return false
            }
        }
        return remainder == 1
    }
}
