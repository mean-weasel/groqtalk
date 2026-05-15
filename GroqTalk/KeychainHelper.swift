import Foundation
import Security

enum KeychainHelper {
    private static let defaultService = "com.neonwatty.GroqTalk"
    private static let defaultAccount = "groq-api-key"

    #if DEBUG
    static var storageDirectoryOverride: URL?
    static var serviceOverride: String?
    static var accountOverride: String?
    #endif

    private static var service: String {
        #if DEBUG
        serviceOverride ?? defaultService
        #else
        defaultService
        #endif
    }

    private static func account(for providerID: TranscriptionProviderID) -> String {
        #if DEBUG
        let base = accountOverride ?? defaultAccount
        #else
        let base = defaultAccount
        #endif
        switch providerID {
        case .groq:
            return base
        case .openAICompatible:
            return "\(base).\(providerID.rawValue)"
        }
    }

    private static var legacyPlaintextStorageURL: URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        #if DEBUG
        if let storageDirectoryOverride {
            return storageDirectoryOverride.appendingPathComponent("api-key")
        }
        #endif

        let dir = appSupport.appendingPathComponent("GroqTalk", isDirectory: true)
        return dir.appendingPathComponent("api-key")
    }

    static func save(apiKey: String) throws {
        try save(apiKey: apiKey, for: .groq)
    }

    static func save(apiKey: String, for providerID: TranscriptionProviderID) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try saveToKeychain(apiKey: trimmed, for: providerID)
        if providerID == .groq, let legacyURL = legacyPlaintextStorageURL {
            try? FileManager.default.removeItem(at: legacyURL)
        }
    }

    static func readApiKey() -> String? {
        readApiKey(for: .groq)
    }

    static func readApiKey(for providerID: TranscriptionProviderID) -> String? {
        if let key = readFromKeychain(for: providerID) {
            if providerID == .groq, let legacyURL = legacyPlaintextStorageURL {
                try? FileManager.default.removeItem(at: legacyURL)
            }
            return key
        }
        guard providerID == .groq else { return nil }
        return migrateLegacyPlaintextFile()
    }

    static func delete() {
        delete(for: .groq)
    }

    static func delete(for providerID: TranscriptionProviderID) {
        deleteFromKeychain(for: providerID)
        if providerID == .groq, let legacyURL = legacyPlaintextStorageURL {
            try? FileManager.default.removeItem(at: legacyURL)
        }
    }

    // MARK: - Keychain storage

    private static func saveToKeychain(apiKey: String, for providerID: TranscriptionProviderID = .groq) throws {
        let data = Data(apiKey.utf8)
        let query = baseQuery(for: providerID)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let addStatus = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        if addStatus == errSecSuccess { return }

        if addStatus == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unhandledStatus(updateStatus)
            }
            return
        }

        throw KeychainError.unhandledStatus(addStatus)
    }

    private static func readFromKeychain(for providerID: TranscriptionProviderID = .groq) -> String? {
        var query = baseQuery(for: providerID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            return nil
        }
        return key
    }

    private static func deleteFromKeychain(for providerID: TranscriptionProviderID = .groq) {
        SecItemDelete(baseQuery(for: providerID) as CFDictionary)
    }

    private static func baseQuery(for providerID: TranscriptionProviderID = .groq) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: providerID)
        ]
    }

    // MARK: - Legacy plaintext migration

    private static func migrateLegacyPlaintextFile() -> String? {
        guard let legacyURL = legacyPlaintextStorageURL,
              let data = try? Data(contentsOf: legacyURL),
              let key = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            if let legacyURL = legacyPlaintextStorageURL {
                try? FileManager.default.removeItem(at: legacyURL)
            }
            return nil
        }

        do {
            try saveToKeychain(apiKey: key, for: .groq)
            try? FileManager.default.removeItem(at: legacyURL)
            return key
        } catch {
            DiagnosticLog.write("KeychainHelper: failed to migrate legacy plaintext API key status=\(error.localizedDescription)")
            return key
        }
    }

    enum KeychainError: LocalizedError, Equatable {
        case unhandledStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unhandledStatus(let status):
                if let message = SecCopyErrorMessageString(status, nil) as String? {
                    return message
                }
                return "Keychain error \(status)"
            }
        }
    }
}
