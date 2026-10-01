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

    func testTimedTranslationSupportsCustomAndRootifyModels() {
        XCTAssertTrue(LLMTranslationService.supportsTimedTranslation(
            provider: .custom,
            modelName: "custom-model"
        ))
        XCTAssertTrue(LLMTranslationService.supportsTimedTranslation(
            provider: .rootify,
            modelName: "gpt-5.6-luna"
        ))
        XCTAssertFalse(LLMTranslationService.supportsTimedTranslation(
            provider: .rootify,
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

    func testAlignsTimedTranslationsByIDAndPreservesSourceOrder() throws {
        let segments = makeTimedSegments()
        let output = #"{"segments":[{"id":2,"translation":"第二句"},{"id":1,"translation":"第一句"}]}"#

        let translation = try LLMTranslationService.alignTimedTranslations(from: output, to: segments)

        XCTAssertEqual(translation.text, "第一句\n第二句")
        XCTAssertEqual(translation.segments.map(\.translatedText), ["第一句", "第二句"])
        XCTAssertEqual(translation.segments.map(\.startMilliseconds), [0, 1_000])
    }

    func testRejectsMalformedTimedTranslationJSON() {
        assertInvalidTimedTranslation(#"{"segments":"#)
    }

    func testRejectsMissingTimedTranslationSegment() {
        assertInvalidTimedTranslation(#"{"segments":[{"id":1,"translation":"第一句"}]}"#)
    }

    func testRejectsUnexpectedTimedTranslationID() {
        assertInvalidTimedTranslation(#"{"segments":[{"id":1,"translation":"第一句"},{"id":2,"translation":"第二句"},{"id":3,"translation":"额外句"}]}"#)
    }

    func testRejectsDuplicateTimedTranslationID() {
        assertInvalidTimedTranslation(#"{"segments":[{"id":1,"translation":"第一句"},{"id":1,"translation":"重复"}]}"#)
    }

    func testRejectsEmptyTimedTranslation() {
        assertInvalidTimedTranslation(#"{"segments":[{"id":1,"translation":" "},{"id":2,"translation":"第二句"}]}"#)
    }

    private func assertInvalidTimedTranslation(
        _ output: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try LLMTranslationService.alignTimedTranslations(from: output, to: makeTimedSegments()),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "模型返回的分段译文不完整或格式无效，请重试。",
                file: file,
                line: line
            )
        }
    }

    private func makeTimedSegments() -> [TimedTranscriptSegment] {
        [
            TimedTranscriptSegment(id: 1, startMilliseconds: 0, endMilliseconds: 1_000, sourceText: "First"),
            TimedTranscriptSegment(id: 2, startMilliseconds: 1_000, endMilliseconds: 2_000, sourceText: "Second")
        ]
    }

}
