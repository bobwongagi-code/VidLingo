import CryptoKit
import Foundation
import Security
import VidLingoCore

enum TranslationAPIKeyStore {
    private static let account = "API_KEY"
    private static let legacyAccount = "OPENAI_API_KEY"

    static func hasAPIKey(
        for provider: TranslationProviderID,
        customEndpoint: ValidatedEndpoint? = nil
    ) -> Bool {
        availability(for: provider, customEndpoint: customEndpoint) == .configured
    }

    static func availability(
        for provider: TranslationProviderID,
        customEndpoint: ValidatedEndpoint? = nil
    ) -> KeychainAvailability {
        guard let service = try? keychainService(for: provider, customEndpoint: customEndpoint) else {
            return .missing
        }
        return availability(service: service)
    }

    static func availability(service: String) -> KeychainAvailability {
        do {
            guard let key = try readAPIKey(service: service), !key.isEmpty else {
                return .missing
            }
            return .configured
        } catch let error as TranslationAPIKeyStoreError {
            return error.availability
        } catch {
            return .corrupted
        }
    }

    static func readAPIKey(
        for provider: TranslationProviderID,
        customEndpoint: ValidatedEndpoint? = nil
    ) throws -> String? {
        try readAPIKey(service: keychainService(for: provider, customEndpoint: customEndpoint))
    }

    static func readAPIKey(service: String) throws -> String? {
        for (service, account) in keychainLookups(service: service) {
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

    static func saveAPIKey(
        _ key: String,
        for provider: TranslationProviderID,
        customEndpoint: ValidatedEndpoint? = nil
    ) throws {
        try saveAPIKey(
            key,
            service: keychainService(for: provider, customEndpoint: customEndpoint)
        )
    }

    static func saveAPIKey(_ key: String, service: String) throws {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw TranslationAPIKeyStoreError.emptyKey
        }
        guard let data = trimmedKey.data(using: .utf8) else {
            throw TranslationAPIKeyStoreError.invalidStoredKey
        }

        let query = baseQuery(service: service, account: account)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw TranslationAPIKeyStoreError.keychainStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw TranslationAPIKeyStoreError.keychainStatus(addStatus)
        }
    }

    static func deleteAPIKey(
        for provider: TranslationProviderID,
        customEndpoint: ValidatedEndpoint? = nil
    ) throws {
        try deleteAPIKey(service: keychainService(for: provider, customEndpoint: customEndpoint))
    }

    static func keychainService(
        for provider: TranslationProviderID,
        customEndpoint: ValidatedEndpoint? = nil
    ) throws -> String {
        guard provider == .custom else { return provider.keychainService }
        guard let customEndpoint else {
            throw TranslationAPIKeyStoreError.customEndpointRequired
        }
        let originDigest = SHA256.hash(data: Data(customEndpoint.origin.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(provider.keychainService).\(originDigest)"
    }

    static func deleteAPIKey(service: String) throws {
        for (service, account) in keychainLookups(service: service) {
            let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw TranslationAPIKeyStoreError.keychainStatus(status)
            }
        }
    }

    private static func keychainLookups(service: String) -> [(service: String, account: String)] {
        [
            (service, account),
            (service, legacyAccount)
        ]
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
    case customEndpointRequired
    case invalidStoredKey
    case keychainStatus(OSStatus)

    var availability: KeychainAvailability {
        switch self {
        case .customEndpointRequired:
            .missing
        case .emptyKey, .invalidStoredKey:
            .corrupted
        case let .keychainStatus(status):
            KeychainAvailability.from(status: status)
        }
    }

    var errorDescription: String? {
        switch self {
        case .emptyKey:
            AppText.translationAPIKeyEmpty
        case .customEndpointRequired:
            AppText.customEndpointRequiredToSaveKey
        case .invalidStoredKey:
            AppText.translationAPIKeyInvalidStoredValue
        case let .keychainStatus(status):
            AppText.translationAPIKeychainFailed(status)
        }
    }
}
