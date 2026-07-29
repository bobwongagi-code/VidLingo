import XCTest
@testable import VidLingoCore

final class FilePairTransactionTests: XCTestCase {
    private var directoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VidLingoPairTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directoryURL)
        try super.tearDownWithError()
    }

    func testRetireRemovesBothFilesTogether() throws {
        let sourceURL = directoryURL.appendingPathComponent("sample_original.txt")
        let translationURL = directoryURL.appendingPathComponent("sample_translation.txt")
        try "原文".write(to: sourceURL, atomically: true, encoding: .utf8)
        try "译文".write(to: translationURL, atomically: true, encoding: .utf8)

        try FilePairTransaction.retire(sourceURL: sourceURL, translationURL: translationURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: translationURL.path))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil).count,
            0
        )
    }

    func testRetireRejectsFilesFromDifferentDirectories() throws {
        let sourceURL = directoryURL.appendingPathComponent("original.txt")
        let otherDirectoryURL = directoryURL.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherDirectoryURL, withIntermediateDirectories: true)
        let translationURL = otherDirectoryURL.appendingPathComponent("translation.txt")

        XCTAssertThrowsError(try FilePairTransaction.retire(sourceURL: sourceURL, translationURL: translationURL)) { error in
            XCTAssertEqual(error as? FilePairTransactionError, .filesMustShareDirectory)
        }
    }
}
