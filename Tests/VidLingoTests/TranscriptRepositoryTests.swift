import XCTest
@testable import VidLingo

final class TranscriptRepositoryTests: XCTestCase {
    private var rootURL: URL!
    private var currentURL: URL!
    private var legacyURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VidLingoRepositoryTests-\(UUID().uuidString)", isDirectory: true)
        currentURL = rootURL.appendingPathComponent("current", isDirectory: true)
        legacyURL = rootURL.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: currentURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootURL)
        try super.tearDownWithError()
    }

    func testFlatPairEditsBecomeACompleteArtifact() throws {
        let sourceURL = currentURL.appendingPathComponent("old_original.txt")
        let translationURL = currentURL.appendingPathComponent("old_translation.txt")
        try "旧原文".write(to: sourceURL, atomically: true, encoding: .utf8)
        try "旧译文".write(to: translationURL, atomically: true, encoding: .utf8)

        let repository = TranscriptRepository(
            currentDirectoryURL: currentURL,
            legacyDirectoryURL: legacyURL
        )
        let oldTranscript = try XCTUnwrap(try repository.load().first)

        try repository.saveEdits(
            for: oldTranscript,
            sourceText: "新原文",
            translatedText: "新译文"
        )

        let records = try repository.load()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].sourceText, "新原文")
        XCTAssertEqual(records[0].translatedText, "新译文")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: translationURL.path))
        XCTAssertNotNil(records[0].manifest)
    }

    func testFlatPairDeleteRemovesBothFiles() throws {
        let sourceURL = currentURL.appendingPathComponent("old_original.txt")
        let translationURL = currentURL.appendingPathComponent("old_translation.txt")
        try "原文".write(to: sourceURL, atomically: true, encoding: .utf8)
        try "译文".write(to: translationURL, atomically: true, encoding: .utf8)

        let repository = TranscriptRepository(
            currentDirectoryURL: currentURL,
            legacyDirectoryURL: legacyURL
        )
        let transcript = try XCTUnwrap(try repository.load().first)

        try repository.delete(transcript)

        XCTAssertTrue(try repository.load().isEmpty)
    }
}
