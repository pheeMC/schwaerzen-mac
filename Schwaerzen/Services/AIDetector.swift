import Foundation
@preconcurrency import OpenMedKit

struct AISpan {
    var label: String
    var text: String
    /// Unicode-Scalar-Offsets im übergebenen Text
    var start: Int
    var end: Int
    var confidence: Double
}

/// Lokales KI-Modell (OpenAI Privacy Filter über OpenMedKit/MLX) – dasselbe Modell wie in HideMyData.
@Observable
@MainActor
final class AIDetector {
    enum Phase: Equatable {
        case checking
        case missing
        case downloading(Int64, Int64)
        case loading
        case ready
        case failed(String)
    }

    nonisolated static let repoID = "OpenMed/privacy-filter-mlx-8bit"

    var phase: Phase = .checking
    var sourceDescription: String = ""

    private var model: OpenMed?

    var isReady: Bool { phase == .ready }

    var statusText: String {
        switch phase {
        case .checking: return "KI-Modell wird gesucht …"
        case .missing: return "KI-Modell nicht gefunden"
        case .downloading(let done, let total):
            let d = done.formatted(.byteCount(style: .file))
            if total > 0 {
                let t = total.formatted(.byteCount(style: .file))
                return "Lade KI-Modell … \(d) von \(t)"
            }
            return "Lade KI-Modell … \(d)"
        case .loading: return "KI-Modell wird geladen …"
        case .ready: return "KI-Modell bereit"
        case .failed(let m): return "KI-Modell: \(m)"
        }
    }

    /// Sucht das Modell im eigenen Cache und in den Ablageorten von HideMyData.
    func locateAndLoad() async {
        phase = .checking
        for dir in Paths.modelCacheCandidates {
            let state = (try? OpenMedModelStore.mlxModelCacheState(repoID: Self.repoID, cacheDirectory: dir)) ?? .missing
            if state == .ready {
                sourceDescription = dir.path.contains("HideMyData") ? "von HideMyData übernommen" : "eigener Speicher"
                await load(cacheDirectory: dir)
                if isReady { return }
            }
        }
        if case .failed = phase { return }
        phase = .missing
    }

    func download() async {
        let downloader = ModelDownloader(repoID: Self.repoID, cacheRoot: Paths.ownModelCache)
        phase = .downloading(0, 0)
        downloader.onProgress = { [weak self] done, total in
            self?.phase = .downloading(done, total)
        }
        do {
            _ = try await downloader.download()
            sourceDescription = "eigener Speicher"
            await load(cacheDirectory: Paths.ownModelCache)
        } catch {
            phase = .failed("Download fehlgeschlagen – \(error.localizedDescription)")
        }
    }

    private func load(cacheDirectory: URL) async {
        phase = .loading
        do {
            let url = try await OpenMedModelStore.downloadMLXModel(repoID: Self.repoID, cacheDirectory: cacheDirectory)
            let loaded = try OpenMed(backend: .mlx(modelDirectoryURL: url))
            model = loaded
            _ = await Task.detached(priority: .userInitiated) {
                try? loaded.extractPII("Aufwärmen.", confidenceThreshold: 0.5, useSmartMerging: false)
            }.value
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func detect(_ text: String) async -> [AISpan] {
        guard let model, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) { () -> [AISpan] in
            guard let entities = try? model.extractPII(text, confidenceThreshold: 0.4, useSmartMerging: false) else { return [] }
            return entities.map {
                AISpan(label: $0.label, text: $0.text, start: $0.start, end: $0.end, confidence: Double($0.confidence))
            }
        }.value
    }

    /// Ordnet die Kategorien des Modells den eigenen Erkennungsarten zu.
    nonisolated static func kind(for label: String) -> Kind? {
        let l = label.lowercased()
        if l.contains("person") || l.contains("name") { return .name }
        if l.contains("address") || l.contains("location") { return .address }
        if l.contains("email") || l.contains("phone") || l.contains("url") { return .contact }
        if l.contains("date") { return .date }
        if l.contains("account") { return .bank }
        if l.contains("secret") || l.contains("id") { return .identifier }
        return nil
    }
}
