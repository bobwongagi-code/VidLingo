import Foundation
import XCTest
@testable import VidLingo

final class FunASRTranscriberTests: XCTestCase {
    func testParsesNestedFunASRResponse() throws {
        let data = Data(#"{"output":{"output":{"sentence":{"text":"泰语口播"}},"text":"备用文本"}}"#.utf8)

        XCTAssertEqual(try FunASRTranscriber.recognizedText(from: data), "泰语口播")
    }

    func testParsesTopLevelFunASRText() throws {
        let data = Data(#"{"text":"顶层口播文本","sentence":{"text":"当前句子"}}"#.utf8)

        XCTAssertEqual(try FunASRTranscriber.recognizedText(from: data), "当前句子")
    }

    func testBuildsAudioRequestWithProductContext() throws {
        let data = try FunASRTranscriber.requestData(
            audioData: Data([0x01, 0x02]),
            productContext: "家居清洁设备",
            languageHint: "th"
        )
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(payload["model"] as? String, FunASRTranscriber.modelName)

        let input = try XCTUnwrap(payload["input"] as? [String: Any])
        let messages = try XCTUnwrap(input["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[1]["role"] as? String, "user")

        let contextContent = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(contextContent[0]["type"] as? String, "input_text")
        XCTAssertTrue((contextContent[0]["text"] as? String)?.contains("家居清洁设备") == true)

        let audioContent = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(audioContent[0]["type"] as? String, "input_audio")
        let audio = try XCTUnwrap(audioContent[0]["input_audio"] as? [String: Any])
        XCTAssertEqual(audio["data"] as? String, "data:audio/wav;base64,AQI=")

        let parameters = try XCTUnwrap(payload["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["format"] as? String, "wav")
        XCTAssertEqual(parameters["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(parameters["language_hints"] as? [String], ["th"])
    }
}
