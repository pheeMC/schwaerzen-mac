import Foundation

enum Paths {
    static let fm = FileManager.default

    static var home: URL { fm.homeDirectoryForCurrentUser }

    static var support: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent("Schwaerzen", isDirectory: true))
    }

    static var mandatesDir: URL { ensure(support.appendingPathComponent("Mandate", isDirectory: true)) }

    static func mandateJSON(_ id: UUID) -> URL {
        mandatesDir.appendingPathComponent("\(id.uuidString).json")
    }

    static func workDir(_ mandate: UUID) -> URL {
        ensure(support.appendingPathComponent("Arbeitsdateien", isDirectory: true)
            .appendingPathComponent(mandate.uuidString, isDirectory: true))
    }

    static func workPDF(_ mandate: UUID, _ file: UUID) -> URL {
        workDir(mandate).appendingPathComponent("\(file.uuidString).pdf")
    }

    static func pagesJSON(_ mandate: UUID, _ file: UUID) -> URL {
        workDir(mandate).appendingPathComponent("\(file.uuidString).seiten.json")
    }

    static var ownModelCache: URL { ensure(support.appendingPathComponent("ModelCache", isDirectory: true)) }

    /// Mögliche Orte, an denen HideMyData das KI-Modell bereits abgelegt hat.
    static var modelCacheCandidates: [URL] {
        let lib = home.appendingPathComponent("Library", isDirectory: true)
        let hmdSuffix = "Data/Library/Application Support/HideMyData/ModelCache"
        return [
            ownModelCache,
            lib.appendingPathComponent("Containers/com.maciejbula.hidemydata/\(hmdSuffix)", isDirectory: true),
            lib.appendingPathComponent("Containers/com.maciejonos.HideMyData/\(hmdSuffix)", isDirectory: true),
            lib.appendingPathComponent("Application Support/HideMyData/ModelCache", isDirectory: true)
        ]
    }

    /// Office ist sandboxed: Dateien im gemeinsamen Office-Gruppencontainer kann Office ohne Rückfrage öffnen und speichern.
    static var officeStaging: URL {
        let group = home.appendingPathComponent("Library/Group Containers/UBF8T346G9.Office", isDirectory: true)
        if fm.fileExists(atPath: group.path) {
            return ensure(group.appendingPathComponent("Schwaerzen-Temp", isDirectory: true))
        }
        return ensure(fm.temporaryDirectory.appendingPathComponent("Schwaerzen-Temp", isDirectory: true))
    }

    static func appContainerStaging(bundleID: String) -> URL {
        let dir = home.appendingPathComponent("Library/Containers/\(bundleID)/Data/tmp/Schwaerzen", isDirectory: true)
        return ensure(dir)
    }

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }
}

enum Storage {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func loadMandates() -> [Mandate] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: Paths.mandatesDir, includingPropertiesForKeys: nil) else { return [] }
        var out: [Mandate] = []
        for url in items where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url), let m = try? decoder().decode(Mandate.self, from: data) {
                out.append(m)
            }
        }
        return out.sorted { $0.created > $1.created }
    }

    static func save(_ mandate: Mandate) {
        guard let data = try? encoder().encode(mandate) else { return }
        try? data.write(to: Paths.mandateJSON(mandate.id), options: .atomic)
    }

    static func delete(_ mandate: Mandate) {
        try? FileManager.default.removeItem(at: Paths.mandateJSON(mandate.id))
        try? FileManager.default.removeItem(at: Paths.workDir(mandate.id))
    }

    static func savePages(_ pages: [PageData], mandate: UUID, file: UUID) {
        guard let data = try? JSONEncoder().encode(pages) else { return }
        try? data.write(to: Paths.pagesJSON(mandate, file), options: .atomic)
    }

    static func loadPages(mandate: UUID, file: UUID) -> [PageData] {
        guard let data = try? Data(contentsOf: Paths.pagesJSON(mandate, file)),
              let pages = try? JSONDecoder().decode([PageData].self, from: data) else { return [] }
        return pages
    }
}
