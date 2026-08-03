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
}
