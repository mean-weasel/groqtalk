import Foundation
import Security

enum KeychainHelper {
    private static let service = "com.neonwatty.GroqTalk"
    private static let account = "groq-api-key"

    private static var storageURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("GroqTalk", isDirectory: true)
        return dir.appendingPathComponent("api-key")
    }

    static func save(apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let dir = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(trimmed.utf8).write(to: storageURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: storageURL.path
        )
    }

    static func readApiKey() -> String? {
        if let data = try? Data(contentsOf: storageURL),
           let key = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            return key
        }
        return readFromLegacyKeychain()
    }

    static func delete() {
        try? FileManager.default.removeItem(at: storageURL)
        deleteLegacyKeychain()
    }

    // MARK: - Legacy keychain migration

    private static func readFromLegacyKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { return nil }
        // Migrate to file storage — only delete legacy on success
        if (try? save(apiKey: key)) != nil {
            deleteLegacyKeychain()
        }
        return key
    }

    private static func deleteLegacyKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
