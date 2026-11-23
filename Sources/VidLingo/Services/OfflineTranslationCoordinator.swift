import AVFoundation
import Foundation
import VidLingoCore

struct OfflineTranslationRunRequest: Sendable {
    let videoURL: URL
    let fallbackSource: LanguageOption
    let target: LanguageOption
    let initialProductContext: String
    let provider: TranslationProviderID
    let modelName: String
    let customBaseURL: String
    let shouldAutoDetectLanguage: Bool
    let shouldInferProductContext: Bool
    let allowsCloudAudioTranscription: Bool
    let allowsCloudVideoFrames: Bool
    let allowsVisualSalesCopy: Bool
}

struct OfflineTranslationRunResult: Sendable {
    let sourceText: String
    let translatedText: String
    let timedSegments: [TimedTranscriptSegment]
    let sourceLanguage: LanguageOption?
    let sourceDescription: String
    let productContext: String
    let artifactKind: TranscriptArtifactKind?
    let frameData: [Data]
}

struct OfflineVideoPreviewMetadata: Sendable, Equatable {
    let durationText: String
    let hasAudio: Bool?
}

struct OfflineVideoPreflight: Sendable {
    let durationSeconds: Double
    let audioTrackIndex: Int?
    let audioStartOffsetSeconds: Double?
}

struct OfflineTranslationCoordinator {
    typealias ProgressHandler = @Sendable (String) async -> Void

    func run(
        request: OfflineTranslationRunRequest,
        token: ProcessCancellationToken,
        reportProgress: @escaping ProgressHandler
    ) async throws -> OfflineTranslationRunResult {
        var audioURL: URL?
        var stageTimings = [OfflineTranslationStageTiming]()
        var detectedLanguageID: String?
        var diagnosticOutcome = "failed"
        var diagnosticError: String?
        var videoDurationSeconds: Int?

        func recordStage(_ name: String, startedAt: Date) {
            let milliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
            stageTimings.append(OfflineTranslationStageTiming(name: name, milliseconds: milliseconds))
        }

        defer {
            if let audioURL {
                OfflineVideoAudioExtractor.removeTemporaryAudio(audioURL)
            }
            OfflineTranslationDiagnostics.save(OfflineTranslationDiagnosticRecord(
                createdAt: Date(),
                languageID: detectedLanguageID,
                videoDurationSeconds: videoDurationSeconds,
                outcome: diagnosticOutcome,
                stages: stageTimings,
                errorDescription: diagnosticError
            ))
        }

        do {
            try token.check()
            guard request.allowsCloudAudioTranscription
                    || (request.allowsCloudVideoFrames && request.allowsVisualSalesCopy) else {
                throw OfflineVideoTranslationError.cloudAudioConsentRequired
            }
            let preflightStartedAt = Date()
            let preflight = try await Self.preflightVideo(request.videoURL, token: token)
            let videoDuration = preflight.durationSeconds
            videoDurationSeconds = Int(videoDuration.rounded())
            recordStage("mediaPreflight", startedAt: preflightStartedAt)

            guard let audioTrackIndex = preflight.audioTrackIndex else {
                try token.check()
                let visualStartedAt = Date()
                let result = try await generateNoSpeechResult(
                    request: request,
                    videoDuration: videoDuration,
                    token: token,
                    reportProgress: reportProgress
                )
                recordStage("visualFallback", startedAt: visualStartedAt)
                diagnosticOutcome = "noEffectiveSpeech"
                return result
            }
            guard request.allowsCloudAudioTranscription else {
                throw OfflineVideoTranslationError.cloudAudioConsentRequired
            }

            let audioStartedAt = Date()
            audioURL = try await OfflineVideoAudioExtractor.extractSpeechAudio(
                from: request.videoURL,
                videoDuration: videoDuration,
                audioTrackIndex: audioTrackIndex,
                token: token
            )
            guard let audioURL else {
                throw OfflineVideoTranslationError.audioExtractionFailed("Audio extraction returned no file.")
            }
            recordStage("audioExtraction", startedAt: audioStartedAt)

            let transcriptionStartedAt = Date()
            let transcription = try await transcribe(
                audioURL: audioURL,
                videoURL: request.videoURL,
                productContext: request.initialProductContext,
                languageHint: request.shouldAutoDetectLanguage
                    ? nil
                    : FunASRTranscriber.languageCode(for: request.fallbackSource),
                token: token,
                reportProgress: reportProgress
            )
            recordStage("transcription", startedAt: transcriptionStartedAt)
            let rawTranscript = transcription.text

            let languageStartedAt = Date()
            let sourceLanguage = try await detectLanguage(
                transcript: rawTranscript,
                request: request,
                token: token,
                reportProgress: reportProgress
            )
            recordStage("languageDetection", startedAt: languageStartedAt)
            detectedLanguageID = sourceLanguage.id

            let sourceText = TranscriptTextProcessor.organizeTranscript(
                rawTranscript,
                languageID: sourceLanguage.id
            )
            let rawTimedSegments = transcription.segments.compactMap { segment -> TimedTranscriptSegment? in
                let organizedText = TranscriptTextProcessor.organizeTranscript(
                    segment.sourceText,
                    languageID: sourceLanguage.id
                )
                guard !organizedText.isEmpty else { return nil }
                return TimedTranscriptSegment(
                    id: segment.id,
                    startMilliseconds: segment.startMilliseconds,
                    endMilliseconds: segment.endMilliseconds,
                    sourceText: organizedText
                )
            }
            let timedSegments = Self.alignTimedSegmentsToVideo(
                rawTimedSegments,
                audioStartOffsetSeconds: preflight.audioStartOffsetSeconds,
                videoDurationSeconds: videoDuration
            )
            guard SpeechTranscriptValidator.hasEffectiveSpeechTranscript(
                sourceText,
                language: sourceLanguage
            ) else {
                let visualStartedAt = Date()
                let result = try await generateNoSpeechResult(
                    request: request,
                    videoDuration: videoDuration,
                    token: token,
                    reportProgress: reportProgress
                )
                recordStage("visualFallback", startedAt: visualStartedAt)
                diagnosticOutcome = "noEffectiveSpeech"
                return result
            }

            let productContextStartedAt = Date()
            let productContext = try await inferProductContext(
                sourceText: sourceText,
                language: sourceLanguage,
                request: request,
                token: token,
                reportProgress: reportProgress
            )
            recordStage("productContext", startedAt: productContextStartedAt)

            let translationStartedAt = Date()
            await reportProgress(AppText.offlineVideoTranslating(request.videoURL.lastPathComponent, provider: request.provider.title))
            let translation = try await LLMTranslationService().translateTimedTranscript(
                sourceText,
                timedSegments: timedSegments,
                source: sourceLanguage,
                target: request.target,
                productContext: productContext,
                provider: request.provider,
                modelName: request.modelName,
                customBaseURL: request.customBaseURL,
                token: token
            )
            let resultSegments = translation.segments.isEmpty ? timedSegments : translation.segments
            recordStage("translation", startedAt: translationStartedAt)
            diagnosticOutcome = "completed"
            return OfflineTranslationRunResult(
                sourceText: sourceText,
                translatedText: translation.text,
                timedSegments: resultSegments,
                sourceLanguage: sourceLanguage,
                sourceDescription: AppText.funASRSource,
                productContext: productContext,
                artifactKind: .transcriptionTranslation,
                frameData: []
            )
        } catch ProcessSupervisorError.cancelled {
            diagnosticOutcome = "cancelled"
            throw ProcessSupervisorError.cancelled
        } catch is CancellationError {
            diagnosticOutcome = "cancelled"
            throw CancellationError()
        } catch {
            diagnosticError = OfflineTranslationDiagnostics.sanitizedErrorDescription(error.localizedDescription)
            throw error
        }
    }

    static func formattedVideoDuration(for videoURL: URL) async -> String {
        let asset = AVURLAsset(url: videoURL)
        let duration = try? await AsyncOperationTimeout.run(
            timeout: 15,
            onCancel: { asset.cancelLoading() }
        ) {
            try await asset.load(.duration)
        }
        let seconds = duration.map(CMTimeGetSeconds) ?? 0
        guard seconds.isFinite, seconds > 0 else { return "" }
        return String(format: "%d:%02d", Int(seconds.rounded()) / 60, Int(seconds.rounded()) % 60)
    }

    static func previewMetadata(for videoURL: URL) async -> OfflineVideoPreviewMetadata {
        let asset = AVURLAsset(url: videoURL)
        do {
            let metadata = try await AsyncOperationTimeout.run(
                timeout: 15,
                onCancel: { asset.cancelLoading() }
            ) {
                try await Self.loadVideoPreflight(asset)
            }
            let seconds = metadata.durationSeconds
            let durationText = seconds.isFinite && seconds > 0
                ? Self.durationText(seconds)
                : ""
            return OfflineVideoPreviewMetadata(
                durationText: durationText,
                hasAudio: metadata.audioTrackIndex != nil
            )
        } catch {
            return OfflineVideoPreviewMetadata(durationText: "", hasAudio: nil)
        }
    }

    private func detectLanguage(
        transcript: String,
        request: OfflineTranslationRunRequest,
        token: ProcessCancellationToken,
        reportProgress: @escaping ProgressHandler
    ) async throws -> LanguageOption {
        guard request.shouldAutoDetectLanguage else { return request.fallbackSource }
        try token.check()
        await reportProgress(AppText.offlineVideoDetectingLanguage(request.videoURL.lastPathComponent))
        let language = LanguageTextDetector.detect(transcript) ?? .undetermined
        await reportProgress(AppText.offlineVideoDetectedLanguage(language.localizedTitle))
        return language
    }

    private func transcribe(
        audioURL: URL,
        videoURL: URL,
        productContext: String,
        languageHint: String?,
        token: ProcessCancellationToken,
        reportProgress: @escaping ProgressHandler
    ) async throws -> FunASRTranscription {
        try token.check()
        await reportProgress(AppText.offlineVideoTranscribing(videoURL.lastPathComponent))
        let transcription = try await FunASRTranscriber.transcribe(
            audioFileURL: audioURL,
            productContext: productContext,
            token: token,
            languageHint: languageHint
        )
        return transcription
    }

    private func generateNoSpeechResult(
        request: OfflineTranslationRunRequest,
        videoDuration: Double,
        token: ProcessCancellationToken,
        reportProgress: @escaping ProgressHandler
    ) async throws -> OfflineTranslationRunResult {
        let sourceText = AppText.noEffectiveSpeech
        let supportsVision = LLMTranslationService.supportsProductContextFrames(
            provider: request.provider,
            modelName: request.modelName
        )
        guard request.allowsVisualSalesCopy, request.allowsCloudVideoFrames, supportsVision else {
            return OfflineTranslationRunResult(
                sourceText: sourceText,
                translatedText: AppText.noEffectiveSpeechDescription,
                timedSegments: [],
                sourceLanguage: nil,
                sourceDescription: AppText.funASRSource,
                productContext: request.initialProductContext,
                artifactKind: nil,
                frameData: []
            )
        }

        await reportProgress(AppText.generatingVisualSalesCopy(request.videoURL.lastPathComponent))
        let frames = try await OfflineVideoFrameExtractor.extractProductContextFrames(
            from: request.videoURL,
            token: token
        )
        guard !frames.isEmpty else {
            return OfflineTranslationRunResult(
                sourceText: sourceText,
                translatedText: AppText.noEffectiveSpeechDescription,
                timedSegments: [],
                sourceLanguage: nil,
                sourceDescription: AppText.funASRSource,
                productContext: request.initialProductContext,
                artifactKind: nil,
                frameData: []
            )
        }
        do {
            let visualCopy = try await LLMTranslationService().generateVisualSalesCopy(
                fileName: request.videoURL.lastPathComponent,
                durationText: Self.durationText(videoDuration),
                productContext: request.initialProductContext,
                frameJPEGData: frames,
                provider: request.provider,
                modelName: request.modelName,
                customBaseURL: request.customBaseURL,
                token: token
            )
            return OfflineTranslationRunResult(
                sourceText: sourceText,
                translatedText: "\(AppText.visualSalesCopyNotice)\n\n\(visualCopy)",
                timedSegments: [],
                sourceLanguage: nil,
                sourceDescription: AppText.funASRSource,
                productContext: request.initialProductContext,
                artifactKind: .visualGeneratedCopy,
                frameData: frames
            )
        } catch let error as LLMTranslationError where error.allowsVisionFallback {
            return OfflineTranslationRunResult(
                sourceText: sourceText,
                translatedText: AppText.noEffectiveSpeechDescription,
                timedSegments: [],
                sourceLanguage: nil,
                sourceDescription: AppText.funASRSource,
                productContext: request.initialProductContext,
                artifactKind: nil,
                frameData: []
            )
        }
    }

    private func inferProductContext(
        sourceText: String,
        language: LanguageOption,
        request: OfflineTranslationRunRequest,
        token: ProcessCancellationToken,
        reportProgress: @escaping ProgressHandler
    ) async throws -> String {
        var productContext = request.initialProductContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard request.shouldInferProductContext,
              productContext.isEmpty
        else {
            return productContext
        }

        try token.check()
        await reportProgress(AppText.inferringProductContext(request.videoURL.lastPathComponent))
        let frameData = request.allowsCloudVideoFrames
            && LLMTranslationService.supportsProductContextFrames(
                provider: request.provider,
                modelName: request.modelName
            )
            ? try await OfflineVideoFrameExtractor.extractProductContextFrames(from: request.videoURL, token: token)
            : []
        do {
            let inferred = try await LLMTranslationService().inferProductContext(
                from: sourceText,
                fileName: request.videoURL.lastPathComponent,
                frameJPEGData: frameData,
                source: language,
                provider: request.provider,
                modelName: request.modelName,
                customBaseURL: request.customBaseURL,
                token: token
            )
            if !inferred.isEmpty, inferred != AppText.unknownProductContext {
                productContext = inferred
            }
        } catch let error as LLMTranslationError where error.allowsVisionFallback {
            // 视觉能力不兼容时保留空商品类型，认证、额度和超时继续抛给界面。
        }
        return productContext
    }

    static func preflightVideo(_ videoURL: URL, token: ProcessCancellationToken) async throws -> OfflineVideoPreflight {
        try token.check()
        let values = try videoURL.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize, Int64(fileSize) <= MediaProcessingLimits.maxVideoBytes else {
            throw OfflineVideoTranslationError.videoTooLarge
        }
        let asset = AVURLAsset(url: videoURL)
        let preflight: OfflineVideoPreflight
        do {
            preflight = try await AsyncOperationTimeout.run(
                timeout: 15,
                token: token,
                onCancel: { asset.cancelLoading() }
            ) {
                try await Self.loadVideoPreflight(asset)
            }
        } catch let error as ProcessSupervisorError {
            throw error
        } catch is CancellationError {
            throw ProcessSupervisorError.cancelled
        } catch {
            throw OfflineVideoTranslationError.invalidVideo
        }
        let seconds = preflight.durationSeconds
        guard seconds.isFinite, seconds > 0 else { throw OfflineVideoTranslationError.invalidVideo }
        guard seconds <= MediaProcessingLimits.maxVideoDurationSeconds else {
            throw OfflineVideoTranslationError.videoTooLong
        }
        if preflight.audioTrackIndex != nil,
           seconds > FunASRTranscriber.maxDurationSeconds {
            throw OfflineVideoTranslationError.videoTooLongForFunASR
        }
        try token.check()
        return preflight
    }

    static func alignTimedSegmentsToVideo(
        _ segments: [TimedTranscriptSegment],
        audioStartOffsetSeconds: Double?,
        videoDurationSeconds: Double
    ) -> [TimedTranscriptSegment] {
        guard videoDurationSeconds.isFinite,
              videoDurationSeconds > 0,
              let audioStartOffsetSeconds,
              audioStartOffsetSeconds.isFinite,
              audioStartOffsetSeconds >= 0,
              audioStartOffsetSeconds <= videoDurationSeconds + 0.05 else {
            return []
        }
        let videoDurationMilliseconds = Int((videoDurationSeconds * 1_000).rounded(.down))
        let offsetMilliseconds = Int((min(audioStartOffsetSeconds, videoDurationSeconds) * 1_000).rounded(.toNearestOrAwayFromZero))
        let maximumTimeMilliseconds = videoDurationMilliseconds + 50
        let maximumAudioTimeMilliseconds = max(0, maximumTimeMilliseconds - offsetMilliseconds)
        var alignedSegments = [TimedTranscriptSegment]()
        alignedSegments.reserveCapacity(segments.count)
        for segment in segments {
            guard segment.startMilliseconds >= 0,
                  segment.endMilliseconds >= segment.startMilliseconds,
                  segment.startMilliseconds <= maximumAudioTimeMilliseconds,
                  segment.endMilliseconds <= maximumAudioTimeMilliseconds else {
                return []
            }
            let (start, startOverflow) = segment.startMilliseconds.addingReportingOverflow(offsetMilliseconds)
            let (end, endOverflow) = segment.endMilliseconds.addingReportingOverflow(offsetMilliseconds)
            guard !startOverflow, !endOverflow,
                  start <= maximumTimeMilliseconds,
                  end <= maximumTimeMilliseconds else {
                return []
            }
            alignedSegments.append(TimedTranscriptSegment(
                id: segment.id,
                startMilliseconds: min(start, videoDurationMilliseconds),
                endMilliseconds: min(end, videoDurationMilliseconds),
                sourceText: segment.sourceText,
                translatedText: segment.translatedText
            ))
        }
        return alignedSegments
    }

    private static func loadVideoPreflight(_ asset: AVURLAsset) async throws -> OfflineVideoPreflight {
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        let audioTracks = try await asset.load(.tracks).filter { $0.mediaType == .audio }
        var prioritizedTracks = Array(audioTracks.enumerated())
        if audioTracks.count > 1 {
            var enabled: [(Int, AVAssetTrack)] = []
            var alternate: [(Int, AVAssetTrack)] = []
            for (index, track) in prioritizedTracks {
                if try await track.load(.isEnabled) {
                    enabled.append((index, track))
                } else {
                    alternate.append((index, track))
                }
            }
            // 保留原始流序号，让 ffmpeg 提取与时间偏移使用同一条音轨。
            prioritizedTracks = enabled + alternate
        }
        for (index, track) in prioritizedTracks {
            let segments = try await track.load(.segments)
            if let firstMediaSegment = segments.first(where: { !$0.isEmpty }) {
                let startSeconds = CMTimeGetSeconds(firstMediaSegment.timeMapping.target.start)
                guard startSeconds.isFinite else { throw OfflineVideoTranslationError.invalidVideo }
                return OfflineVideoPreflight(
                    durationSeconds: seconds,
                    audioTrackIndex: index,
                    audioStartOffsetSeconds: max(0, startSeconds)
                )
            }

            let timeRange = try await track.load(.timeRange)
            let startSeconds = CMTimeGetSeconds(timeRange.start)
            let trackDurationSeconds = CMTimeGetSeconds(timeRange.duration)
            guard startSeconds.isFinite,
                  trackDurationSeconds.isFinite,
                  trackDurationSeconds > 0 else {
                continue
            }
            return OfflineVideoPreflight(
                durationSeconds: seconds,
                audioTrackIndex: index,
                audioStartOffsetSeconds: max(0, startSeconds)
            )
        }

        guard audioTracks.isEmpty else { throw OfflineVideoTranslationError.invalidVideo }
        return OfflineVideoPreflight(
            durationSeconds: seconds,
            audioTrackIndex: nil,
            audioStartOffsetSeconds: nil
        )
    }

    private static func durationText(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds.rounded()) / 60, Int(seconds.rounded()) % 60)
    }

}
