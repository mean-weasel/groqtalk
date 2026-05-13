import Foundation
import Observation

struct TranscriptionRecord: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    var outcome: Outcome

    enum Outcome: Codable {
        case success(text: String)
        case failure(error: String, audioFileURL: URL?)
    }

    var text: String? {
        if case .success(let t) = outcome { return t }
        return nil
    }

    var error: String? {
        if case .failure(let e, _) = outcome { return e }
        return nil
    }

    var audioFileURL: URL? {
        if case .failure(_, let url) = outcome { return url }
        return nil
    }

    var isFailure: Bool {
        if case .failure = outcome { return true }
        return false
    }

    var previewText: String {
        let source = text ?? error ?? ""
        if source.count <= 40 { return source }
        return String(source.prefix(40)) + "..."
    }

    var relativeTimestamp: String {
        let interval = Date().timeIntervalSince(timestamp)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }
}

@MainActor @Observable
final class TranscriptionHistory {
    nonisolated static let maxRecords = 500

    /// Transcription records, sorted newest-first.
    /// Insertion order is load-bearing for retry logic.
    private(set) var records: [TranscriptionRecord] = []
    var retentionLimit: Int {
        didSet {
            trimToRetentionLimit()
            save()
        }
    }

    var isPersistenceEnabled: Bool {
        didSet {
            if !isPersistenceEnabled {
                clear()
                try? FileManager.default.removeItem(at: historyFileURL)
            } else {
                save()
            }
        }
    }

    private let historyFileURL: URL

    init(
        storageDirectory: URL,
        retentionLimit: Int = TranscriptionHistory.maxRecords,
        isPersistenceEnabled: Bool = true
    ) {
        self.historyFileURL = storageDirectory.appendingPathComponent("history.json")
        self.retentionLimit = retentionLimit
        self.isPersistenceEnabled = isPersistenceEnabled
        load()
    }

    /// Convenience init using the default Application Support directory.
    convenience init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("GroqTalk", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.init(storageDirectory: dir)
    }

    func addSuccess(text: String) {
        let record = TranscriptionRecord(
            id: UUID(), timestamp: Date(), outcome: .success(text: text)
        )
        insert(record)
    }

    func addFailure(error: String, audioFileURL: URL?) {
        let record = TranscriptionRecord(
            id: UUID(), timestamp: Date(), outcome: .failure(error: error, audioFileURL: audioFileURL)
        )
        insert(record)
    }

    func resolveRetry(id: UUID, text: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        // Delete the audio file since retry succeeded
        if let audioURL = records[index].audioFileURL {
            try? FileManager.default.removeItem(at: audioURL)
        }
        records[index].outcome = .success(text: text)
        save()
    }

    func resolveRetryFailure(id: UUID, error: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let audioURL = records[index].audioFileURL
        records[index].outcome = .failure(error: error, audioFileURL: audioURL)
        save()
    }

    func updateSuccess(id: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = records.firstIndex(where: { $0.id == id }),
              !records[index].isFailure else { return }
        records[index].outcome = .success(text: trimmed)
        save()
    }

    /// Returns the most recent record if it is a failure with a retryable audio file.
    var retryableRecord: TranscriptionRecord? {
        guard let first = records.first,
              first.isFailure,
              let url = first.audioFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return first
    }

    var successfulRecords: [TranscriptionRecord] {
        records.filter { !$0.isFailure }
    }

    func recentRecords(limit: Int) -> [TranscriptionRecord] {
        Array(records.prefix(limit))
    }

    func delete(id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let removed = records.remove(at: index)
        if let audioURL = removed.audioFileURL {
            try? FileManager.default.removeItem(at: audioURL)
        }
        save()
    }

    func clear() {
        for record in records {
            if let audioURL = record.audioFileURL {
                try? FileManager.default.removeItem(at: audioURL)
            }
        }
        records = []
        save()
    }

    /// Delete all records older than the given date.
    func deleteOlderThan(_ date: Date) {
        let toDelete = records.filter { $0.timestamp < date }
        for record in toDelete {
            if let url = record.audioFileURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
        records.removeAll { $0.timestamp < date }
        save()
    }

    /// Delete all records matching the given IDs.
    func deleteAll(ids: Set<UUID>) {
        for record in records where ids.contains(record.id) {
            if let url = record.audioFileURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
        records.removeAll { ids.contains($0.id) }
        save()
    }

    /// Delete records from a given array (e.g., filtered results).
    func deleteFiltered(_ recordsToDelete: [TranscriptionRecord]) {
        let ids = Set(recordsToDelete.map(\.id))
        deleteAll(ids: ids)
    }

    var retainedFailedAudioCount: Int {
        records.reduce(0) { count, record in
            guard let url = record.audioFileURL,
                  FileManager.default.fileExists(atPath: url.path) else {
                return count
            }
            return count + 1
        }
    }

    func clearRetainedFailedAudio() {
        var updated = false
        for index in records.indices {
            guard case .failure(let error, let audioURL) = records[index].outcome,
                  let audioURL else { continue }
            try? FileManager.default.removeItem(at: audioURL)
            records[index].outcome = .failure(error: error, audioFileURL: nil)
            updated = true
        }
        if updated { save() }
    }

    func exportMarkdown() -> String {
        records.map { record in
            let kind = record.isFailure ? "Failure" : "Transcript"
            let body = record.text ?? record.error ?? ""
            return """
            ## \(kind) - \(Self.exportDateFormatter.string(from: record.timestamp))

            \(body)
            """
        }
        .joined(separator: "\n\n")
    }

    func exportJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    // MARK: - Private

    private func insert(_ record: TranscriptionRecord) {
        guard isPersistenceEnabled, effectiveRetentionLimit > 0 else {
            if let audioURL = record.audioFileURL {
                try? FileManager.default.removeItem(at: audioURL)
            }
            return
        }
        records.insert(record, at: 0)
        trimToRetentionLimit()
        save()
    }

    private func trimToRetentionLimit() {
        while records.count > effectiveRetentionLimit {
            let evicted = records.removeLast()
            if let audioURL = evicted.audioFileURL {
                try? FileManager.default.removeItem(at: audioURL)
            }
        }
    }

    private var effectiveRetentionLimit: Int {
        max(0, retentionLimit)
    }

    private func save() {
        guard isPersistenceEnabled else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(records)
            try data.write(to: historyFileURL, options: .atomic)
        } catch {
            print("TranscriptionHistory: failed to save — \(error)")
        }
    }

    private func load() {
        guard isPersistenceEnabled else { return }
        guard FileManager.default.fileExists(atPath: historyFileURL.path) else { return }
        do {
            let data = try Data(contentsOf: historyFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            records = try decoder.decode([TranscriptionRecord].self, from: data)
        } catch {
            print("TranscriptionHistory: failed to load — \(error)")
            records = []
        }
    }

    private static let exportDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
