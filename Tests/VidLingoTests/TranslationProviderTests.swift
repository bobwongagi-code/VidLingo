import XCTest
@testable import VidLingo

final class TranslationProviderTests: XCTestCase {
    func testQwenUsesWorkspaceCompatibleEndpoint() {
        XCTAssertEqual(
            TranslationProviderID.qwen.defaultBaseURL,
            "https://llm-nlx73tfv3mm6w67e.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions"
        )
    }

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
