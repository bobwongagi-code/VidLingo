import XCTest
@testable import VidLingo

final class SpeechTranscriptValidatorTests: XCTestCase {
    func testAcceptsShortEnglishAndMalayUtterances() throws {
        let malay = try XCTUnwrap(LanguageOption.supported.first { $0.id == "ms-MY" })

        XCTAssertTrue(SpeechTranscriptValidator.hasEffectiveSpeechTranscript("So cute!", language: .english))
        XCTAssertTrue(SpeechTranscriptValidator.hasEffectiveSpeechTranscript("Cantik sangat!", language: malay))
    }

    func testAcceptsShortChineseUtterance() throws {
        let chinese = try XCTUnwrap(LanguageOption.supported.first { $0.id == "zh-CN" })

        XCTAssertTrue(SpeechTranscriptValidator.hasEffectiveSpeechTranscript("好用", language: chinese))
    }

    func testRejectsTextWithoutSpeechCharacters() {
        XCTAssertFalse(SpeechTranscriptValidator.hasEffectiveSpeechTranscript("!!!", language: .english))
    }

    func testAcceptsShortSpokenNumber() {
        XCTAssertTrue(SpeechTranscriptValidator.hasEffectiveSpeechTranscript("19.90", language: .english))
    }

    func testUndeterminedRejectsUnspacedCyrillicRepetitionLoop() {
        XCTAssertFalse(SpeechTranscriptValidator.hasEffectiveSpeechTranscript(
            "дададададададададададада",
            language: .undetermined
        ))
        XCTAssertFalse(SpeechTranscriptValidator.hasEffectiveSpeechTranscript(
            " \nдададададададададададада \n",
            language: .undetermined
        ))
    }

    func testUndeterminedAcceptsShortCyrillicUtterance() {
        XCTAssertTrue(SpeechTranscriptValidator.hasEffectiveSpeechTranscript("Привет", language: .undetermined))
    }

    func testUndeterminedKeepsShortLatinUtterance() {
        XCTAssertTrue(SpeechTranscriptValidator.hasEffectiveSpeechTranscript("So cute!", language: .undetermined))
    }

    func testStillRejectsKnownHallucinationsAndRepetitionLoops() {
        XCTAssertFalse(SpeechTranscriptValidator.hasEffectiveSpeechTranscript("*trips*", language: .english))
        XCTAssertFalse(SpeechTranscriptValidator.hasEffectiveSpeechTranscript(
            "yeah yeah yeah yeah yeah yeah",
            language: .english
        ))
    }
}
