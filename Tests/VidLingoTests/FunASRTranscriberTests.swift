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
        XCTAssertEqual(audio["data"] as? String, "data:audio/mp3;base64,AQI=")

        let parameters = try XCTUnwrap(payload["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["format"] as? String, "mp3")
        XCTAssertEqual(parameters["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(parameters["language_hints"] as? [String], ["th"])
    }

    func testMaximumAudioSizeStaysWithinBase64RequestLimit() throws {
        let audioData = Data(repeating: 0x01, count: Int(FunASRTranscriber.maxAudioBytes))
        let requestData = try FunASRTranscriber.requestData(
            audioData: audioData,
            productContext: ""
        )
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        let input = try XCTUnwrap(payload["input"] as? [String: Any])
        let messages = try XCTUnwrap(input["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        let audio = try XCTUnwrap(content[0]["input_audio"] as? [String: Any])
        let dataURI = try XCTUnwrap(audio["data"] as? String)

        XCTAssertLessThan(dataURI.utf8.count, 10_000_000)
        XCTAssertLessThan(requestData.count, 10_000_000)
    }

    func testRejectsAudioAboveBase64SafeLimit() {
        let audioData = Data(repeating: 0x01, count: Int(FunASRTranscriber.maxAudioBytes) + 1)

        XCTAssertThrowsError(try FunASRTranscriber.requestData(
            audioData: audioData,
            productContext: ""
        ))
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

    func testPartialSentenceTimelineDoesNotReplaceTheFullTranscript() throws {
        let lines = [
            #"data:{"output":{"text":"The bag is light. Click the link below.","sentence":{"sentence_id":2,"sentence_end":true,"begin_time":2400,"end_time":3900,"text":"Click the link below."}}}"#
        ]

        let result = try FunASRTranscriber.transcription(fromSSELines: lines)

        XCTAssertEqual(result.text, "The bag is light. Click the link below.")
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertFalse(result.hasWordTimestamps)
    }

    func testPartialWordTimelineDoesNotReplaceTheFullTranscript() throws {
        let lines = [
            #"data:{"output":{"text":"The bag is light. Click the link below.","output":{"sentence":{"sentence_id":2,"sentence_end":true,"begin_time":2400,"end_time":3900,"text":"Click the link below.","words":[{"begin_time":2400,"end_time":3900,"text":"Click the link below"}]}}}}"#
        ]

        let result = try FunASRTranscriber.transcription(fromSSELines: lines)

        XCTAssertEqual(result.text, "The bag is light. Click the link below.")
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertFalse(result.hasWordTimestamps)
    }

    func testNestedSentenceFallbackKeepsItsCompleteTimeline() throws {
        let lines = [
            #"data:{"output":{"output":{"sentence":{"sentence_id":1,"sentence_end":true,"begin_time":0,"end_time":1800,"text":"完整的嵌套转写。"}}}}"#
        ]

        let result = try FunASRTranscriber.transcription(fromSSELines: lines)

        XCTAssertEqual(result.text, "完整的嵌套转写。")
        XCTAssertEqual(result.segments.map(\.sourceText), ["完整的嵌套转写。"])
        XCTAssertFalse(result.hasWordTimestamps)
    }

    func testSentenceFallbackKeepsEarlierUntimedFinalSentences() throws {
        let lines = [
            #"data:{"output":{"sentence":{"sentence_id":1,"sentence_end":true,"text":"I like this bag."}}}"#,
            #"data:{"output":{"sentence":{"sentence_id":2,"sentence_end":true,"begin_time":2400,"end_time":3900,"text":"It feels light."}}}"#
        ]

        let result = try FunASRTranscriber.transcription(fromSSELines: lines)

        XCTAssertEqual(result.text, "I like this bag. It feels light.")
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertFalse(result.hasWordTimestamps)
    }

    func testInvalidTimestampAndExtremeSentenceIDStillKeepFullText() throws {
        let lines = [
            #"data:{"output":{"text":"Two words.","sentence":{"sentence_id":9223372036854775807,"sentence_end":true,"begin_time":9223372036854775800,"end_time":9223372036854775807,"text":"Two words.","words":[{"begin_time":9223372036854775800,"end_time":9223372036854775802,"text":"Two"},{"begin_time":9223372036854775803,"end_time":9223372036854775807,"text":" words."}]}}}"#
        ]
        let result = try FunASRTranscriber.transcription(fromSSELines: lines)
        XCTAssertEqual(result.text, "Two words.")
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertFalse(result.hasWordTimestamps)
    }

    func testSentenceTimelineMustPreserveLatinWordBoundaries() throws {
        let lines = [
            #"data:{"output":{"text":"The product is now here.","sentence":{"sentence_id":1,"sentence_end":true,"begin_time":0,"end_time":1800,"text":"The product is nowhere."}}}"#
        ]

        let result = try FunASRTranscriber.transcription(fromSSELines: lines)

        XCTAssertEqual(result.text, "The product is now here.")
        XCTAssertTrue(result.segments.isEmpty)
    }

    func testSentenceTimelineMustPreserveKoreanWordBoundaries() throws {
        let lines = [
            #"data:{"output":{"text":"아버지가 방에 들어가신다.","sentence":{"sentence_id":1,"sentence_end":true,"begin_time":0,"end_time":1800,"text":"아버지 가방에 들어가신다."}}}"#
        ]
        let result = try FunASRTranscriber.transcription(fromSSELines: lines)
        XCTAssertEqual(result.text, "아버지가 방에 들어가신다.")
        XCTAssertTrue(result.segments.isEmpty)
    }

    func testSentenceTimelineMustPreserveCurrencyAndSign() throws {
        for (total, timed, shouldKeep) in [("$5", "€5", false), ("-$5", "$5", false), ("$ 5", "$5", true)] {
            let line = #"data:{"output":{"text":"Price is \#(total).","sentence":{"sentence_id":1,"sentence_end":true,"begin_time":0,"end_time":1800,"text":"Price is \#(timed)."}}}"#
            let result = try FunASRTranscriber.transcription(fromSSELines: [line])
            XCTAssertEqual(result.text, "Price is \(total).")
            XCTAssertEqual(!result.segments.isEmpty, shouldKeep, "\(total) versus \(timed)")
        }
    }

    func testNumericPunctuationMustMatchBeforeKeepingSentenceTimeline() throws {
        let exactLines = [
            #"data:{"output":{"text":"Price is RM 1.99.","sentence":{"sentence_id":1,"sentence_end":true,"begin_time":0,"end_time":1800,"text":"Price is RM 1.99."}}}"#
        ]
        let changedPriceLines = [
            #"data:{"output":{"text":"Price is RM 1.99.","sentence":{"sentence_id":1,"sentence_end":true,"begin_time":0,"end_time":1800,"text":"Price is RM 199."}}}"#
        ]
        let changedSignLines = [
            #"data:{"output":{"text":"The temperature is -5 degrees.","sentence":{"sentence_id":1,"sentence_end":true,"begin_time":0,"end_time":1800,"text":"The temperature is 5 degrees."}}}"#
        ]

        let exact = try FunASRTranscriber.transcription(fromSSELines: exactLines)
        let changedPrice = try FunASRTranscriber.transcription(fromSSELines: changedPriceLines)
        let changedSign = try FunASRTranscriber.transcription(fromSSELines: changedSignLines)

        XCTAssertEqual(exact.segments.map(\.sourceText), ["Price is RM 1.99."])
        XCTAssertTrue(changedPrice.segments.isEmpty)
        XCTAssertTrue(changedSign.segments.isEmpty)
    }

    func testSentenceTimelineAllowsUnspacedScriptSegmentationDifferences() throws {
        let lines = [
            #"data:{"output":{"text":"这个背包很好用。","sentence":{"sentence_id":1,"sentence_end":true,"begin_time":0,"end_time":1800,"text":"这 个 背 包 很 好 用 。"}}}"#
        ]

        let result = try FunASRTranscriber.transcription(fromSSELines: lines)

        XCTAssertEqual(result.text, "这个背包很好用。")
        XCTAssertEqual(result.segments.map(\.sourceText), ["这 个 背 包 很 好 用 。"])
    }

    func testParsesWordTimestampsIntoMultipleSegments() throws {
        let lines = [
            #"data:{"output":{"text":"第一句 第二句 第三句 第四句","sentence":{"sentence_id":1,"sentence_end":true,"begin_time":0,"end_time":9000,"text":"第一句 第二句 第三句 第四句","words":[{"begin_time":0,"end_time":1800,"text":"第一句","punctuation":"。"},{"begin_time":2200,"end_time":3900,"text":"第二句","punctuation":"。"},{"begin_time":4500,"end_time":6200,"text":"第三句","punctuation":""},{"begin_time":7000,"end_time":9000,"text":"第四句","punctuation":"。"}]}}}"#
        ]

        let result = try FunASRTranscriber.transcription(fromSSELines: lines)

        XCTAssertEqual(result.text, "第一句 第二句 第三句 第四句")
        XCTAssertGreaterThan(result.segments.count, 1)
        XCTAssertTrue(result.hasWordTimestamps)
        XCTAssertEqual(result.segments.map(\.sourceText).joined(), "第一句。第二句。第三句第四句。")
        XCTAssertEqual(result.segments.first?.startMilliseconds, 0)
        XCTAssertEqual(result.segments.last?.endMilliseconds, 9_000)
        XCTAssertTrue(zip(result.segments, result.segments.dropFirst()).allSatisfy {
            $0.endMilliseconds <= $1.startMilliseconds
        })
    }
}
