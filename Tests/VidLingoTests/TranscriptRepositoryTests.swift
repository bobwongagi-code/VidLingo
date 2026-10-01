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

        let publishedRecordID = try repository.saveEdits(
            for: oldTranscript,
            sourceText: "新原文",
            translatedText: "新译文"
        )

        let records = try repository.load()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(publishedRecordID, records[0].id)
        XCTAssertEqual(publishedRecordID, "current:\(records[0].manifest?.id ?? "")")
        XCTAssertEqual(records[0].sourceText, "新原文")
        XCTAssertEqual(records[0].translatedText, "新译文")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: translationURL.path))
        XCTAssertNotNil(records[0].manifest)
    }

    func testFailedArtifactRetirementKeepsThePublishedEditReadable() throws {
        let fileManager = FaultInjectingFileManager()
        let repository = TranscriptRepository(
            currentDirectoryURL: currentURL,
            legacyDirectoryURL: legacyURL,
            fileManager: fileManager
        )
        _ = try repository.publish(
            sourceText: "旧原文",
            translatedText: "旧译文",
            sourceLanguage: nil,
            targetLanguage: LanguageOption(id: "zh-CN", title: "简体中文", locale: Locale(identifier: "zh-CN")),
            provider: .rootify,
            modelName: "test-model",
            videoFileName: "sample.mp4",
            kind: .transcriptionTranslation
        )
        let oldTranscript = try XCTUnwrap(try repository.load().first)
        let oldDirectoryURL = oldTranscript.sourceFileURL.deletingLastPathComponent()
        fileManager.fault = .partiallyRemoveArtifactDirectory(oldDirectoryURL)

        XCTAssertThrowsError(
            try repository.saveEdits(
                for: oldTranscript,
                sourceText: "新原文",
                translatedText: "新译文"
            )
        )
        let records = try repository.load()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].sourceText, "新原文")
        XCTAssertEqual(records[0].translatedText, "新译文")
        XCTAssertNotNil(records[0].manifest)
    }

    func testFailedPublicationLeavesTheOriginalArtifactReadable() throws {
        let fileManager = FaultInjectingFileManager()
        let repository = TranscriptRepository(
            currentDirectoryURL: currentURL,
            legacyDirectoryURL: legacyURL,
            fileManager: fileManager
        )
        _ = try repository.publish(
            sourceText: "旧原文",
            translatedText: "旧译文",
            sourceLanguage: nil,
            targetLanguage: LanguageOption(id: "zh-CN", title: "简体中文", locale: Locale(identifier: "zh-CN")),
            provider: .rootify,
            modelName: "test-model",
            videoFileName: "sample.mp4",
            kind: .transcriptionTranslation
        )
        let oldTranscript = try XCTUnwrap(try repository.load().first)
        fileManager.fault = .failPublicationMove

        XCTAssertThrowsError(
            try repository.saveEdits(
                for: oldTranscript,
                sourceText: "新原文",
                translatedText: "新译文"
            )
        )

        let records = try repository.load()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].sourceText, "旧原文")
        XCTAssertEqual(records[0].translatedText, "旧译文")
    }

    func testFailedArtifactRenameLeavesBothCompleteRecordsReadable() throws {
        let fileManager = FaultInjectingFileManager()
        let repository = TranscriptRepository(
            currentDirectoryURL: currentURL,
            legacyDirectoryURL: legacyURL,
            fileManager: fileManager
        )
        _ = try repository.publish(
            sourceText: "旧原文",
            translatedText: "旧译文",
            sourceLanguage: nil,
            targetLanguage: LanguageOption(id: "zh-CN", title: "简体中文", locale: Locale(identifier: "zh-CN")),
            provider: .rootify,
            modelName: "test-model",
            videoFileName: "sample.mp4",
            kind: .transcriptionTranslation
        )
        let oldTranscript = try XCTUnwrap(try repository.load().first)
        let oldDirectoryURL = oldTranscript.sourceFileURL.deletingLastPathComponent()
        fileManager.fault = .failArtifactRetirementMove(oldDirectoryURL)

        XCTAssertThrowsError(
            try repository.saveEdits(
                for: oldTranscript,
                sourceText: "新原文",
                translatedText: "新译文"
            )
        )

        let records = try repository.load()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.map(\.sourceText)), Set(["旧原文", "新原文"]))
        XCTAssertEqual(Set(records.compactMap(\.translatedText)), Set(["旧译文", "新译文"]))
    }

    func testFailedFlatPairRetirementKeepsThePublishedArtifactReadable() throws {
        let fileManager = FaultInjectingFileManager()
        let repository = TranscriptRepository(
            currentDirectoryURL: currentURL,
            legacyDirectoryURL: legacyURL,
            fileManager: fileManager
        )
        let sourceURL = currentURL.appendingPathComponent("old_original.txt")
        let translationURL = currentURL.appendingPathComponent("old_translation.txt")
        try "旧原文".write(to: sourceURL, atomically: true, encoding: .utf8)
        try "旧译文".write(to: translationURL, atomically: true, encoding: .utf8)
        let oldTranscript = try XCTUnwrap(try repository.load().first)
        fileManager.fault = .failFlatPairRetirementRollback(
            sourceURL: sourceURL,
            translationURL: translationURL
        )

        XCTAssertThrowsError(
            try repository.saveEdits(
                for: oldTranscript,
                sourceText: "新原文",
                translatedText: "新译文"
            )
        ) { error in
            guard let repositoryError = error as? TranscriptRepositoryError,
                  case .savedButRetirementFailed = repositoryError else {
                XCTFail("预期旧记录退休失败，但新编辑已发布：\(error)")
                return
            }
        }
        XCTAssertTrue(fileManager.flatPairRetirementRollbackWasInjected)

        let records = try repository.load()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].sourceText, "新原文")
        XCTAssertEqual(records[0].translatedText, "新译文")
        XCTAssertNotNil(records[0].manifest)
    }

    func testPartialFlatPairQuarantineCleanupKeepsThePublishedArtifactReadable() throws {
        let fileManager = FaultInjectingFileManager()
        let repository = TranscriptRepository(
            currentDirectoryURL: currentURL,
            legacyDirectoryURL: legacyURL,
            fileManager: fileManager
        )
        let sourceURL = currentURL.appendingPathComponent("old_original.txt")
        let translationURL = currentURL.appendingPathComponent("old_translation.txt")
        try "旧原文".write(to: sourceURL, atomically: true, encoding: .utf8)
        try "旧译文".write(to: translationURL, atomically: true, encoding: .utf8)
        let oldTranscript = try XCTUnwrap(try repository.load().first)
        fileManager.fault = .partiallyRemoveFlatPairQuarantine

        XCTAssertThrowsError(
            try repository.saveEdits(
                for: oldTranscript,
                sourceText: "新原文",
                translatedText: "新译文"
            )
        )

        let records = try repository.load()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].sourceText, "新原文")
        XCTAssertEqual(records[0].translatedText, "新译文")
        XCTAssertNotNil(records[0].manifest)
    }

    @MainActor
    func testPartialRetirementReloadAndRetryUsesPublishedRecord() async throws {
        let fileManager = FaultInjectingFileManager()
        let repository = TranscriptRepository(
            currentDirectoryURL: currentURL,
            legacyDirectoryURL: legacyURL,
            fileManager: fileManager
        )
        _ = try repository.publish(
            sourceText: "旧原文",
            translatedText: "旧译文",
            sourceLanguage: nil,
            targetLanguage: LanguageOption(id: "zh-CN", title: "简体中文", locale: Locale(identifier: "zh-CN")),
            provider: .rootify,
            modelName: "test-model",
            videoFileName: "sample.mp4",
            kind: .transcriptionTranslation
        )
        let store = TranslationSessionStore(transcriptRepository: repository)
        let oldTranscript = try XCTUnwrap(store.savedTranscripts.first)
        store.selectSavedTranscript(oldTranscript.id)
        store.savedDraftSourceText = "第一次修改"
        store.savedDraftTranslationText = "第一次译文"
        fileManager.fault = .failArtifactRetirementMove(
            oldTranscript.sourceFileURL.deletingLastPathComponent()
        )

        store.saveSelectedTranscriptEdits()

        let firstPublishedTranscript = try XCTUnwrap(store.selectedSavedTranscript)
        XCTAssertNotEqual(firstPublishedTranscript.id, oldTranscript.id)
        XCTAssertEqual(firstPublishedTranscript.sourceText, "第一次修改")
        XCTAssertEqual(firstPublishedTranscript.translatedText, "第一次译文")
        XCTAssertTrue(firstPublishedTranscript.id.hasPrefix("current:"))
        XCTAssertEqual(store.savedTranscripts.count, 2)

        store.savedDraftSourceText = "第二次修改"
        store.savedDraftTranslationText = "第二次译文"
        store.saveSelectedTranscriptEdits()

        XCTAssertEqual(store.savedTranscripts.count, 2)
        XCTAssertFalse(store.savedTranscripts.contains { $0.sourceText == "第一次修改" })
        XCTAssertEqual(store.savedTranscripts.filter { $0.sourceText == "第二次修改" }.count, 1)
        XCTAssertEqual(store.selectedSavedTranscript?.sourceText, "第二次修改")
        XCTAssertEqual(store.selectedSavedTranscript?.translatedText, "第二次译文")
        XCTAssertEqual(store.selectedSavedTranscriptID, store.savedTranscripts.first?.id)
    }

    @MainActor
    func testSuccessfulEditSelectsPublishedRecord() async throws {
        let repository = TranscriptRepository(
            currentDirectoryURL: currentURL,
            legacyDirectoryURL: legacyURL
        )
        _ = try repository.publish(
            sourceText: "旧原文",
            translatedText: "旧译文",
            sourceLanguage: nil,
            targetLanguage: LanguageOption(id: "zh-CN", title: "简体中文", locale: Locale(identifier: "zh-CN")),
            provider: .rootify,
            modelName: "test-model",
            videoFileName: "sample.mp4",
            kind: .transcriptionTranslation
        )
        let store = TranslationSessionStore(transcriptRepository: repository)
        let oldTranscript = try XCTUnwrap(store.savedTranscripts.first)
        store.selectSavedTranscript(oldTranscript.id)
        store.savedDraftSourceText = "新原文"
        store.savedDraftTranslationText = "新译文"

        store.saveSelectedTranscriptEdits()

        XCTAssertEqual(store.savedTranscripts.count, 1)
        XCTAssertNotEqual(store.selectedSavedTranscriptID, oldTranscript.id)
        XCTAssertEqual(store.selectedSavedTranscript?.sourceText, "新原文")
        XCTAssertEqual(store.selectedSavedTranscriptID, store.savedTranscripts.first?.id)
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
            provider: .rootify,
            modelName: "gpt-5.6-luna",
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

private final class FaultInjectingFileManager: FileManager {
    enum Fault {
        case partiallyRemoveArtifactDirectory(URL)
        case partiallyRemoveFlatPairQuarantine
        case failPublicationMove
        case failArtifactRetirementMove(URL)
        case failFlatPairRetirementRollback(sourceURL: URL, translationURL: URL)
    }

    var fault: Fault?
    private var failedFlatTranslationMove = false
    private(set) var flatPairRetirementRollbackWasInjected = false

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        switch fault {
        case .some(.failPublicationMove):
            if srcURL.lastPathComponent.hasPrefix(".staging-"),
               !dstURL.lastPathComponent.hasPrefix(".staging-") {
                fault = nil
                throw InjectedFileManagerError.requested
            }
        case let .some(.failArtifactRetirementMove(oldDirectoryURL)):
            if srcURL.standardizedFileURL == oldDirectoryURL.standardizedFileURL,
               dstURL.lastPathComponent.hasPrefix(".staging-retired-") {
                fault = nil
                throw InjectedFileManagerError.requested
            }
        case let .some(.failFlatPairRetirementRollback(sourceURL, translationURL)):
            if srcURL.lastPathComponent == translationURL.lastPathComponent,
               srcURL.deletingLastPathComponent().resolvingSymlinksInPath()
                    == translationURL.deletingLastPathComponent().resolvingSymlinksInPath(),
               dstURL.deletingLastPathComponent().lastPathComponent.hasPrefix(".staging-retire-") {
                failedFlatTranslationMove = true
                throw InjectedFileManagerError.requested
            }
            if failedFlatTranslationMove,
               srcURL.deletingLastPathComponent().lastPathComponent.hasPrefix(".staging-retire-"),
               dstURL.lastPathComponent == sourceURL.lastPathComponent,
               dstURL.deletingLastPathComponent().resolvingSymlinksInPath()
                    == sourceURL.deletingLastPathComponent().resolvingSymlinksInPath() {
                fault = nil
                flatPairRetirementRollbackWasInjected = true
                throw InjectedFileManagerError.requested
            }
        case .some(.partiallyRemoveArtifactDirectory), .some(.partiallyRemoveFlatPairQuarantine):
            break
        case nil:
            break
        }

        try super.moveItem(at: srcURL, to: dstURL)
    }

    override func removeItem(at url: URL) throws {
        if case let .some(.partiallyRemoveArtifactDirectory(oldDirectoryURL)) = fault,
           url.standardizedFileURL == oldDirectoryURL.standardizedFileURL
                || url.lastPathComponent.hasPrefix(".staging-retired-") {
            fault = nil
            let originalURL = url.appendingPathComponent("original.txt")
            if fileExists(atPath: originalURL.path) {
                try super.removeItem(at: originalURL)
            }
            throw InjectedFileManagerError.requested
        }
        if case .some(.partiallyRemoveFlatPairQuarantine) = fault,
           url.lastPathComponent.hasPrefix(".staging-retire-") {
            fault = nil
            let originalURL = url.appendingPathComponent("original.txt")
            if fileExists(atPath: originalURL.path) {
                try super.removeItem(at: originalURL)
            }
            throw InjectedFileManagerError.requested
        }

        try super.removeItem(at: url)
    }
}

private enum InjectedFileManagerError: Error {
    case requested
}
