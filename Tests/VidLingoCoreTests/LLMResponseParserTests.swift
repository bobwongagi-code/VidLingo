import XCTest
@testable import VidLingoCore

final class LLMResponseParserTests: XCTestCase {
    func testParsesChatCompletionStringContent() throws {
        let data = Data(#"{"choices":[{"message":{"content":"译文"}}]}"#.utf8)

        XCTAssertEqual(try LLMResponseParser.outputText(from: data), "译文")
    }

    func testParsesContentBlocks() throws {
        let data = Data(#"{"choices":[{"message":{"content":[{"type":"text","text":"第一句"},{"type":"text","text":"第二句"}]}}]}"#.utf8)

        XCTAssertEqual(try LLMResponseParser.outputText(from: data), "第一句第二句")
    }

    func testParsesResponsesOutputText() throws {
        let data = Data(#"{"output_text":"Responses 译文"}"#.utf8)

        XCTAssertEqual(try LLMResponseParser.outputText(from: data), "Responses 译文")
    }

    func testParsesLegacyTextChoice() throws {
        let data = Data(#"{"choices":[{"text":"Text completion 译文"}]}"#.utf8)

        XCTAssertEqual(try LLMResponseParser.outputText(from: data), "Text completion 译文")
    }

    func testRejectsEmptyOutput() {
        let data = Data(#"{"choices":[{"message":{"content":[]}}]}"#.utf8)

        XCTAssertThrowsError(try LLMResponseParser.outputText(from: data)) { error in
            XCTAssertEqual(error as? LLMResponseParserError, .emptyOutput)
        }
    }
}
