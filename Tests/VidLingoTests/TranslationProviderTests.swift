import XCTest
@testable import VidLingo

final class TranslationProviderTests: XCTestCase {
    func testQwenMTIsTranslationOnly() {
        let capabilities = TranslationProviderID.qwen.capabilities(for: "qwen-mt-flash")

        XCTAssertTrue(capabilities.isTranslationOnly)
        XCTAssertFalse(capabilities.supportsVision)
    }

    func testQwenVisionCapabilityDoesNotChangeSelectedModel() {
        let capabilities = TranslationProviderID.qwen.capabilities(for: "qwen-vl-plus")

        XCTAssertTrue(capabilities.supportsVision)
    }

    func testAnthropicClaudeVisionCapabilityIsExplicit() {
        XCTAssertTrue(TranslationProviderID.anthropic.capabilities(for: "claude-sonnet-4-5").supportsVision)
        XCTAssertFalse(TranslationProviderID.anthropic.capabilities(for: "text-only-model").supportsVision)
    }
}
