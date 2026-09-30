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

}
