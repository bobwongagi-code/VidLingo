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

    func testParsesStreamingTextAndFinalSentenceTimestamps() throws {
        let lines = [
            "event:result",
            #"data:{"output":{"text":"第一句","sentence":{"sentence_id":1,"sentence_end":true,"begin_time":760,"end_time":3800,"text":"第一句"}}}"#,
            #"data:{"output":{"text":"第一句第二句","sentence":{"sentence_id":2,"sentence_end":true,"begin_time":4200,"end_time":6950,"text":"第二句"}}}"#,
            "data:[DONE]"
        ]

        let result = try FunASRTranscriber.transcription(fromSSELines: lines)

        XCTAssertEqual(result.text, "第一句第二句")
        XCTAssertEqual(result.segments.map(\.id), [1, 2])
        XCTAssertEqual(result.segments[0].startMilliseconds, 760)
        XCTAssertEqual(result.segments[0].endMilliseconds, 3_800)
        XCTAssertEqual(result.segments[1].startMilliseconds, 4_200)
        XCTAssertEqual(result.segments[1].endMilliseconds, 6_950)
        XCTAssertFalse(result.hasWordTimestamps)
    }

    func testIgnoresIntermediateSentenceWithoutFinalTimestamp() throws {
        let lines = [
            #"data:{"output":{"text":"正在说到一半","sentence":{"sentence_id":1,"sentence_end":false,"text":"正在说到一半"}}}"#,
            #"data:{"output":{"text":"完整一句"}}"#
        ]

        let result = try FunASRTranscriber.transcription(fromSSELines: lines)

        XCTAssertEqual(result.text, "完整一句")
        XCTAssertTrue(result.segments.isEmpty)
    }

    func testParsesWordTimestampsIntoMultipleSegments() throws {
        let lines = [
            #"data:{"output":{"text":"第一句 第二句 第三句 第四句","sentence":{"sentence_id":1,"sentence_end":true,"begin_time":0,"end_time":9000,"text":"第一句 第二句 第三句 第四句","words":[{"begin_time":0,"end_time":1800,"text":"第一句","punctuation":"。"},{"begin_time":2200,"end_time":3900,"text":"第二句","punctuation":"。"},{"begin_time":4500,"end_time":6200,"text":"第三句","punctuation":""},{"begin_time":7000,"end_time":9000,"text":"第四句","punctuation":"。"}]}}}"#
        ]

        let result = try FunASRTranscriber.transcription(fromSSELines: lines)

        XCTAssertGreaterThan(result.segments.count, 1)
        XCTAssertTrue(result.hasWordTimestamps)
        XCTAssertEqual(result.segments.map(\.sourceText).joined(), "第一句。第二句。第三句。第四句。")
        XCTAssertEqual(result.segments.first?.startMilliseconds, 0)
        XCTAssertEqual(result.segments.last?.endMilliseconds, 9_000)
        XCTAssertTrue(zip(result.segments, result.segments.dropFirst()).allSatisfy {
            $0.endMilliseconds <= $1.startMilliseconds
        })
    }
}
