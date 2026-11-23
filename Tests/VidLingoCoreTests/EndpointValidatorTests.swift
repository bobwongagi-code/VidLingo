import XCTest
@testable import VidLingoCore

final class EndpointValidatorTests: XCTestCase {
    func testHTTPSEndpointReturnsOrigin() throws {
        let endpoint = try EndpointValidator.validate("https://api.example.com/v1/chat/completions")

        XCTAssertEqual(endpoint.origin, "https://api.example.com")
        XCTAssertEqual(endpoint.url.absoluteString, "https://api.example.com/v1/chat/completions")
    }

    func testOriginCanonicalizesHostCaseAndDefaultPort() throws {
        let implicitDefault = try EndpointValidator.validate("https://API.EXAMPLE.COM/v1/one")
        let explicitDefault = try EndpointValidator.validate("HTTPS://api.example.com:443/v1/two")

        XCTAssertEqual(implicitDefault.origin, "https://api.example.com")
        XCTAssertEqual(explicitDefault.origin, implicitDefault.origin)
        XCTAssertNotEqual(implicitDefault.url.path, explicitDefault.url.path)
    }

    func testOriginPreservesNonDefaultPortAndScheme() throws {
        let standard = try EndpointValidator.validate("https://api.example.com/v1/chat")
        let nonDefaultPort = try EndpointValidator.validate("https://api.example.com:444/v1/chat")
        let loopbackHTTP = try EndpointValidator.validate("http://127.0.0.1/v1/chat", allowLoopbackHTTP: true)
        let explicitHTTPPort = try EndpointValidator.validate("http://127.0.0.1:80/other", allowLoopbackHTTP: true)

        XCTAssertEqual(nonDefaultPort.origin, "https://api.example.com:444")
        XCTAssertNotEqual(nonDefaultPort.origin, standard.origin)
        XCTAssertEqual(loopbackHTTP.origin, explicitHTTPPort.origin)
    }

    func testOriginCanonicalizesIDNAAliasWithoutMergingEscapedAuthority() throws {
        let unicodeHost = try EndpointValidator.validate("https://bücher.example/v1/chat")
        let punycodeHost = try EndpointValidator.validate("https://xn--bcher-kva.example/v1/chat")
        let escapedHost = try EndpointValidator.validate("https://b%C3%BCcher.example/v1/chat")

        XCTAssertEqual(unicodeHost.origin, "https://xn--bcher-kva.example")
        XCTAssertEqual(punycodeHost.origin, unicodeHost.origin)
        XCTAssertNotEqual(escapedHost.origin, punycodeHost.origin)
    }

    func testSameOriginIgnoresPathButRejectsSchemeHostAndPortChanges() throws {
        let source = try XCTUnwrap(URL(string: "https://API.EXAMPLE.COM:443/v1/chat"))
        let sameOrigin = try XCTUnwrap(URL(string: "https://api.example.com:443/v1/redirected?token=not-a-credential"))
        let otherHost = try XCTUnwrap(URL(string: "https://other.example.com/v1/chat"))
        let otherScheme = try XCTUnwrap(URL(string: "http://api.example.com/v1/chat"))
        let otherPort = try XCTUnwrap(URL(string: "https://api.example.com:444/v1/chat"))

        XCTAssertTrue(EndpointValidator.sameOrigin(source, sameOrigin))
        XCTAssertFalse(EndpointValidator.sameOrigin(source, otherHost))
        XCTAssertFalse(EndpointValidator.sameOrigin(source, otherScheme))
        XCTAssertFalse(EndpointValidator.sameOrigin(source, otherPort))
    }

    func testHTTPIsRejectedByDefault() {
        XCTAssertThrowsError(try EndpointValidator.validate("http://api.example.com/chat")) { error in
            XCTAssertEqual(error as? EndpointValidationError, .localHTTPNotAllowed)
        }
    }

    func testLoopbackHTTPRequiresExplicitOptIn() throws {
        XCTAssertThrowsError(try EndpointValidator.validate("http://127.0.0.1:8080/v1/chat"))

        let endpoint = try EndpointValidator.validate(
            "http://127.0.0.1:8080/v1/chat",
            allowLoopbackHTTP: true
        )
        XCTAssertEqual(endpoint.origin, "http://127.0.0.1:8080")
    }

    func testEndpointCredentialsAreRejected() {
        XCTAssertThrowsError(try EndpointValidator.validate("https://user:password@example.com/v1/chat")) { error in
            XCTAssertEqual(error as? EndpointValidationError, .credentialsNotAllowed)
        }
    }

    func testEndpointQueryAndFragmentAreRejected() {
        XCTAssertThrowsError(try EndpointValidator.validate("https://api.example.com/v1/chat?api_key=secret")) { error in
            XCTAssertEqual(error as? EndpointValidationError, .queryOrFragmentNotAllowed)
        }
        XCTAssertThrowsError(try EndpointValidator.validate("https://api.example.com/v1/chat#fragment")) { error in
            XCTAssertEqual(error as? EndpointValidationError, .queryOrFragmentNotAllowed)
        }
    }
}
