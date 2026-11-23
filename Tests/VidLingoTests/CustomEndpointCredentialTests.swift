import Foundation
import XCTest
@testable import VidLingo
@testable import VidLingoCore

final class CustomEndpointCredentialTests: XCTestCase {
    func testCustomCredentialServiceUsesCanonicalValidatedOrigin() throws {
        let pathOne = try EndpointValidator.validate("https://API.EXAMPLE.COM:443/v1/chat/completions")
        let pathTwo = try EndpointValidator.validate("https://api.example.com/v1/other")
        let otherHost = try EndpointValidator.validate("https://other.example.com/v1/chat/completions")
        let otherPort = try EndpointValidator.validate("https://api.example.com:444/v1/chat/completions")
        let idnaUnicode = try EndpointValidator.validate("https://bücher.example/v1/chat/completions")
        let idnaPunycode = try EndpointValidator.validate("https://xn--bcher-kva.example/v1/chat/completions")
        let idnaEscaped = try EndpointValidator.validate("https://b%C3%BCcher.example/v1/chat/completions")

        let firstService = try TranslationAPIKeyStore.keychainService(for: .custom, customEndpoint: pathOne)
        let secondService = try TranslationAPIKeyStore.keychainService(for: .custom, customEndpoint: pathTwo)

        XCTAssertEqual(firstService, secondService)
        XCTAssertNotEqual(firstService, TranslationProviderID.custom.keychainService)
        XCTAssertNotEqual(
            firstService,
            try TranslationAPIKeyStore.keychainService(for: .custom, customEndpoint: otherHost)
        )
        XCTAssertNotEqual(
            firstService,
            try TranslationAPIKeyStore.keychainService(for: .custom, customEndpoint: otherPort)
        )
        XCTAssertEqual(
            try TranslationAPIKeyStore.keychainService(for: .custom, customEndpoint: idnaUnicode),
            try TranslationAPIKeyStore.keychainService(for: .custom, customEndpoint: idnaPunycode)
        )
        XCTAssertNotEqual(
            try TranslationAPIKeyStore.keychainService(for: .custom, customEndpoint: idnaUnicode),
            try TranslationAPIKeyStore.keychainService(for: .custom, customEndpoint: idnaEscaped)
        )
        XCTAssertEqual(
            try TranslationAPIKeyStore.keychainService(for: .rootify, customEndpoint: nil),
            TranslationProviderID.rootify.keychainService
        )
    }

    func testCustomCredentialServiceRequiresValidatedEndpoint() {
        XCTAssertThrowsError(
            try TranslationAPIKeyStore.keychainService(for: .custom, customEndpoint: nil)
        )
    }

    func testAuthenticatedRequestUsesTheValidatedEndpointSnapshot() throws {
        let endpoint = try EndpointValidator.validate("https://api.example.com:443/v1/custom/path")
        let request = LLMTranslationService.authenticatedRequest(
            endpoint: endpoint,
            apiKey: "test-only-key",
            timeout: 37
        )

        XCTAssertEqual(request.url, endpoint.url)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 37)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only-key")
    }

    func testCustomRedirectPolicyRejectsCrossOriginAndAllowsSameOrigin() throws {
        let source = try XCTUnwrap(URL(string: "https://api.example.com:443/v1/chat"))
        let sameOrigin = try XCTUnwrap(URL(string: "https://API.EXAMPLE.COM/v2/chat?cursor=1"))
        let otherHost = try XCTUnwrap(URL(string: "https://attacker.example.net/collect"))
        let otherPort = try XCTUnwrap(URL(string: "https://api.example.com:444/collect"))
        let userInfo = try XCTUnwrap(URL(string: "https://user:password@api.example.com/collect"))
        let idnaUnicode = try XCTUnwrap(URL(string: "https://bücher.example/collect"))
        let idnaPunycode = try XCTUnwrap(URL(string: "https://xn--bcher-kva.example/collect"))
        let idnaEscaped = try XCTUnwrap(URL(string: "https://b%C3%BCcher.example/collect"))

        XCTAssertTrue(CustomEndpointRedirectDelegate.shouldFollow(from: source, to: sameOrigin))
        XCTAssertFalse(CustomEndpointRedirectDelegate.shouldFollow(from: source, to: otherHost))
        XCTAssertFalse(CustomEndpointRedirectDelegate.shouldFollow(from: source, to: otherPort))
        XCTAssertFalse(CustomEndpointRedirectDelegate.shouldFollow(from: source, to: userInfo))
        XCTAssertTrue(CustomEndpointRedirectDelegate.shouldFollow(from: idnaUnicode, to: idnaPunycode))
        XCTAssertFalse(CustomEndpointRedirectDelegate.shouldFollow(from: idnaPunycode, to: idnaEscaped))
    }
}
