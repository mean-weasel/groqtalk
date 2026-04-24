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
    private static let maxRecords = 20

    /// Transcription records, sorted newest-first.
    /// Insertion order is load-bearing for retry logic.
    private(set) var records: [TranscriptionRecord] = []
    private let historyFileURL: URL

    init(storageDirectory: URL) {
        self.historyFileURL = storageDirectory.appendingPathComponent("history.json")
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

    // MARK: - Private

    private func insert(_ record: TranscriptionRecord) {
        records.insert(record, at: 0)
        while records.count > Self.maxRecords {
            let evicted = records.removeLast()
            if let audioURL = evicted.audioFileURL {
                try? FileManager.default.removeItem(at: audioURL)
            }
        }
        save()
    }

    private func save() {
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
}
