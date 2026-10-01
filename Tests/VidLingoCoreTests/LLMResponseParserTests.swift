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

    func testRejectsLengthLimitedChatCompletion() {
        let data = Data(#"{"choices":[{"message":{"content":"部分译文"},"finish_reason":"length"}]}"#.utf8)

        XCTAssertThrowsError(try LLMResponseParser.outputText(from: data)) { error in
            XCTAssertEqual(error as? LLMResponseParserError, .incompleteOutput)
        }
    }

    func testRejectsContentFilteredChatCompletion() {
        let data = Data(#"{"choices":[{"message":{"content":"部分译文"},"finish_reason":"content_filter"}]}"#.utf8)

        XCTAssertThrowsError(try LLMResponseParser.outputText(from: data)) { error in
            XCTAssertEqual(error as? LLMResponseParserError, .incompleteOutput)
        }
    }

    func testRejectsToolCallChatCompletionDespitePartialText() {
        let data = Data(#"{"choices":[{"message":{"content":"部分译文","tool_calls":[{"id":"call_1","type":"function","function":{"name":"lookup","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#.utf8)

        XCTAssertThrowsError(try LLMResponseParser.outputText(from: data)) { error in
            XCTAssertEqual(error as? LLMResponseParserError, .incompleteOutput)
        }
    }

    func testRejectsLegacyFunctionCallChatCompletionDespitePartialText() {
        let data = Data(#"{"choices":[{"message":{"content":"部分译文","function_call":{"name":"lookup","arguments":"{}"}},"finish_reason":"function_call"}]}"#.utf8)

        XCTAssertThrowsError(try LLMResponseParser.outputText(from: data)) { error in
            XCTAssertEqual(error as? LLMResponseParserError, .incompleteOutput)
        }
    }

    func testRejectsIncompleteResponsesPayloadDespitePartialText() {
        let data = Data(#"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output_text":"部分译文"}"#.utf8)

        XCTAssertThrowsError(try LLMResponseParser.outputText(from: data)) { error in
            XCTAssertEqual(error as? LLMResponseParserError, .incompleteOutput)
        }
    }

    func testAcceptsCompletedResponsesPayload() throws {
        let data = Data(#"{"status":"completed","output_text":"完整译文"}"#.utf8)

        XCTAssertEqual(try LLMResponseParser.outputText(from: data), "完整译文")
    }

    func testAcceptsCompletedChatCompletion() throws {
        let data = Data(#"{"choices":[{"message":{"content":"完整译文"},"finish_reason":"stop"}]}"#.utf8)

        XCTAssertEqual(try LLMResponseParser.outputText(from: data), "完整译文")
    }
}
