import Foundation
import Security

enum KeychainAvailability: Equatable, Sendable {
    case configured
    case missing
    case locked
    case accessDenied
    case corrupted

    static func from(status: OSStatus) -> KeychainAvailability {
        switch status {
        case errSecSuccess:
            .configured
        case errSecItemNotFound:
            .missing
        case errSecInteractionNotAllowed:
            .locked
        case errSecAuthFailed, errSecNoAccessForItem:
            .accessDenied
        default:
            .corrupted
        }
    }
}
