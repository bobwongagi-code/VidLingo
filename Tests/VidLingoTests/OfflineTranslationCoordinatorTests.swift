import XCTest
@testable import VidLingo

final class OfflineTranslationCoordinatorTests: XCTestCase {
    func testRunRejectsCloudAudioWithoutExplicitConsent() async throws {
        let request = OfflineTranslationRunRequest(
            videoURL: URL(fileURLWithPath: "/tmp/not-used.mp4"),
            fallbackSource: .english,
            target: LanguageOption(id: "zh-CN", title: "Chinese Simplified", locale: Locale(identifier: "zh-CN")),
            initialProductContext: "",
            provider: .qwen,
            modelName: "qwen3.6-plus",
            customBaseURL: "",
            shouldAutoDetectLanguage: true,
            shouldInferProductContext: true,
            allowsCloudAudioTranscription: false,
            allowsCloudVideoFrames: false,
            allowsVisualSalesCopy: false
        )
        let token = ProcessCancellationToken(timeout: 30)

        do {
            _ = try await OfflineTranslationCoordinator().run(
                request: request,
                token: token,
                reportProgress: { _ in }
            )
            XCTFail("Expected explicit cloud audio consent to be required")
        } catch let error as OfflineVideoTranslationError {
            XCTAssertEqual(error.errorDescription, AppText.cloudAudioConsentRequired)
        }
    }
}
