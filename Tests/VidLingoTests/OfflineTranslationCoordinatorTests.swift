import XCTest
import Foundation
import VidLingoCore
@testable import VidLingo

final class OfflineTranslationCoordinatorTests: XCTestCase {
    func testRunRejectsCloudAudioWithoutExplicitConsent() async throws {
        let request = OfflineTranslationRunRequest(
            videoURL: URL(fileURLWithPath: "/tmp/not-used.mp4"),
            fallbackSource: .english,
            target: LanguageOption(id: "zh-CN", title: "Chinese Simplified", locale: Locale(identifier: "zh-CN")),
            initialProductContext: "",
            provider: .rootify,
            modelName: "gpt-5.6-luna",
            customBaseURL: "",
            shouldAutoDetectLanguage: true,
            shouldInferProductContext: true,
            allowsCloudAudioTranscription: false,
            allowsCloudVideoFrames: false,
            allowsVisualSalesCopy: false
        )
        let token = ProcessCancellationToken(timeout: 30)

        do {
            _ = try await OfflineTranslationCoordinator().run(
                request: request,
                token: token,
                reportProgress: { _ in }
            )
            XCTFail("Expected explicit cloud audio consent to be required")
        } catch let error as OfflineVideoTranslationError {
            XCTAssertEqual(error.errorDescription, AppText.cloudAudioConsentRequired)
        }
    }

    func testPreflightUsesPresentationOffsetWithoutCountingAACPriming() async throws {
        let normalVideoURL = try makeSyntheticVideo(.normalAudio)
        let delayedVideoURL = try makeSyntheticVideo(.delayedAudio)
        let token = ProcessCancellationToken(timeout: 30)

        let normalPreview = await OfflineTranslationCoordinator.previewMetadata(for: normalVideoURL)
        XCTAssertEqual(normalPreview.hasAudio, true)
        XCTAssertEqual(normalPreview.durationText, "0:05")
        let normalPreflight = try await OfflineTranslationCoordinator.preflightVideo(normalVideoURL, token: token)
        XCTAssertEqual(normalPreflight.audioStartOffsetSeconds ?? -1, 0, accuracy: 0.001)

        let delayedPreview = await OfflineTranslationCoordinator.previewMetadata(for: delayedVideoURL)
        XCTAssertEqual(delayedPreview.hasAudio, true)
        let delayedPreflight = try await OfflineTranslationCoordinator.preflightVideo(delayedVideoURL, token: token)
        XCTAssertEqual(delayedPreflight.audioStartOffsetSeconds ?? -1, 1.978, accuracy: 0.03)

        let sourceSegments = [TimedTranscriptSegment(
            id: 1,
            startMilliseconds: 200,
            endMilliseconds: 400,
            sourceText: "测试"
        )]
        let alignedSegments = OfflineTranslationCoordinator.alignTimedSegmentsToVideo(
            sourceSegments,
            audioStartOffsetSeconds: delayedPreflight.audioStartOffsetSeconds,
            videoDurationSeconds: delayedPreflight.durationSeconds
        )
        let offsetMilliseconds = Int(((delayedPreflight.audioStartOffsetSeconds ?? 0) * 1_000).rounded())
        XCTAssertEqual(alignedSegments.map(\.startMilliseconds), [200 + offsetMilliseconds])
        XCTAssertEqual(alignedSegments.map(\.endMilliseconds), [400 + offsetMilliseconds])

        let unchangedSegments = OfflineTranslationCoordinator.alignTimedSegmentsToVideo(
            sourceSegments,
            audioStartOffsetSeconds: normalPreflight.audioStartOffsetSeconds,
            videoDurationSeconds: normalPreflight.durationSeconds
        )
        XCTAssertEqual(unchangedSegments, sourceSegments)
    }

    func testNoAudioVideoUsesExistingNoSpeechFallbackAndPreviewConfirmsAbsence() async throws {
        let videoURL = try makeSyntheticVideo(.noAudio)
        let preview = await OfflineTranslationCoordinator.previewMetadata(for: videoURL)
        XCTAssertEqual(preview.hasAudio, false)
        XCTAssertEqual(preview.durationText, "0:05")

        let token = ProcessCancellationToken(timeout: 30)
        let preflight = try await OfflineTranslationCoordinator.preflightVideo(videoURL, token: token)
        XCTAssertNil(preflight.audioTrackIndex)
        let request = makeRequest(
            videoURL: videoURL,
            allowsCloudAudioTranscription: false,
            allowsCloudVideoFrames: true,
            allowsVisualSalesCopy: true
        )
        let result = try await OfflineTranslationCoordinator().run(
            request: request,
            token: token,
            reportProgress: { _ in }
        )
        XCTAssertEqual(result.sourceText, AppText.noEffectiveSpeech)
        XCTAssertEqual(result.translatedText, AppText.noEffectiveSpeechDescription)
        XCTAssertNil(result.artifactKind)
        XCTAssertTrue(result.frameData.isEmpty)
    }

    func testAudioWithoutConsentIsRejectedAfterTrackPreflight() async throws {
        let videoURL = try makeSyntheticVideo(.normalAudio)
        let request = makeRequest(
            videoURL: videoURL,
            allowsCloudAudioTranscription: false,
            allowsCloudVideoFrames: true,
            allowsVisualSalesCopy: true
        )

        do {
            _ = try await OfflineTranslationCoordinator().run(
                request: request,
                token: ProcessCancellationToken(timeout: 30),
                reportProgress: { _ in }
            )
            XCTFail("Expected an audio track to require explicit audio consent")
        } catch let error as OfflineVideoTranslationError {
            XCTAssertEqual(error.errorDescription, AppText.cloudAudioConsentRequired)
        }
    }

    func testNoAudioPreflightUsesVideoLimitRatherThanFunASRLimit() async throws {
        let videoURL = try makeSyntheticVideo(.noAudio, durationSeconds: 300.5)
        let preflight = try await OfflineTranslationCoordinator.preflightVideo(
            videoURL,
            token: ProcessCancellationToken(timeout: 30)
        )

        XCTAssertNil(preflight.audioTrackIndex)
        XCTAssertEqual(preflight.durationSeconds, 300.5, accuracy: 0.1)
    }

    func testInvalidOrOverflowingAudioTimestampsDisableTimeline() {
        let overflowingSegment = TimedTranscriptSegment(
            id: 1,
            startMilliseconds: Int.max - 10,
            endMilliseconds: Int.max,
            sourceText: "异常时间戳"
        )
        XCTAssertTrue(OfflineTranslationCoordinator.alignTimedSegmentsToVideo(
            [overflowingSegment],
            audioStartOffsetSeconds: 1.978,
            videoDurationSeconds: 5
        ).isEmpty)

        let segment = TimedTranscriptSegment(id: 2, startMilliseconds: 3_000, endMilliseconds: 3_025, sourceText: "尾部")
        let clamped = OfflineTranslationCoordinator.alignTimedSegmentsToVideo(
            [segment],
            audioStartOffsetSeconds: 1.978,
            videoDurationSeconds: 5
        )
        XCTAssertEqual(clamped.first?.startMilliseconds, 4_978)
        XCTAssertEqual(clamped.first?.endMilliseconds, 5_000)

        XCTAssertTrue(OfflineTranslationCoordinator.alignTimedSegmentsToVideo(
            [segment],
            audioStartOffsetSeconds: Double.greatestFiniteMagnitude,
            videoDurationSeconds: 5
        ).isEmpty)
    }

    private func makeRequest(
        videoURL: URL,
        allowsCloudAudioTranscription: Bool,
        allowsCloudVideoFrames: Bool,
        allowsVisualSalesCopy: Bool
    ) -> OfflineTranslationRunRequest {
        OfflineTranslationRunRequest(
            videoURL: videoURL,
            fallbackSource: .english,
            target: LanguageOption(id: "zh-CN", title: "Chinese Simplified", locale: Locale(identifier: "zh-CN")),
            initialProductContext: "",
            provider: .deepSeek,
            modelName: "deepseek-v4-flash",
            customBaseURL: "",
            shouldAutoDetectLanguage: true,
            shouldInferProductContext: true,
            allowsCloudAudioTranscription: allowsCloudAudioTranscription,
            allowsCloudVideoFrames: allowsCloudVideoFrames,
            allowsVisualSalesCopy: allowsVisualSalesCopy
        )
    }

    private func makeSyntheticVideo(
        _ kind: SyntheticVideoKind,
        durationSeconds: Double = 5
    ) throws -> URL {
        guard let ffmpegURL = ExecutableFinder.findExecutable(named: ["ffmpeg"]) else {
            throw XCTSkip("ffmpeg is required to create local media fixtures")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VidLingo-MediaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        let outputURL = directory.appendingPathComponent("fixture.mp4")
        var arguments = [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "color=c=black:s=160x90:r=30:d=\(durationSeconds)"
        ]
        switch kind {
        case .noAudio:
            arguments += ["-map", "0:v:0", "-an"]
        case .normalAudio:
            arguments += [
                "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000:duration=\(durationSeconds)",
                "-map", "0:v:0", "-map", "1:a:0"
            ]
        case .delayedAudio:
            arguments += [
                "-itsoffset", "2",
                "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000:duration=3",
                "-map", "0:v:0", "-map", "1:a:0"
            ]
        }
        arguments += ["-c:v", "mpeg4", "-pix_fmt", "yuv420p", "-t", "\(durationSeconds)"]
        if kind != .noAudio {
            arguments += ["-c:a", "aac", "-b:a", "96k"]
        }
        arguments.append(outputURL.path(percentEncoded: false))

        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "OfflineTranslationCoordinatorTests", code: Int(process.terminationStatus))
        }
        return outputURL
    }

    private enum SyntheticVideoKind: Equatable {
        case noAudio
        case normalAudio
        case delayedAudio
    }
}
