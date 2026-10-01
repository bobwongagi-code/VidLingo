import XCTest
@testable import VidLingo

final class TranslationProviderTests: XCTestCase {
    func testTranslationMenuOnlyIncludesRetainedProviders() {
        XCTAssertEqual(TranslationProviderID.allCases, [.rootify, .deepSeek, .custom])
    }

    func testAllTranslationKeysUseVidLingoServices() {
        for provider in TranslationProviderID.allCases {
            XCTAssertTrue(provider.keychainService.hasPrefix("VidLingo."))
        }
    }

    func testRootifyUsesCompanyGatewayAndLuna() {
        XCTAssertEqual(TranslationProviderID.rootify.defaultModel, "gpt-5.6-luna")
        XCTAssertEqual(
            TranslationProviderID.rootify.defaultBaseURL,
            "https://rootifyaiapi.rootifyglobal.com/v1/chat/completions"
        )
        XCTAssertEqual(TranslationProviderID.rootify.keychainService, "VidLingo.Rootify")
        XCTAssertTrue(TranslationProviderID.rootify.capabilities(for: "gpt-5.6-luna").supportsVision)
    }

    func testFunASRIsIndependentAndKeepsExistingCredentials() {
        XCTAssertEqual(FunASRConfiguration.keychainService, "VidLingo.QwenSoutheastAsia")
        XCTAssertNotEqual(FunASRConfiguration.keychainService, TranslationProviderID.rootify.keychainService)
        XCTAssertEqual(FunASRConfiguration.endpoint.absoluteString, "https://llm-ltudqs3p2y3jjvo5.ap-southeast-1.maas.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation")
        XCTAssertEqual(FunASRTranscriber.modelName, "fun-asr-flash-2026-06-15")
    }

    func testRemovedTranslationProvidersCannotBeRestored() {
        for id in ["qwen", "qwenSoutheastAsia", "openAI", "claudeCompatible", "anthropic"] {
            XCTAssertNil(TranslationProviderID(rawValue: id))
        }
    }
}
