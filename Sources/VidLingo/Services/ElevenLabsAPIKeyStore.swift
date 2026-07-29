import Foundation
import Security

enum ElevenLabsAPIKeyStore {
    private static let service = "VidLingo.ElevenLabs"
    private static let account = "API_KEY"

    static var hasAPIKey: Bool {
        availability == .configured
    }

    static var availability: KeychainAvailability {
        do {
            guard let key = try readAPIKey(), !key.isEmpty else { return .missing }
            return .configured
        } catch let error as ElevenLabsAPIKeyStoreError {
            return error.availability
        } catch {
            return .corrupted
        }
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

        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw ElevenLabsAPIKeyStoreError.keychainStatus(updateStatus)
        }
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ElevenLabsAPIKeyStoreError.keychainStatus(addStatus)
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

    var availability: KeychainAvailability {
        switch self {
        case .emptyKey, .invalidStoredKey:
            .corrupted
        case let .keychainStatus(status):
            KeychainAvailability.from(status: status)
        }
    }

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
