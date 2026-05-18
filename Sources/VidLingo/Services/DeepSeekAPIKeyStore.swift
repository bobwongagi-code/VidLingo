import Foundation
import Security

enum DeepSeekAPIKeyStore {
    private static let service = "VidLingo.DeepSeek"
    private static let legacyServices = ["VidLingo.OpenAI", "AirTranslate.OpenAI"]
    private static let account = "OPENAI_API_KEY"

    static func hasAPIKey() -> Bool {
        guard let key = try? readAPIKey() else { return false }
        return !key.isEmpty
    }

    static func readAPIKey() throws -> String? {
        var query = baseQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return try readLegacyAPIKey()
        }
        guard status == errSecSuccess else {
            throw DeepSeekAPIKeyStoreError.keychainStatus(status)
        }
        guard let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw DeepSeekAPIKeyStoreError.invalidStoredKey
        }
        return key
    }

    static func saveAPIKey(_ key: String) throws {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw DeepSeekAPIKeyStoreError.emptyKey
        }
        guard let data = trimmedKey.data(using: .utf8) else {
            throw DeepSeekAPIKeyStoreError.invalidStoredKey
        }

        SecItemDelete(baseQuery(service: service) as CFDictionary)

        var query = baseQuery(service: service)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw DeepSeekAPIKeyStoreError.keychainStatus(status)
        }
    }

    static func deleteAPIKey() throws {
        let status = SecItemDelete(baseQuery(service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeepSeekAPIKeyStoreError.keychainStatus(status)
        }

        for legacyService in legacyServices {
            let legacyStatus = SecItemDelete(baseQuery(service: legacyService) as CFDictionary)
            guard legacyStatus == errSecSuccess || legacyStatus == errSecItemNotFound else {
                throw DeepSeekAPIKeyStoreError.keychainStatus(legacyStatus)
            }
        }
    }

    private static func readLegacyAPIKey() throws -> String? {
        for legacyService in legacyServices {
            var query = baseQuery(service: legacyService)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecItemNotFound {
                continue
            }
            guard status == errSecSuccess else {
                throw DeepSeekAPIKeyStoreError.keychainStatus(status)
            }
            guard let data = item as? Data,
                  let key = String(data: data, encoding: .utf8) else {
                throw DeepSeekAPIKeyStoreError.invalidStoredKey
            }
            return key
        }
        return nil
    }

    private static func baseQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum DeepSeekAPIKeyStoreError: LocalizedError {
    case emptyKey
    case invalidStoredKey
    case keychainStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyKey:
            AppText.deepSeekAPIKeyEmpty
        case .invalidStoredKey:
            AppText.deepSeekAPIKeyInvalidStoredValue
        case let .keychainStatus(status):
            AppText.deepSeekAPIKeychainFailed(status)
        }
    }
}
