import Foundation
import Security

enum TranslationAPIKeyStore {
    private static let account = "API_KEY"
    private static let legacyAccount = "OPENAI_API_KEY"

    static func hasAPIKey(for provider: TranslationProviderID) -> Bool {
        guard let key = try? readAPIKey(for: provider) else { return false }
        return !key.isEmpty
    }

    static func readAPIKey(for provider: TranslationProviderID) throws -> String? {
        for (service, account) in keychainLookups(for: provider) {
            var query = baseQuery(service: service, account: account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecItemNotFound {
                continue
            }
            guard status == errSecSuccess else {
                throw TranslationAPIKeyStoreError.keychainStatus(status)
            }
            guard let data = item as? Data,
                  let key = String(data: data, encoding: .utf8) else {
                throw TranslationAPIKeyStoreError.invalidStoredKey
            }
            return key
        }

        return nil
    }

    static func saveAPIKey(_ key: String, for provider: TranslationProviderID) throws {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw TranslationAPIKeyStoreError.emptyKey
        }
        guard let data = trimmedKey.data(using: .utf8) else {
            throw TranslationAPIKeyStoreError.invalidStoredKey
        }

        SecItemDelete(baseQuery(service: provider.keychainService, account: account) as CFDictionary)

        var query = baseQuery(service: provider.keychainService, account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw TranslationAPIKeyStoreError.keychainStatus(status)
        }
    }

    static func deleteAPIKey(for provider: TranslationProviderID) throws {
        for (service, account) in keychainLookups(for: provider) {
            let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw TranslationAPIKeyStoreError.keychainStatus(status)
            }
        }
    }

    private static func keychainLookups(for provider: TranslationProviderID) -> [(service: String, account: String)] {
        [
            (provider.keychainService, account),
            (provider.keychainService, legacyAccount)
        ]
            + provider.legacyKeychainServices.map { ($0, legacyAccount) }
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum TranslationAPIKeyStoreError: LocalizedError {
    case emptyKey
    case invalidStoredKey
    case keychainStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyKey:
            AppText.translationAPIKeyEmpty
        case .invalidStoredKey:
            AppText.translationAPIKeyInvalidStoredValue
        case let .keychainStatus(status):
            AppText.translationAPIKeychainFailed(status)
        }
    }
}
