import SwiftUI

// MARK: - Dokumenttypen

enum DocType: String, Codable, CaseIterable, Identifiable, Hashable {
    case personal
    case payroll
    case lease
    case commercial
    case invoice
    case permit
    case corporate
    case other
    case excluded

    var id: String { rawValue }

    var label: String {
        switch self {
        case .personal: "Arbeitsverträge & Personal"
        case .payroll: "Lohnabrechnungen"
        case .lease: "Miet- & Pachtverträge"
        case .commercial: "Kunden & Lieferanten"
        case .invoice: "Rechnungen"
        case .permit: "Genehmigungen & Bescheide"
        case .corporate: "Gesellschaft"
        case .other: "Sonstiges"
        case .excluded: "Ausgeschlossen"
        }
    }

    var shortLabel: String {
        switch self {
        case .personal: "Personal"
        case .payroll: "Lohn"
        case .lease: "Miete"
        case .commercial: "Verträge"
        case .invoice: "Rechnung"
        case .permit: "Genehmigung"
        case .corporate: "Gesellschaft"
        case .other: "Sonstiges"
        case .excluded: "Ausgeschlossen"
        }
    }

    var symbol: String {
        switch self {
        case .personal: "person.text.rectangle"
        case .payroll: "banknote"
        case .lease: "building.2"
        case .commercial: "shippingbox"
        case .invoice: "doc.text"
        case .permit: "checkmark.seal"
        case .corporate: "building.columns"
        case .other: "folder"
        case .excluded: "nosign"
        }
    }

    var tint: Color {
        switch self {
        case .personal: .blue
        case .payroll: .purple
        case .lease: .orange
        case .commercial: .teal
        case .invoice: .green
        case .permit: .brown
        case .corporate: .indigo
        case .other: .gray
        case .excluded: .red
        }
    }

    /// Dokumente mit Personenbezug: KI-Treffer werden hier ab Schwelle automatisch geschwärzt.
    var isPersonal: Bool { self == .personal || self == .payroll }

    /// Was in diesem Dokumenttyp standardmäßig sichtbar bleibt (Hinweis im Profil).
    var keepHint: String {
        switch self {
        case .personal: "Gehalt & Zulagen, Eintrittsdatum, Funktion, Kündigungsfristen, Unterzeichner Arbeitgeber"
        case .payroll: "Brutto & Netto, Arbeitgeberanteile, Zulagen & Überstunden, Eintritt & Tätigkeit"
        case .lease: "Objektadresse, Flächen, Miete & Nebenkosten, Laufzeit & Optionen"
        case .commercial: "Laufzeit & Kündigung, Haftung, Change of Control"
        case .invoice: "Beträge, Leistungszeitraum, eigene Firmendaten"
        case .permit: "Behörde & Aktenzeichen, Auflagen, Flurstücke, Fristen"
        case .corporate: "Gesellschafter & Anteile, Geschäftsführer, Beschlüsse"
        case .other: "alles, was nicht erkannt wird"
        case .excluded: "nichts – diese Dateien werden nicht exportiert"
        }
    }

    var detectHint: String {
        switch self {
        case .personal: "Arbeitsvertrag, Anstellungsvertrag, Änderungs-/Aufhebungsvertrag, Abmahnung, Personalakte"
        case .payroll: "Verdienst-, Entgelt-, Lohn- oder Gehaltsabrechnung, Lohnjournal"
        case .lease: "Miet- oder Pachtvertrag, Nachträge, Nebenkostenabrechnung"
        case .commercial: "Rahmen-, Liefer-, Kauf- oder Dienstleistungsvertrag"
        case .invoice: "Rechnung, Rechnungsnummer, Gutschrift"
        case .permit: "Bescheid, Genehmigung, BImSchG, Behördenkopf"
        case .corporate: "Gesellschaftsvertrag, Satzung, Gesellschafterliste, Beschluss, Registerauszug"
        case .other: "alle übrigen Dokumente"
        case .excluded: "Krankmeldung/AU, BEM, Schwerbehinderung, ärztliche Unterlagen, Bewerbungen, Beurteilungen"
        }
    }

    static var reviewable: [DocType] { allCases.filter { $0 != .excluded } }
}

// MARK: - Erkennungsarten

enum Kind: String, Codable, CaseIterable, Identifiable, Hashable {
    case name
    case company
    case address
    case contact
    case birthdate
    case bank
    case identifier
    case religion
    case family
    case insurer
    case date
    case term
    case manual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: "Namen von Personen"
        case .company: "Firmen aus Listen"
        case .address: "Anschriften"
        case .contact: "E-Mail & Telefon"
        case .birthdate: "Geburtsdatum & -ort"
        case .bank: "Bankverbindungen"
        case .identifier: "Steuer-ID, SV-Nummer, Ausweis"
        case .religion: "Konfession & Kirchensteuer"
        case .family: "Steuerklasse, Kinder, Familienstand, Pfändungen"
        case .insurer: "Krankenkasse"
        case .date: "Alle Datumsangaben"
        case .term: "Begriffe (Immer-Liste)"
        case .manual: "Manuelle Schwärzung"
        }
    }

    var shortLabel: String {
        switch self {
        case .name: "Name"
        case .company: "Firma"
        case .address: "Anschrift"
        case .contact: "Kontakt"
        case .birthdate: "Geburt"
        case .bank: "Bank"
        case .identifier: "Kennnummer"
        case .religion: "Konfession"
        case .family: "Familie"
        case .insurer: "Krankenkasse"
        case .date: "Datum"
        case .term: "Begriff"
        case .manual: "Manuell"
        }
    }

    var detail: String {
        switch self {
        case .name: "Vor- und Nachnamen, auch Nachname allein und Initialen"
        case .company: "Lieferanten und Kunden aus den importierten Listen"
        case .address: "Straße, Hausnummer, PLZ, Ort"
        case .contact: "E-Mail-Adressen und Telefonnummern"
        case .birthdate: "Nur mit Hinweis „geb.“ oder „Geburtsdatum“"
        case .bank: "IBAN (mit Prüfziffer) und Kontonummern"
        case .identifier: "feste Regeln, immer geschwärzt"
        case .religion: "besondere Kategorie nach Art. 9 DSGVO"
        case .family: "lassen auf die private Lebenssituation schließen"
        case .insurer: "Name der Kasse; Beitragssätze bleiben"
        case .date: "Achtung: auch Vertragsdaten und Fristen"
        case .term: "aus der Immer-Liste des Mandats"
        case .manual: "von Hand gezogene Bereiche"
        }
    }

    var symbol: String {
        switch self {
        case .name: "person"
        case .company: "building.2"
        case .address: "house"
        case .contact: "envelope"
        case .birthdate: "birthday.cake"
        case .bank: "creditcard"
        case .identifier: "number"
        case .religion: "lock.shield"
        case .family: "figure.2.and.child.holdinghands"
        case .insurer: "cross.case"
        case .date: "calendar"
        case .term: "text.badge.xmark"
        case .manual: "rectangle.dashed"
        }
    }

    var tint: Color {
        switch self {
        case .name: .blue
        case .company: .orange
        case .address: .teal
        case .contact: .cyan
        case .birthdate: .pink
        case .bank: .purple
        case .identifier: .purple
        case .religion: .red
        case .family: .mint
        case .insurer: .green
        case .date: .gray
        case .term: .brown
        case .manual: .gray
        }
    }

    /// Feste Regeln, die immer geschwärzt werden.
    var locked: Bool { self == .bank || self == .identifier || self == .religion }

    static var configurable: [Kind] {
        [.name, .company, .address, .contact, .birthdate, .bank, .identifier, .religion, .family, .insurer, .date]
    }

    /// Reihenfolge der Gruppen in der Personen-&-Begriffe-Ansicht.
    var groupOrder: Int {
        switch self {
        case .name: 0
        case .company: 1
        case .term: 2
        case .address: 3
        case .contact: 4
        case .birthdate: 5
        case .family: 6
        case .insurer: 7
        case .religion: 8
        case .bank: 9
        case .identifier: 10
        case .date: 11
        case .manual: 12
        }
    }
}

// MARK: - Rollen (für Namen und Firmen)

enum Role: String, Codable, CaseIterable, Identifiable, Hashable {
    case employee
    case landlord
    case supplier
    case customer
    case partner
    case privatePerson
    case official
    case shareholder
    case unknown

    var id: String { rawValue }

    var label: String {
        switch self {
        case .employee: "Mitarbeiter"
        case .landlord: "Vermieter"
        case .supplier: "Lieferant"
        case .customer: "Kunde"
        case .partner: "Vertragspartner"
        case .privatePerson: "Privatperson"
        case .official: "Amtsträger"
        case .shareholder: "Gesellschafter"
        case .unknown: "Person"
        }
    }

    /// Präfix für die Ersetzung im Balken und im Dateinamen.
    var prefix: String {
        switch self {
        case .employee: "MA-"
        case .landlord: "Vermieter "
        case .supplier: "Lieferant "
        case .customer: "Kunde "
        case .partner: "Partner "
        case .privatePerson: "Privatperson "
        case .official: "Amt "
        case .shareholder: "Gesellschafter "
        case .unknown: "Person "
        }
    }

    var digits: Int {
        switch self {
        case .employee, .supplier, .customer: 3
        default: 2
        }
    }

    var tint: Color {
        switch self {
        case .employee: .blue
        case .landlord: .orange
        case .supplier, .customer, .partner: .teal
        case .privatePerson: .green
        case .official: .gray
        case .shareholder: .indigo
        case .unknown: .blue
        }
    }
}

// MARK: - Entscheidung

enum Decision: String, Codable, CaseIterable, Hashable {
    case pending
    case redact
    case keep

    var label: String {
        switch self {
        case .pending: "Offen"
        case .redact: "Schwärzen"
        case .keep: "Behalten"
        }
    }
}

// MARK: - Dateinamen

enum FilenameMode: String, Codable, CaseIterable, Identifiable {
    case personnelNumber
    case sequential
    case initials

    var id: String { rawValue }

    var label: String {
        switch self {
        case .personnelNumber: "Personalnummer"
        case .sequential: "Laufende Nummer"
        case .initials: "Initialen"
        }
    }

    var example: String {
        switch self {
        case .personnelNumber: "Arbeitsvertrag_MA-0417.pdf"
        case .sequential: "Arbeitsvertrag_P-001.pdf"
        case .initials: "Arbeitsvertrag_HM.pdf"
        }
    }

    var hint: String {
        switch self {
        case .personnelNumber: "Empfohlen: Käufer können Verträge, Abrechnungen und die anonymisierte Personalliste einander zuordnen."
        case .sequential: "Wenn es keine Personalnummern gibt. Die Zuordnung bleibt nur bei dir."
        case .initials: "Nicht empfohlen: Kollisionen und in kleinen Betrieben leicht rückführbar."
        }
    }
}

// MARK: - Dateistatus

enum FileStatus: String, Codable, Hashable {
    case queued
    case converting
    case analyzing
    case done
    case failed
    case unsupported

    var label: String {
        switch self {
        case .queued: "Wartet"
        case .converting: "Wandle um …"
        case .analyzing: "Analysiere …"
        case .done: "Fertig"
        case .failed: "Fehler"
        case .unsupported: "Nicht unterstützt"
        }
    }
}
