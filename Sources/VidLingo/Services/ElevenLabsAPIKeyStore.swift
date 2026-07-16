import Foundation
import Security

enum ElevenLabsAPIKeyStore {
    private static let service = "VidLingo.ElevenLabs"
    private static let account = "API_KEY"

    static var hasAPIKey: Bool {
        guard let key = try? readAPIKey() else { return false }
        return !key.isEmpty
    }

    static func readAPIKey() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw ElevenLabsAPIKeyStoreError.keychainStatus(status)
        }
        guard let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw ElevenLabsAPIKeyStoreError.invalidStoredKey
        }
        return key
    }

    static func saveAPIKey(_ key: String) throws {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw ElevenLabsAPIKeyStoreError.emptyKey }
        guard let data = trimmedKey.data(using: .utf8) else {
            throw ElevenLabsAPIKeyStoreError.invalidStoredKey
        }

        SecItemDelete(baseQuery as CFDictionary)
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ElevenLabsAPIKeyStoreError.keychainStatus(status)
        }
    }

    static func deleteAPIKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ElevenLabsAPIKeyStoreError.keychainStatus(status)
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum ElevenLabsAPIKeyStoreError: LocalizedError {
    case emptyKey
    case invalidStoredKey
    case keychainStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyKey:
            "保存前请输入 ElevenLabs API key。"
        case .invalidStoredKey:
            "保存的 ElevenLabs API key 无法读取。"
        case let .keychainStatus(status):
            "ElevenLabs Keychain 操作失败（\(status)）。"
        }
    }
}
