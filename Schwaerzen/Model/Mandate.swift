import Foundation
import CoreGraphics

// MARK: - Geometrie

/// Rechteck in Anzeige-Koordinaten der Seite (Punkte, Ursprung unten links, Drehung bereits angewandt).
struct Box: Codable, Hashable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }

    init(_ r: CGRect) {
        x = Double(r.origin.x); y = Double(r.origin.y); w = Double(r.size.width); h = Double(r.size.height)
    }

    var cg: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

// MARK: - Listen

struct PersonRecord: Codable, Hashable, Identifiable {
    var firstName: String
    var lastName: String
    var number: String

    var id: String { number.isEmpty ? "\(lastName)|\(firstName)" : number }

    var fullName: String {
        [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
    }

    var initials: String {
        let f = firstName.split(separator: " ").compactMap { $0.first }.map(String.init).joined()
        let l = lastName.first.map(String.init) ?? ""
        return (f + l).uppercased()
    }
}

struct CompanyRecord: Codable, Hashable, Identifiable {
    var name: String
    var number: String
    var id: String { number.isEmpty ? name : number }
}

// MARK: - Profil

struct Profile: Codable, Equatable {
    var rules: [String: Set<Kind>] = [:]
    var useAI: Bool = true
    var autoThreshold: Double = 0.9
    var labelsInBars: Bool = true
    var rebuildTextLayer: Bool = true
    var removeMetadata: Bool = true
    var filenameMode: FilenameMode = .personnelNumber
    var employeePrefix: String = "MA-"

    init() {
        for t in DocType.allCases { rules[t.rawValue] = Profile.defaults(for: t) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        if let r = try c.decodeIfPresent([String: Set<Kind>].self, forKey: .rules) { rules.merge(r) { _, new in new } }
        useAI = try c.decodeIfPresent(Bool.self, forKey: .useAI) ?? useAI
        autoThreshold = try c.decodeIfPresent(Double.self, forKey: .autoThreshold) ?? autoThreshold
        labelsInBars = try c.decodeIfPresent(Bool.self, forKey: .labelsInBars) ?? labelsInBars
        rebuildTextLayer = try c.decodeIfPresent(Bool.self, forKey: .rebuildTextLayer) ?? rebuildTextLayer
        removeMetadata = try c.decodeIfPresent(Bool.self, forKey: .removeMetadata) ?? removeMetadata
        filenameMode = try c.decodeIfPresent(FilenameMode.self, forKey: .filenameMode) ?? filenameMode
        employeePrefix = try c.decodeIfPresent(String.self, forKey: .employeePrefix) ?? employeePrefix
    }

    func kinds(for type: DocType) -> Set<Kind> {
        rules[type.rawValue] ?? Profile.defaults(for: type)
    }

    func isEnabled(_ kind: Kind, for type: DocType) -> Bool {
        if type == .excluded { return false }
        if kind == .term || kind == .manual || kind.locked { return true }
        return kinds(for: type).contains(kind)
    }

    mutating func set(_ kind: Kind, _ on: Bool, for type: DocType) {
        var set = kinds(for: type)
        if on { set.insert(kind) } else { set.remove(kind) }
        rules[type.rawValue] = set
    }

    static func defaults(for type: DocType) -> Set<Kind> {
        let base: Set<Kind> = [.bank, .identifier, .religion]
        switch type {
        case .personal: return base.union([.name, .address, .contact, .birthdate, .family])
        case .payroll: return base.union([.name, .address, .birthdate, .family, .insurer])
        case .lease: return base.union([.name, .address, .contact])
        case .commercial: return base.union([.name, .company, .contact])
        case .invoice: return base.union([.name, .address, .contact])
        case .permit: return base.union([.name])
        case .corporate: return base.union([.address, .birthdate])
        case .other: return base.union([.name, .address, .contact, .birthdate])
        case .excluded: return []
        }
    }
}

// MARK: - Dateien

struct SourceFile: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var sourcePath: String
    var relativePath: String
    var docType: DocType = .other
    var typeLockedByUser: Bool = false
    var excludedReason: String = ""
    var status: FileStatus = .queued
    var method: String = ""
    var pageCount: Int = 0
    var pageSizes: [[Double]] = []
    var message: String = ""

    var fileName: String { (relativePath as NSString).lastPathComponent }
    var ext: String { (sourcePath as NSString).pathExtension.lowercased() }

    func pageSize(_ index: Int) -> CGSize {
        guard index >= 0, index < pageSizes.count, pageSizes[index].count == 2 else { return CGSize(width: 595, height: 842) }
        return CGSize(width: pageSizes[index][0], height: pageSizes[index][1])
    }

    init(sourcePath: String, relativePath: String) {
        self.sourcePath = sourcePath
        self.relativePath = relativePath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        sourcePath = try c.decode(String.self, forKey: .sourcePath)
        relativePath = try c.decode(String.self, forKey: .relativePath)
        docType = try c.decodeIfPresent(DocType.self, forKey: .docType) ?? .other
        typeLockedByUser = try c.decodeIfPresent(Bool.self, forKey: .typeLockedByUser) ?? false
        excludedReason = try c.decodeIfPresent(String.self, forKey: .excludedReason) ?? ""
        status = try c.decodeIfPresent(FileStatus.self, forKey: .status) ?? .queued
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? ""
        pageCount = try c.decodeIfPresent(Int.self, forKey: .pageCount) ?? 0
        pageSizes = try c.decodeIfPresent([[Double]].self, forKey: .pageSizes) ?? []
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }
}

// MARK: - Personen & Begriffe

struct Entity: Codable, Identifiable, Hashable {
    var key: String
    var display: String
    var kind: Kind
    var role: Role?
    var replacement: String?
    var decision: Decision
    var locked: Bool = false
    var lockReason: String = ""
    var sources: Set<String> = []
    var confidence: Double = 0
    var surfaces: [String] = []
    var personNumber: String?
    var userDecided: Bool = false
    var note: String = ""

    var id: String { key }

    init(key: String, display: String, kind: Kind, role: Role?, replacement: String?, decision: Decision) {
        self.key = key
        self.display = display
        self.kind = kind
        self.role = role
        self.replacement = replacement
        self.decision = decision
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        display = try c.decode(String.self, forKey: .display)
        kind = try c.decode(Kind.self, forKey: .kind)
        role = try c.decodeIfPresent(Role.self, forKey: .role)
        replacement = try c.decodeIfPresent(String.self, forKey: .replacement)
        decision = try c.decodeIfPresent(Decision.self, forKey: .decision) ?? .pending
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        lockReason = try c.decodeIfPresent(String.self, forKey: .lockReason) ?? ""
        sources = try c.decodeIfPresent(Set<String>.self, forKey: .sources) ?? []
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        surfaces = try c.decodeIfPresent([String].self, forKey: .surfaces) ?? []
        personNumber = try c.decodeIfPresent(String.self, forKey: .personNumber)
        userDecided = try c.decodeIfPresent(Bool.self, forKey: .userDecided) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }

    var subtitle: String {
        var parts: [String] = []
        if let role, kind == .name || kind == .company { parts.append(role.label) } else { parts.append(kind.shortLabel) }
        if let n = personNumber, !n.isEmpty { parts.append("Nr. \(n)") }
        if !sources.isEmpty { parts.append(sources.sorted().joined(separator: " · ")) }
        return parts.joined(separator: " · ")
    }
}

/// Eine Fundstelle: wo im Dokument eine Person / ein Begriff vorkommt.
struct Finding: Codable, Identifiable {
    var id: UUID = UUID()
    var entityKey: String
    var fileID: UUID
    var page: Int
    var location: Int
    var length: Int
    var rects: [Box]
    var before: String
    var matched: String
    var after: String
    var suppressed: Bool = false
}

// MARK: - Mandat

struct Mandate: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var caseNumber: String
    var created: Date = Date()
    var profile: Profile = Profile()
    var employees: [PersonRecord] = []
    var employeesSource: String = ""
    var suppliers: [CompanyRecord] = []
    var suppliersSource: String = ""
    var customers: [CompanyRecord] = []
    var customersSource: String = ""
    var neverTerms: [String] = []
    var alwaysTerms: [String] = []
    var files: [SourceFile] = []
    var entities: [String: Entity] = [:]
    var findings: [Finding] = []
    var counters: [String: Int] = [:]
    var lastExportPath: String = ""

    init(name: String, caseNumber: String) {
        self.name = name
        self.caseNumber = caseNumber
        if !name.isEmpty { neverTerms = [name] }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Mandat"
        caseNumber = try c.decodeIfPresent(String.self, forKey: .caseNumber) ?? ""
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        profile = try c.decodeIfPresent(Profile.self, forKey: .profile) ?? Profile()
        employees = try c.decodeIfPresent([PersonRecord].self, forKey: .employees) ?? []
        employeesSource = try c.decodeIfPresent(String.self, forKey: .employeesSource) ?? ""
        suppliers = try c.decodeIfPresent([CompanyRecord].self, forKey: .suppliers) ?? []
        suppliersSource = try c.decodeIfPresent(String.self, forKey: .suppliersSource) ?? ""
        customers = try c.decodeIfPresent([CompanyRecord].self, forKey: .customers) ?? []
        customersSource = try c.decodeIfPresent(String.self, forKey: .customersSource) ?? ""
        neverTerms = try c.decodeIfPresent([String].self, forKey: .neverTerms) ?? []
        alwaysTerms = try c.decodeIfPresent([String].self, forKey: .alwaysTerms) ?? []
        files = try c.decodeIfPresent([SourceFile].self, forKey: .files) ?? []
        entities = try c.decodeIfPresent([String: Entity].self, forKey: .entities) ?? [:]
        findings = try c.decodeIfPresent([Finding].self, forKey: .findings) ?? []
        counters = try c.decodeIfPresent([String: Int].self, forKey: .counters) ?? [:]
        lastExportPath = try c.decodeIfPresent(String.self, forKey: .lastExportPath) ?? ""
    }

    func file(_ id: UUID) -> SourceFile? { files.first { $0.id == id } }

    mutating func nextNumber(for role: Role) -> String {
        let n = (counters[role.rawValue] ?? 0) + 1
        counters[role.rawValue] = n
        return role.prefix + String(format: "%0\(role.digits)d", n)
    }
}

// MARK: - Seiteninhalt (wird pro Datei separat gespeichert)

struct OCRWord: Codable, Hashable {
    var start: Int
    var end: Int
    var line: Int
    /// normalisiert (0…1), Ursprung unten links
    var box: Box
}

struct PageData: Codable {
    var index: Int
    /// Anzeigegröße der Seite in Punkten (Drehung angewandt)
    var width: Double
    var height: Double
    var isOCR: Bool
    var text: String
    var words: [OCRWord]
}

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
