import SwiftUI
import PDFKit
import AppKit
import UniformTypeIdentifiers

enum ReviewMode: String, CaseIterable, Identifiable {
    case entities
    case unsure
    case pages
    case files

    var id: String { rawValue }

    var label: String {
        switch self {
        case .entities: "Personen & Begriffe"
        case .unsure: "Unsicher"
        case .pages: "Seiten"
        case .files: "Dateien"
        }
    }
}

enum SidebarItem: Hashable {
    case all
    case type(DocType)
    case problems
}

struct SidebarSelection: Hashable {
    var mandate: UUID
    var item: SidebarItem
}

enum DecisionFilter: String, CaseIterable, Identifiable {
    case all, pending, redact, keep
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "Alle"
        case .pending: "Offen"
        case .redact: "Schwärzen"
        case .keep: "Behalten"
        }
    }
}

struct EntityStat {
    var hits = 0
    var files = Set<UUID>()
    var types = Set<DocType>()
}

struct EntityRow: Identifiable {
    let entity: Entity
    let stat: EntityStat
    var id: String { entity.key }
}

struct EntityGroup: Identifiable {
    let kind: Kind
    let rows: [EntityRow]
    var id: String { kind.rawValue }
}

@Observable
@MainActor
final class AppStore {
    var mandates: [Mandate] = []
    var selection: SidebarSelection?
    var mode: ReviewMode = .entities
    var search: String = ""
    var decisionFilter: DecisionFilter = .all
    var selectedEntityKey: String?
    var showInspector: Bool = false

    var stats: [String: EntityStat] = [:]
    var redactionsByFile: [UUID: Int] = [:]
    var skippedUnsure: Set<String> = []

    var processing: Bool = false
    var progressText: String = ""
    var progressValue: Double = 0
    var alertMessage: String?

    var viewerFileID: UUID?
    var viewerPage: Int = 0
    var showProfile: Bool = false
    var showExport: Bool = false
    var showNewMandate: Bool = false
    var showPagesAll: Bool = false

    var exportRunning: Bool = false
    var exportProgress: Double = 0
    var exportText: String = ""
    var exportResult: ExportResult?

    let ai = AIDetector()

    @ObservationIgnored private var saveTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var touched: Set<UUID> = []
    @ObservationIgnored private var needsReanalysis: Set<UUID> = []
    let thumbnails = NSCache<NSString, NSImage>()

    // MARK: - Zugriff

    var currentID: UUID? { selection?.mandate }

    var current: Mandate? {
        guard let id = currentID else { return nil }
        return mandates.first { $0.id == id }
    }

    func mandate(_ id: UUID) -> Mandate? { mandates.first { $0.id == id } }

    var sidebarItem: SidebarItem { selection?.item ?? .all }

    // MARK: - Start

    func bootstrap() async {
        mandates = Storage.loadMandates()
        if let first = mandates.first {
            selection = SidebarSelection(mandate: first.id, item: .all)
        }
        // Unterbrochene Analysen wieder aufnehmen
        for i in mandates.indices {
            for j in mandates[i].files.indices where mandates[i].files[j].status == .converting || mandates[i].files[j].status == .analyzing {
                mandates[i].files[j].status = .queued
            }
        }
        rebuildIndex()
        setupDemoIfRequested()
        await ai.locateAndLoad()
        startAnalysis()
    }

    /// `--demo <ordner> [--mode entities|unsure|pages|files] [--no-ai] [--inspector]` – für Oberflächentests.
    private func setupDemoIfRequested() {
        let args = CommandLine.arguments
        if args.contains("--demo-empty") {
            if let existing = mandates.first(where: { $0.name == "Leeres Mandat" }) {
                select(mandate: existing.id)
            } else {
                createMandate(name: "Leeres Mandat", caseNumber: "1 IN 1/26")
            }
            return
        }
        guard let i = args.firstIndex(of: "--demo") else { return }
        let dir = i + 1 < args.count && !args[i + 1].hasPrefix("--")
            ? URL(fileURLWithPath: args[i + 1])
            : FileManager.default.temporaryDirectory.appendingPathComponent("schwaerzen-demo")
        let name = "Demo Logistik GmbH"
        if let existing = mandates.first(where: { $0.name == name }) {
            select(mandate: existing.id)
        } else {
            let root = dir.appendingPathComponent("Datenraum Demo", isDirectory: true)
            _ = SelfTest.makeTestPDF(at: root.appendingPathComponent("02 Personal/Müller, Hans/Arbeitsvertrag_Hans-Mueller.pdf"))
            _ = SelfTest.makePDF(at: root.appendingPathComponent("03 Immobilien/Mietvertrag_Lager_Schroeder.pdf"), text: """
            Mietvertrag über Gewerberäume

            Zwischen Frau Gerda Schröder, Elbchaussee 140, 22763 Hamburg – Vermieterin – und der Demo Logistik GmbH,
            Hafenstraße 4, 20457 Hamburg – Mieterin – wird folgender Vertrag geschlossen:

            § 1 Mietobjekt: Lagerhalle Halskestraße 38, 22113 Hamburg, ca. 4.800 m² Hallenfläche.
            § 3 Miete: 24.000,00 EUR netto monatlich auf das Konto IBAN DE89 3704 0044 0532 0130 00.
            § 14 Ansprechpartner der Vermieterin ist Thomas Schröder, Telefon 040 987 65432.
            """, scannedText: nil)
            _ = SelfTest.makePDF(at: root.appendingPathComponent("02 Personal/Müller, Hans/AU_Bescheinigung_2025.pdf"),
                                 text: "Arbeitsunfähigkeitsbescheinigung\n\nHans Müller, arbeitsunfähig seit 03.02.2025", scannedText: nil)
            createMandate(name: name, caseNumber: "12 IN 34/26")
            mutate { m in
                m.employees = [PersonRecord(firstName: "Hans", lastName: "Müller", number: "0417"),
                               PersonRecord(firstName: "Sabine", lastName: "Krüger", number: "0058")]
                m.employeesSource = "Demo-Personalliste"
                m.profile.useAI = !args.contains("--no-ai")
            }
            addFiles([root])
        }
        if let mi = args.firstIndex(of: "--mode"), mi + 1 < args.count, let mode = ReviewMode(rawValue: args[mi + 1]) {
            self.mode = mode
        }
        if args.contains("--inspector") { showInspector = true }
    }

    // MARK: - Ändern & Speichern

    func mutate(_ id: UUID? = nil, _ body: (inout Mandate) -> Void) {
        guard let id = id ?? currentID, let i = mandates.firstIndex(where: { $0.id == id }) else { return }
        body(&mandates[i])
        scheduleSave(id)
        if id == currentID { rebuildIndex() }
    }

    func scheduleSave(_ id: UUID) {
        saveTasks[id]?.cancel()
        saveTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self, let m = self.mandate(id) else { return }
            await Task.detached(priority: .utility) { Storage.save(m) }.value
        }
    }

    func saveNow() {
        for m in mandates { Storage.save(m) }
    }

    // MARK: - Mandate

    func createMandate(name: String, caseNumber: String) {
        let m = Mandate(name: name.trimmingCharacters(in: .whitespaces), caseNumber: caseNumber.trimmingCharacters(in: .whitespaces))
        mandates.insert(m, at: 0)
        Storage.save(m)
        selection = SidebarSelection(mandate: m.id, item: .all)
        mode = .files
        rebuildIndex()
    }

    func deleteMandate(_ id: UUID) {
        guard let m = mandate(id) else { return }
        Storage.delete(m)
        mandates.removeAll { $0.id == id }
        if currentID == id {
            selection = mandates.first.map { SidebarSelection(mandate: $0.id, item: .all) }
        }
        rebuildIndex()
    }

    func select(mandate id: UUID) {
        selection = SidebarSelection(mandate: id, item: .all)
        selectedEntityKey = nil
        skippedUnsure = []
        rebuildIndex()
    }

    // MARK: - Dateien

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Hinzufügen"
        panel.message = "Ordner oder Dateien für den Datenraum wählen"
        if panel.runModal() == .OK { addFiles(panel.urls) }
    }

    func addFiles(_ urls: [URL]) {
        guard let id = currentID else { return }
        var newFiles: [SourceFile] = []
        let existing = Set(mandate(id)?.files.map(\.sourcePath) ?? [])
        var usedRelative = Set(mandate(id)?.files.map { $0.relativePath.lowercased() } ?? [])
        let fm = FileManager.default

        func add(_ file: URL, relative: String) {
            guard !Converter.shouldIgnore(file), !existing.contains(file.path) else { return }
            var rel = relative
            var n = 2
            while usedRelative.contains(rel.lowercased()) {
                let base = (relative as NSString).deletingPathExtension
                let ext = (relative as NSString).pathExtension
                rel = "\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)")
                n += 1
            }
            usedRelative.insert(rel.lowercased())
            var f = SourceFile(sourcePath: file.path, relativePath: rel)
            if !Converter.isSupported(file.pathExtension) {
                f.status = .unsupported
                f.message = file.pathExtension.lowercased() == "zip" ? "Archiv – bitte entpacken und den Ordner hinzufügen" : "Dateityp wird nicht unterstützt"
            }
            newFiles.append(f)
        }

        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let rootName = url.lastPathComponent
                let keys: [URLResourceKey] = [.isRegularFileKey]
                guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let file as URL in enumerator {
                    let values = try? file.resourceValues(forKeys: Set(keys))
                    guard values?.isRegularFile == true else { continue }
                    let rel = String(file.path.dropFirst(url.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    add(file, relative: rootName + "/" + rel)
                }
            } else {
                add(url, relative: url.lastPathComponent)
            }
        }
        guard !newFiles.isEmpty else { return }
        mutate(id) { $0.files.append(contentsOf: newFiles.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }) }
        if mode == .entities, (current?.entities.isEmpty ?? true) { mode = .files }
        startAnalysis()
    }

    func setDocType(_ fileID: UUID, _ type: DocType) {
        mutate { m in
            guard let i = m.files.firstIndex(where: { $0.id == fileID }) else { return }
            let wasExcluded = m.files[i].docType == .excluded
            m.files[i].docType = type
            m.files[i].typeLockedByUser = true
            m.files[i].excludedReason = type == .excluded ? "von Hand ausgeschlossen" : ""
            if wasExcluded && type != .excluded && m.files[i].status == .done {
                m.files[i].status = .queued
            }
        }
        startAnalysis()
    }

    func reanalyze(_ fileIDs: [UUID]? = nil) {
        mutate { m in
            for i in m.files.indices where fileIDs == nil || fileIDs!.contains(m.files[i].id) {
                if m.files[i].status != .unsupported { m.files[i].status = .queued }
            }
        }
        startAnalysis()
    }

    func removeFiles(_ ids: Set<UUID>) {
        guard let mid = currentID else { return }
        mutate { m in
            m.files.removeAll { ids.contains($0.id) }
            m.findings.removeAll { ids.contains($0.fileID) }
        }
        for id in ids {
            try? FileManager.default.removeItem(at: Paths.workPDF(mid, id))
            try? FileManager.default.removeItem(at: Paths.pagesJSON(mid, id))
        }
    }

    func revealSource(_ fileID: UUID) {
        guard let f = current?.file(fileID) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.sourcePath)])
    }

    // MARK: - Analyse

    func startAnalysis() {
        guard analysisTask == nil else { return }
        analysisTask = Task { [weak self] in
            await self?.runQueue()
            self?.analysisTask = nil
        }
    }

    private func nextQueued() -> (UUID, UUID)? {
        let order = ([currentID].compactMap { $0 }) + mandates.map(\.id).filter { $0 != currentID }
        for mid in order {
            if let f = mandate(mid)?.files.first(where: { $0.status == .queued }) { return (mid, f.id) }
        }
        return nil
    }

    private func runQueue() async {
        processing = true
        defer {
            processing = false
            progressText = ""
            progressValue = 0
        }
        while true {
            while let next = nextQueued() {
                if Task.isCancelled { break }
                let (mid, fid) = next
                await analyze(mandateID: mid, fileID: fid)
                touched.insert(mid)
                if let m = mandate(mid) {
                    let total = m.files.filter { $0.status != .unsupported }.count
                    let done = m.files.filter { $0.status == .done || $0.status == .failed }.count
                    progressValue = total > 0 ? Double(done) / Double(total) : 0
                }
            }
            // Neue Personalliste im Datenraum gefunden → alle Dokumente noch einmal mit der Liste prüfen
            guard !needsReanalysis.isEmpty, !Task.isCancelled else { break }
            let ids = needsReanalysis
            needsReanalysis = []
            for mid in ids {
                mutate(mid) { m in
                    for i in m.files.indices where m.files[i].status == .done && m.files[i].docType != .excluded {
                        m.files[i].status = .queued
                    }
                }
            }
        }
        for mid in touched {
            await propagate(mid)
        }
        touched = []
        rebuildIndex()
        saveNow()
        if CommandLine.arguments.contains("--inspector"), selectedEntityKey == nil {
            selectedEntityKey = groupedEntities.first?.rows.first?.entity.key
        }
    }

    private func setStatus(_ mid: UUID, _ fid: UUID, _ status: FileStatus, message: String = "") {
        mutate(mid) { m in
            guard let i = m.files.firstIndex(where: { $0.id == fid }) else { return }
            m.files[i].status = status
            m.files[i].message = message
        }
    }

    private func analyze(mandateID mid: UUID, fileID fid: UUID) async {
        guard let file = mandate(mid)?.file(fid) else { return }
        let src = URL(fileURLWithPath: file.sourcePath)
        let pdf = Paths.workPDF(mid, fid)

        progressText = "Wandle um: \(file.fileName)"
        setStatus(mid, fid, .converting)
        do {
            guard FileManager.default.fileExists(atPath: src.path) else { throw AppError("Originaldatei nicht mehr vorhanden") }
            let method = try await Converter.convert(src, to: pdf)

            // Personalliste im Datenraum? Dann sofort als Liste übernehmen.
            if let people = await Task.detached(priority: .utility, operation: { ListImporter.detectEmployeeList(at: src) }).value,
               let m = mandate(mid) {
                let known = Set(m.employees.map { Norm.key($0.fullName) })
                let added = people.filter { !known.contains(Norm.key($0.fullName)) }
                if !added.isEmpty {
                    mutate(mid) { m in
                        m.employees.append(contentsOf: added)
                        if m.employeesSource.isEmpty { m.employeesSource = file.fileName }
                    }
                    needsReanalysis.insert(mid)
                    alertMessage = "In „\(file.fileName)“ wurde eine Personalliste erkannt (\(people.count) Personen) und übernommen. Alle Dokumente werden damit noch einmal geprüft."
                }
            }

            progressText = "Lese Text: \(file.fileName)"
            mutate(mid) { m in
                if let i = m.files.firstIndex(where: { $0.id == fid }) {
                    m.files[i].method = method
                    m.files[i].status = .analyzing
                }
            }
            let pages = try await TextExtractor.extract(pdfURL: pdf)
            await Task.detached(priority: .utility) { Storage.savePages(pages, mandate: mid, file: fid) }.value

            var docType = file.docType
            var reason = file.excludedReason
            if !file.typeLockedByUser {
                let folder = (file.relativePath as NSString).deletingLastPathComponent
                let r = Classifier.classify(fileName: file.fileName, folderPath: folder, pages: pages)
                docType = r.type
                reason = r.excludedReason
            }
            mutate(mid) { m in
                if let i = m.files.firstIndex(where: { $0.id == fid }) {
                    m.files[i].docType = docType
                    m.files[i].excludedReason = reason
                    m.files[i].pageCount = pages.count
                    m.files[i].pageSizes = pages.map { [$0.width, $0.height] }
                }
            }
            if docType == .excluded {
                mutate(mid) { m in m.findings.removeAll { $0.fileID == fid && $0.entityKey != "manual" } }
                setStatus(mid, fid, .done)
                return
            }

            guard let snapshot = mandate(mid) else { return }
            let matcher = ListMatcher(mandate: snapshot)
            var mentions = await Task.detached(priority: .userInitiated) {
                Analyzer.ruleAndListMentions(pages: pages, matcher: matcher)
            }.value

            if snapshot.profile.useAI && ai.isReady {
                let includeDates = DocType.allCases.contains { snapshot.profile.kinds(for: $0).contains(.date) }
                for page in pages where !page.text.isEmpty {
                    progressText = "KI prüft \(file.fileName) – Seite \(page.index + 1) von \(pages.count)"
                    let spans = await ai.detect(page.text)
                    mentions += Analyzer.aiMentions(spans, page: page, existing: mentions, matcher: matcher, includeDates: includeDates)
                }
            }

            let all = mentions
            let located = await Task.detached(priority: .userInitiated) {
                Analyzer.locate(all, pdfURL: pdf, pages: pages)
            }.value
            mutate(mid) { m in
                m.ingest(located, fileID: fid)
                if let i = m.files.firstIndex(where: { $0.id == fid }) {
                    m.files[i].status = .done
                    m.files[i].message = ""
                }
            }
        } catch {
            setStatus(mid, fid, .failed, message: error.localizedDescription)
        }
    }

    private func propagate(_ mid: UUID) async {
        guard let m = mandate(mid) else { return }
        progressText = "Übertrage auf alle Dokumente …"
        let targets = m.propagationTargets()
        guard !targets.isEmpty else { return }
        let existing = m.rangeIndex()
        var keysPerFile: [UUID: Set<String>] = [:]
        for f in m.findings { keysPerFile[f.fileID, default: []].insert(f.entityKey) }
        let files = m.files
        let found = await Task.detached(priority: .userInitiated) {
            Analyzer.propagate(mandateID: mid, files: files, targets: targets, existingRanges: existing, keysPerFile: keysPerFile)
        }.value
        if !found.isEmpty {
            mutate(mid) { $0.findings.append(contentsOf: found) }
        }
    }

    // MARK: - Index für die Anzeige

    func rebuildIndex() {
        guard let m = current else {
            stats = [:]
            redactionsByFile = [:]
            return
        }
        var types: [UUID: DocType] = [:]
        for f in m.files { types[f.id] = f.docType }
        var s: [String: EntityStat] = [:]
        var perFile: [UUID: Int] = [:]
        for f in m.findings where !f.suppressed {
            guard let e = m.entities[f.entityKey], let t = types[f.fileID], m.profile.isEnabled(e.kind, for: t) else { continue }
            var stat = s[f.entityKey] ?? EntityStat()
            stat.hits += 1
            stat.files.insert(f.fileID)
            stat.types.insert(t)
            s[f.entityKey] = stat
            if e.decision != .keep { perFile[f.fileID, default: 0] += f.rects.count }
        }
        stats = s
        redactionsByFile = perFile
    }

    // MARK: - Abgeleitete Listen

    func fileCount(_ item: SidebarItem) -> Int {
        guard let m = current else { return 0 }
        switch item {
        case .all: return m.files.count
        case .type(let t): return m.files.filter { $0.docType == t && $0.status == .done }.count
        case .problems: return m.files.filter { $0.status == .failed || $0.status == .unsupported }.count
        }
    }

    var filteredFiles: [SourceFile] {
        guard let m = current else { return [] }
        let base: [SourceFile]
        switch sidebarItem {
        case .all: base = m.files
        case .type(let t): base = m.files.filter { $0.docType == t && $0.status == .done }
        case .problems: base = m.files.filter { $0.status == .failed || $0.status == .unsupported }
        }
        let q = search.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return base }
        return base.filter { $0.relativePath.localizedCaseInsensitiveContains(q) }
    }

    private func entityMatchesSidebar(_ stat: EntityStat) -> Bool {
        switch sidebarItem {
        case .all: return true
        case .type(let t): return stat.types.contains(t)
        case .problems: return false
        }
    }

    var activeRows: [EntityRow] {
        guard let m = current else { return [] }
        return m.entities.values.compactMap { e in
            guard e.kind != .manual, let stat = stats[e.key], stat.hits > 0, entityMatchesSidebar(stat) else { return nil }
            return EntityRow(entity: e, stat: stat)
        }
    }

    var groupedEntities: [EntityGroup] {
        let q = search.trimmingCharacters(in: .whitespaces)
        var rows = activeRows
        switch decisionFilter {
        case .all: break
        case .pending: rows = rows.filter { $0.entity.decision == .pending }
        case .redact: rows = rows.filter { $0.entity.decision == .redact }
        case .keep: rows = rows.filter { $0.entity.decision == .keep }
        }
        if !q.isEmpty {
            rows = rows.filter {
                $0.entity.display.localizedCaseInsensitiveContains(q) || ($0.entity.replacement ?? "").localizedCaseInsensitiveContains(q)
            }
        }
        let grouped = Dictionary(grouping: rows) { $0.entity.kind }
        return grouped.keys.sorted { $0.groupOrder < $1.groupOrder }.map { kind in
            let sorted = grouped[kind]!.sorted {
                if ($0.entity.decision == .pending) != ($1.entity.decision == .pending) { return $0.entity.decision == .pending }
                if $0.stat.hits != $1.stat.hits { return $0.stat.hits > $1.stat.hits }
                return $0.entity.display.localizedCompare($1.entity.display) == .orderedAscending
            }
            return EntityGroup(kind: kind, rows: sorted)
        }
    }

    var pendingCount: Int { activeRows.filter { $0.entity.decision == .pending }.count }

    var unsureQueue: [EntityRow] {
        activeRows
            .filter { $0.entity.decision == .pending && !skippedUnsure.contains($0.entity.key) }
            .sorted { $0.stat.hits > $1.stat.hits }
    }

    var totalPendingFindings: Int {
        activeRows.filter { $0.entity.decision == .pending }.reduce(0) { $0 + $1.stat.hits }
    }

    func findings(for key: String, limit: Int = 30) -> [Finding] {
        guard let m = current else { return [] }
        var out: [Finding] = []
        for f in m.findings where f.entityKey == key {
            out.append(f)
            if out.count >= limit { break }
        }
        return out
    }

    func findings(file: UUID, page: Int) -> [(Finding, Entity)] {
        guard let m = current else { return [] }
        guard let type = m.file(file)?.docType else { return [] }
        return m.findings.compactMap { f in
            guard f.fileID == file, f.page == page, let e = m.entities[f.entityKey], m.profile.isEnabled(e.kind, for: type) else { return nil }
            return (f, e)
        }
    }

    // MARK: - Entscheidungen

    func setDecision(_ key: String, _ decision: Decision) {
        mutate { m in
            guard var e = m.entities[key], !e.locked else { return }
            e.decision = decision
            e.userDecided = true
            m.entities[key] = e
        }
    }

    func setDecision(keys: [String], _ decision: Decision) {
        mutate { m in
            for key in keys {
                guard var e = m.entities[key], !e.locked else { continue }
                e.decision = decision
                e.userDecided = true
                m.entities[key] = e
            }
        }
    }

    func setRole(_ key: String, _ role: Role) {
        mutate { m in
            guard var e = m.entities[key], e.role != role else { return }
            e.role = role
            if role == .employee, let n = e.personNumber, !n.isEmpty {
                e.replacement = m.profile.employeePrefix + n
            } else {
                e.replacement = m.nextNumber(for: role)
            }
            m.entities[key] = e
        }
    }

    func setReplacement(_ key: String, _ text: String) {
        mutate { m in
            guard var e = m.entities[key] else { return }
            let t = text.trimmingCharacters(in: .whitespaces)
            e.replacement = t.isEmpty ? nil : t
            m.entities[key] = e
        }
    }

    func addNever(_ term: String) {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        mutate { m in
            if !m.neverTerms.contains(where: { Norm.key($0) == Norm.key(t) }) { m.neverTerms.append(t) }
            for (k, var e) in Array(m.entities) where m.isNeverTerm(e.display) {
                e.decision = .keep
                e.locked = true
                e.lockReason = "Nie-Liste"
                m.entities[k] = e
            }
        }
    }

    func removeNever(_ term: String) {
        mutate { m in
            m.neverTerms.removeAll { $0 == term }
            for (k, var e) in Array(m.entities) where e.lockReason == "Nie-Liste" && !m.isNeverTerm(e.display) {
                e.locked = false
                e.lockReason = ""
                e.decision = .pending
                m.entities[k] = e
            }
        }
    }

    func addAlways(_ term: String) {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let mid = currentID else { return }
        let key = "t:" + Norm.compact(t)
        mutate { m in
            if !m.alwaysTerms.contains(t) { m.alwaysTerms.append(t) }
            var e = m.entities[key] ?? Entity(key: key, display: t, kind: .term, role: nil, replacement: nil, decision: .redact)
            e.decision = .redact
            e.locked = true
            e.lockReason = "Immer-Liste"
            e.sources.insert("Begriff")
            if !e.surfaces.contains(t) { e.surfaces.append(t) }
            m.entities[key] = e
        }
        Task { await self.propagate(mid); self.rebuildIndex() }
    }

    func removeAlways(_ term: String) {
        let key = "t:" + Norm.compact(term)
        mutate { m in
            m.alwaysTerms.removeAll { $0 == term }
            m.entities[key] = nil
            m.findings.removeAll { $0.entityKey == key }
        }
    }

    // MARK: - Manuelle Bereiche

    func addManualBox(file: UUID, page: Int, box: Box) {
        mutate { m in
            if m.entities["manual"] == nil {
                var e = Entity(key: "manual", display: "Manuell geschwärzt", kind: .manual, role: nil, replacement: nil, decision: .redact)
                e.locked = true
                e.lockReason = "Manuell"
                e.sources = ["Manuell"]
                m.entities["manual"] = e
            }
            m.findings.append(Finding(entityKey: "manual", fileID: file, page: page, location: -Int.random(in: 1...Int(Int32.max)),
                                      length: 0, rects: [box], before: "", matched: "Bereich", after: ""))
        }
    }

    func toggleFinding(_ id: UUID) {
        mutate { m in
            guard let i = m.findings.firstIndex(where: { $0.id == id }) else { return }
            if m.findings[i].entityKey == "manual" {
                m.findings.remove(at: i)
            } else {
                m.findings[i].suppressed.toggle()
            }
        }
    }

    // MARK: - Listen importieren

    enum ListKind { case employees, suppliers, customers }

    func importList(_ kind: ListKind) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "xlsx")!, .commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.message = kind == .employees ? "Personalliste wählen (Excel oder CSV)" : "Liste wählen (Excel oder CSV)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let rows = try ListImporter.readTable(url)
            switch kind {
            case .employees:
                let people = ListImporter.employees(from: rows)
                guard !people.isEmpty else { throw AppError("In der Datei wurden keine Namen gefunden") }
                mutate { $0.employees = people; $0.employeesSource = url.lastPathComponent }
            case .suppliers:
                let items = ListImporter.companies(from: rows)
                guard !items.isEmpty else { throw AppError("In der Datei wurden keine Firmen gefunden") }
                mutate { $0.suppliers = items; $0.suppliersSource = url.lastPathComponent }
            case .customers:
                let items = ListImporter.companies(from: rows)
                guard !items.isEmpty else { throw AppError("In der Datei wurden keine Firmen gefunden") }
                mutate { $0.customers = items; $0.customersSource = url.lastPathComponent }
            }
            if let m = current, m.files.contains(where: { $0.status == .done }) {
                alertMessage = "Liste übernommen. Unter „Dateien“ → „Erneut analysieren“ wird sie auf alle Dokumente angewendet."
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    // MARK: - Vorschaubilder

    func thumbnail(file: UUID, page: Int, size: CGSize) async -> NSImage? {
        guard let mid = currentID else { return nil }
        let key = "\(file.uuidString)-\(page)-\(Int(size.width))" as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        let url = Paths.workPDF(mid, file)
        let image = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let doc = PDFDocument(url: url), let p = doc.page(at: page) else { return nil }
            return p.thumbnail(of: size, for: .mediaBox)
        }.value
        if let image { thumbnails.setObject(image, forKey: key) }
        return image
    }

    // MARK: - Export

    func runExport(_ settings: ExportSettings) {
        guard let m = current else { return }
        exportRunning = true
        exportResult = nil
        exportProgress = 0
        let snapshot = m
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try await Exporter.export(mandate: snapshot, settings: settings) { value, text in
                        Task { @MainActor in
                            self.exportProgress = value
                            self.exportText = text
                        }
                    }
                }.value
                self.exportResult = result
                self.mutate(snapshot.id) { $0.lastExportPath = settings.outputFolder.path }
            } catch {
                self.alertMessage = "Export fehlgeschlagen: \(error.localizedDescription)"
            }
            self.exportRunning = false
        }
    }
}
