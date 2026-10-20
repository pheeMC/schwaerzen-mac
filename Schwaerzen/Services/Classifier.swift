import Foundation

/// Ordnet Dokumente anhand von Dateiname und Inhalt der ersten Seiten einem Dokumenttyp zu.
enum Classifier {
    struct Result {
        var type: DocType
        var excludedReason: String
    }

    private static let exclusions: [(String, String)] = [
        ("arbeitsunfähigkeit", "Gesundheitsdaten (AU-Bescheinigung)"),
        ("au-bescheinigung", "Gesundheitsdaten (AU-Bescheinigung)"),
        ("au bescheinigung", "Gesundheitsdaten (AU-Bescheinigung)"),
        ("arbeitsunfähigkeitsbescheinigung", "Gesundheitsdaten (AU-Bescheinigung)"),
        ("krankmeldung", "Gesundheitsdaten (Krankmeldung)"),
        ("krankschreibung", "Gesundheitsdaten (Krankmeldung)"),
        ("eingliederungsmanagement", "Gesundheitsdaten (BEM)"),
        ("bem-gespräch", "Gesundheitsdaten (BEM)"),
        ("schwerbehindert", "Gesundheitsdaten (Schwerbehinderung)"),
        ("gleichstellungsbescheid", "Gesundheitsdaten (Schwerbehinderung)"),
        ("ärztliche bescheinigung", "Gesundheitsdaten (ärztliche Unterlage)"),
        ("attest", "Gesundheitsdaten (Attest)"),
        ("arbeitsmedizin", "Gesundheitsdaten (Arbeitsmedizin)"),
        ("bewerbung", "Bewerbungsunterlagen"),
        ("lebenslauf", "Bewerbungsunterlagen"),
        ("arbeitszeugnis", "Beurteilung (Arbeitszeugnis)"),
        ("zwischenzeugnis", "Beurteilung (Arbeitszeugnis)"),
        ("mitarbeitergespräch", "Beurteilung (Personalgespräch)"),
        ("personalgespräch", "Beurteilung (Personalgespräch)"),
        ("leistungsbeurteilung", "Beurteilung"),
        ("führungszeugnis", "Führungszeugnis")
    ]

    private static let keywords: [(DocType, [String])] = [
        (.payroll, ["verdienstabrechnung", "entgeltabrechnung", "lohnabrechnung", "gehaltsabrechnung", "lohnjournal",
                    "abrechnung der brutto", "lohn- und gehalt", "lohnkonto", "lstb", "lohnsteuerbescheinigung"]),
        (.personal, ["personalliste", "mitarbeiterliste", "mitarbeiterübersicht", "personalübersicht", "arbeitsvertrag", "anstellungsvertrag", "dienstvertrag", "änderungsvertrag", "aufhebungsvertrag",
                     "abmahnung", "arbeitnehmer", "personalakte", "zusatzvereinbarung zum arbeitsvertrag", "befristung"]),
        (.lease, ["mietvertrag", "pachtvertrag", "untermietvertrag", "gewerbemietvertrag", "nachtrag zum mietvertrag",
                  "nebenkostenabrechnung", "betriebskostenabrechnung", "vermieter", "mietfläche"]),
        (.invoice, ["rechnung", "rechnungsnummer", "rechnungsdatum", "gutschrift", "invoice", "zahlbar bis"]),
        (.permit, ["bescheid", "genehmigung", "baugenehmigung", "bimschg", "immissionsschutz", "erlaubnis",
                   "landratsamt", "bauaufsicht", "auflage", "widerspruchsbelehrung", "rechtsbehelfsbelehrung"]),
        (.corporate, ["gesellschaftsvertrag", "satzung", "gesellschafterliste", "gesellschafterbeschluss",
                      "gesellschafterversammlung", "handelsregister", "registerauszug", "geschäftsordnung", "notar"]),
        (.commercial, ["rahmenvertrag", "liefervertrag", "kaufvertrag", "dienstleistungsvertrag", "lieferant",
                       "auftraggeber", "auftragnehmer", "werkvertrag", "kooperationsvertrag", "lizenzvertrag", "vertrag"])
    ]

    static func classify(fileName: String, folderPath: String, pages: [PageData]) -> Result {
        let name = normalize(fileName + " " + folderPath)
            .replacingOccurrences(of: "ae", with: "ä")
            .replacingOccurrences(of: "oe", with: "ö")
            .replacingOccurrences(of: "ue", with: "ü")
        let head = normalize(pages.prefix(2).map(\.text).joined(separator: "\n"))
        let title = String(head.prefix(700))

        for (raw, reason) in exclusions {
            let needle = normalize(raw)
            guard name.contains(needle) || title.contains(needle) else { continue }
            return Result(type: .excluded, excludedReason: reason)
        }

        var best: (DocType, Int) = (.other, 0)
        for (type, words) in keywords {
            var score = 0
            for raw in words {
                let w = normalize(raw)
                if name.contains(w) { score += 6 }
                if title.contains(w) { score += 3 }
                score += min(occurrences(of: w, in: head), 4)
            }
            if score > best.1 { best = (type, score) }
        }
        return Result(type: best.1 >= 3 ? best.0 : .other, excludedReason: "")
    }

    /// Kleinbuchstaben, Unterstriche/Bindestriche/Punkte als Leerzeichen, Mehrfach-Leerzeichen zusammengefasst.
    private static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        for c in ["_", "-", ".", "–", "/"] { t = t.replacingOccurrences(of: c, with: " ") }
        return t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func occurrences(of needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var range = text.startIndex..<text.endIndex
        while let r = text.range(of: needle, range: range) {
            count += 1
            range = r.upperBound..<text.endIndex
            if count > 10 { break }
        }
        return count
    }
}
