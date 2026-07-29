import XCTest
@testable import VidLingoCore

final class ArtifactPublisherTests: XCTestCase {
    private var directoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VidLingoCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directoryURL)
        try super.tearDownWithError()
    }

    func testPublishCommitsCompleteArtifact() throws {
        let manifest = makeManifest(id: "artifact-1")
        let artifact = try ArtifactPublisher.publish(
            sourceText: "原文",
            translatedText: "译文",
            manifest: manifest,
            in: directoryURL
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.sourceFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.translationFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.manifestFileURL.path))
        XCTAssertEqual(try String(contentsOf: artifact.sourceFileURL, encoding: .utf8), "原文")
        XCTAssertEqual(try String(contentsOf: artifact.translationFileURL, encoding: .utf8), "译文")
    }

    func testPublishDoesNotOverwriteExistingArtifact() throws {
        let manifest = makeManifest(id: "same-id")
        _ = try ArtifactPublisher.publish(
            sourceText: "原文",
            translatedText: "译文",
            manifest: manifest,
            in: directoryURL
        )

        XCTAssertThrowsError(
            try ArtifactPublisher.publish(
                sourceText: "新原文",
                translatedText: "新译文",
                manifest: manifest,
                in: directoryURL
            )
        ) { error in
            guard case .destinationAlreadyExists = error as? ArtifactPublisherError else {
                return XCTFail("Expected a no-clobber error, got \(error)")
            }
        }
    }

    func testStaleStagingDirectoriesAreRemoved() throws {
        let stagingURL = directoryURL.appendingPathComponent(".staging-old", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -7_200)],
            ofItemAtPath: stagingURL.path
        )

        try ArtifactPublisher.removeStaleStagingDirectories(in: directoryURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))
    }

    private func makeManifest(id: String) -> TranscriptArtifactManifest {
        TranscriptArtifactManifest(
            id: id,
            createdAt: Date(timeIntervalSince1970: 0),
            kind: .transcriptionTranslation,
            sourceLanguageID: "ms-MY",
            targetLanguageID: "zh-CN",
            providerID: "qwen",
            modelName: "qwen3.6-plus",
            videoFileName: "sample.mp4"
        )
    }
}
