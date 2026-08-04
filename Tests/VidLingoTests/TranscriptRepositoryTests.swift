import XCTest
@testable import VidLingo
@testable import VidLingoCore

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

    func testLegacyRecordsAreReadOnlyAndCurrentDeleteLeavesThemUntouched() throws {
        let sourceURL = legacyURL.appendingPathComponent("legacy_original.txt")
        let translationURL = legacyURL.appendingPathComponent("legacy_translation.txt")
        try "旧原文".write(to: sourceURL, atomically: true, encoding: .utf8)
        try "旧译文".write(to: translationURL, atomically: true, encoding: .utf8)

        let repository = TranscriptRepository(
            currentDirectoryURL: currentURL,
            legacyDirectoryURL: legacyURL
        )
        let transcript = try XCTUnwrap(try repository.load().first)
        XCTAssertTrue(transcript.isLegacy)

        XCTAssertThrowsError(
            try repository.saveEdits(for: transcript, sourceText: "不应修改", translatedText: "不应修改")
        ) { error in
            XCTAssertEqual(error as? TranscriptRepositoryError, .legacyReadOnly)
        }
        XCTAssertThrowsError(try repository.delete(transcript)) { error in
            XCTAssertEqual(error as? TranscriptRepositoryError, .legacyReadOnly)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: translationURL.path))
    }

    func testDeleteAllReturnsPerRecordResultsAndSkipsLegacyRecords() throws {
        let currentSourceURL = currentURL.appendingPathComponent("current_original.txt")
        let currentTranslationURL = currentURL.appendingPathComponent("current_translation.txt")
        try "原文".write(to: currentSourceURL, atomically: true, encoding: .utf8)
        try "译文".write(to: currentTranslationURL, atomically: true, encoding: .utf8)

        let legacySourceURL = legacyURL.appendingPathComponent("legacy_original.txt")
        let legacyTranslationURL = legacyURL.appendingPathComponent("legacy_translation.txt")
        try "旧原文".write(to: legacySourceURL, atomically: true, encoding: .utf8)
        try "旧译文".write(to: legacyTranslationURL, atomically: true, encoding: .utf8)

        let repository = TranscriptRepository(
            currentDirectoryURL: currentURL,
            legacyDirectoryURL: legacyURL
        )
        let records = try repository.load()
        let result = repository.deleteAllCurrent(records)

        XCTAssertEqual(result.deletedIDs.count, 1)
        XCTAssertTrue(result.failedIDs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacySourceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyTranslationURL.path))
    }

    func testEditingTranslationPreservesSourceTimelineWithoutStaleTranslations() throws {
        let repository = TranscriptRepository(
            currentDirectoryURL: currentURL,
            legacyDirectoryURL: legacyURL
        )
        let sourceLanguage = try XCTUnwrap(LanguageOption.supported.first(where: { $0.id == "ms-MY" }))
        let segments = [
            TimedTranscriptSegment(
                id: 1,
                startMilliseconds: 0,
                endMilliseconds: 1_000,
                sourceText: "原文",
                translatedText: "旧译文"
            )
        ]
        _ = try repository.publish(
            sourceText: "原文",
            translatedText: "旧译文",
            sourceLanguage: sourceLanguage,
            targetLanguage: LanguageOption(id: "zh-CN", title: "Chinese Simplified", locale: Locale(identifier: "zh-CN")),
            provider: .qwen,
            modelName: "qwen3.6-plus",
            videoFileName: "sample.mp4",
            kind: .transcriptionTranslation,
            timedSegments: segments
        )

        let original = try XCTUnwrap(try repository.load().first)
        try repository.saveEdits(for: original, sourceText: "原文", translatedText: "新译文")

        let updated = try XCTUnwrap(try repository.load().first)
        XCTAssertEqual(updated.timedSegments.count, 1)
        XCTAssertEqual(updated.timedSegments[0].sourceText, "原文")
        XCTAssertFalse(updated.timedSegments[0].hasTranslation)
    }
}
