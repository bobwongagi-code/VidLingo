import XCTest
@testable import VidLingoCore

final class WhisperModelValidatorTests: XCTestCase {
    func testAcceptsStructurallyValidWhisperHeader() {
        XCTAssertTrue(WhisperModelValidator.hasValidGGMLHeader(makeHeader()))
    }

    func testRejectsWrongMagic() {
        var header = makeHeader()
        header.replaceSubrange(0..<4, with: Data("test".utf8))

        XCTAssertFalse(WhisperModelValidator.hasValidGGMLHeader(header))
    }

    func testRejectsImpossibleArchitecture() {
        var header = makeHeader(values: [51866, 1500, 32, 20, 32, 448, 1280, 20, 32, 128])

        XCTAssertFalse(WhisperModelValidator.hasValidGGMLHeader(header))
    }

    private func makeHeader(values: [UInt32] = [51866, 1500, 1280, 20, 32, 448, 1280, 20, 32, 128]) -> Data {
        var data = Data([0x6c, 0x6d, 0x67, 0x67])
        for value in values {
            var littleEndian = value.littleEndian
            data.append(Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size))
        }
        return data
    }
}
