import XCTest
@testable import VidLingo
@testable import VidLingoCore

final class LLMTranslationServiceTests: XCTestCase {
    func testStructuredPromptRemovesPlainTextOutputContract() {
        let prompt = """
        # 一、翻译原则
        保留原文事实。

        # 五、输出格式（硬性规则，违反即视为失败）
        你的回复**只能**包含中文译文正文本身。
        严禁输出标签。

        # 六、特别提醒
        下单引导句必须译准。
        """

        let structuredPrompt = LLMTranslationService.structuredTranslationSystemPrompt(from: prompt)

        XCTAssertTrue(structuredPrompt.contains("保留原文事实"))
        XCTAssertTrue(structuredPrompt.contains("下单引导句必须译准"))
        XCTAssertFalse(structuredPrompt.contains("# 五、输出格式"))
        XCTAssertFalse(structuredPrompt.contains("只能**包含中文译文正文本身"))
    }

    func testTimedTranslationSupportsCustomAndQwenMTModels() {
        XCTAssertTrue(LLMTranslationService.supportsTimedTranslation(
            provider: .custom,
            modelName: "custom-model"
        ))
        XCTAssertTrue(LLMTranslationService.supportsTimedTranslation(
            provider: .qwen,
            modelName: "qwen-mt-flash"
        ))
        XCTAssertFalse(LLMTranslationService.supportsTimedTranslation(
            provider: .qwen,
            modelName: "   "
        ))
    }

    func testParsesStructuredTimedTranslationsWithSurroundingText() throws {
        let output = """
        下面是结果：
        {"segments":[{"id":1,"translation":"第一句译文"},{"id":2,"translation":"第二句译文"}]}
        """

        let translations = try LLMTranslationService.parseTimedTranslations(from: output)

        XCTAssertEqual(translations, [
            TimedTranslationItem(id: 1, translation: "第一句译文"),
            TimedTranslationItem(id: 2, translation: "第二句译文")
        ])
    }

    func testParsesQwenMTTaggedTranslationsAndRejectsMissingSegments() {
        let segments = [
            TimedTranscriptSegment(id: 1, startMilliseconds: 0, endMilliseconds: 1_000, sourceText: "第一句"),
            TimedTranscriptSegment(id: 2, startMilliseconds: 1_100, endMilliseconds: 2_000, sourceText: "第二句")
        ]
        let input = LLMTranslationService.qwenMTTimedInput(segments)

        XCTAssertTrue(input.contains("<<<VIDLINGO_SEGMENT_1>>>\n第一句"))
        XCTAssertTrue(input.contains("<<<VIDLINGO_SEGMENT_2>>>\n第二句"))

        let output = """
        <<<VIDLINGO_SEGMENT_1>>>
        第一段译文

        <<<VIDLINGO_SEGMENT_2>>>
        第二段译文
        """
        XCTAssertEqual(
            LLMTranslationService.parseQwenMTTimedTranslations(from: output, expectedIDs: [1, 2]),
            [
                TimedTranslationItem(id: 1, translation: "第一段译文"),
                TimedTranslationItem(id: 2, translation: "第二段译文")
            ]
        )
        XCTAssertNil(LLMTranslationService.parseQwenMTTimedTranslations(
            from: "<<<VIDLNGO_SEGMENT_1>>>\n只有一段",
            expectedIDs: [1, 2]
        ))
    }
}
