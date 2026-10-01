import XCTest
@testable import VidLingo

final class LanguageTextDetectorTests: XCTestCase {
    func testDetectsThaiFromFunASRText() {
        let text = "จักรยานเสือภูเขาตัวนี้เลย เด็กปั่นได้ ผู้ใหญ่ปั่นดีนะ มีให้เลือกหลายไซส์"

        XCTAssertEqual(LanguageTextDetector.detect(text)?.id, "th-TH")
    }

    func testDistinguishesMalayFromIndonesian() {
        let text = "Pakai yang ni je nak cuci sofa boleh, nak cuci karpet ke tilam. Harga dia pun murah."

        XCTAssertEqual(LanguageTextDetector.detect(text)?.id, "ms-MY")
    }

    func testIgnoresSpanishMarkersInsideOtherWords() {
        let text = "kelapa delima contact tuna porridge"

        XCTAssertNil(LanguageTextDetector.detect(text))
    }

    func testDetectsMalayDespiteEmbeddedForeignMarkers() {
        let text = "Nak beli kelapa delima contact tuna porridge boleh."

        XCTAssertEqual(LanguageTextDetector.detect(text)?.id, "ms-MY")
    }

    func testDetectsWholeSpanishMarkersWithCaseAndPunctuation() {
        let text = "QUE, EL; LA! DE? PARA\nCON UNA POR."

        XCTAssertEqual(LanguageTextDetector.detect(text)?.id, "es-ES")
    }

    func testDetectsIndonesianFromWholeWords() {
        let text = "Ini bisa untuk sofa dengan harga murah."

        XCTAssertEqual(LanguageTextDetector.detect(text)?.id, "id-ID")
    }

    func testDetectsEnglishFromWholeWords() {
        let text = "This is for you and the family."

        XCTAssertEqual(LanguageTextDetector.detect(text)?.id, "en-US")
    }

    func testDetectsShortPureHanTextAsChinese() {
        XCTAssertEqual(LanguageTextDetector.detect("好用")?.id, "zh-CN")
    }

    func testDetectsJapaneseWhenKanaDisambiguatesHanCharacters() {
        XCTAssertEqual(LanguageTextDetector.detect("日本語を話す")?.id, "ja-JP")
    }

    func testDetectsChineseWithLatinProductName() {
        XCTAssertEqual(LanguageTextDetector.detect("这个USB背包很实用")?.id, "zh-CN")
    }
}
