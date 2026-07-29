import XCTest
@testable import VidLingoCore

final class EndpointValidatorTests: XCTestCase {
    func testHTTPSEndpointReturnsOrigin() throws {
        let endpoint = try EndpointValidator.validate("https://api.example.com/v1/chat/completions")

        XCTAssertEqual(endpoint.origin, "https://api.example.com")
        XCTAssertEqual(endpoint.url.absoluteString, "https://api.example.com/v1/chat/completions")
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
