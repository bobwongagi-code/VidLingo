import Foundation
import XCTest
@testable import VidLingo

final class LLMProviderAdapterTests: XCTestCase {
    func testChatVisionRequestCarriesSystemPromptAndFrames() throws {
        let data = try ChatCompletionsProviderAdapter.visionRequestData(
            model: "gpt-4o-mini",
            system: "只根据画面回答",
            userText: "输出 JSON",
            frameJPEGData: [Data([0x01, 0x02]), Data([0x03])],
            maxFrameCount: 1
        )
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(payload["model"] as? String, "gpt-4o-mini")

        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")

        let content = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[1]["type"] as? String, "image_url")
    }

    func testInvalidVisualResponseCanUseNoSpeechFallback() {
        XCTAssertTrue(LLMTranslationError.visualResponseInvalid.allowsVisionFallback)
    }
}
