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

struct OfflineTranslationCoordinator {
    typealias ProgressHandler = @Sendable (String) async -> Void
    typealias TranscriptionHandler = @Sendable (String, String) async -> Void

    func run(
        request: OfflineTranslationRunRequest,
        token: ProcessCancellationToken,
        reportProgress: @escaping ProgressHandler,
        reportTranscription: @escaping TranscriptionHandler
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
            guard request.allowsCloudAudioTranscription else {
                throw OfflineVideoTranslationError.cloudAudioConsentRequired
            }
            let preflightStartedAt = Date()
            let videoDuration = try await Self.preflightVideo(request.videoURL, token: token)
            videoDurationSeconds = Int(videoDuration.rounded())
            recordStage("mediaPreflight", startedAt: preflightStartedAt)

            let audioStartedAt = Date()
            audioURL = try await OfflineVideoAudioExtractor.extractSpeechAudio(from: request.videoURL, token: token)
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
            let timedSegments = transcription.segments.compactMap { segment -> TimedTranscriptSegment? in
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
            await reportTranscription(sourceText, AppText.funASRSource)

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
        let duration = try? await withTaskCancellationHandler {
            try await AsyncOperationTimeout.run(timeout: 15) {
                try await asset.load(.duration)
            }
        } onCancel: {
            asset.cancelLoading()
        }
        let seconds = duration.map(CMTimeGetSeconds) ?? 0
        guard seconds.isFinite, seconds > 0 else { return "" }
        return String(format: "%d:%02d", Int(seconds.rounded()) / 60, Int(seconds.rounded()) % 60)
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
              productContext.isEmpty,
              !LLMTranslationService.isTranslationOnlyModel(provider: request.provider, modelName: request.modelName)
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

    private static func preflightVideo(_ videoURL: URL, token: ProcessCancellationToken) async throws -> Double {
        try token.check()
        let values = try videoURL.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize, Int64(fileSize) <= MediaProcessingLimits.maxVideoBytes else {
            throw OfflineVideoTranslationError.videoTooLarge
        }
        let asset = AVURLAsset(url: videoURL)
        let duration = try? await withTaskCancellationHandler {
            try await AsyncOperationTimeout.run(timeout: 15) {
                try await asset.load(.duration)
            }
        } onCancel: {
            asset.cancelLoading()
        }
        guard let duration else { throw OfflineVideoTranslationError.invalidVideo }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { throw OfflineVideoTranslationError.invalidVideo }
        guard seconds <= MediaProcessingLimits.maxVideoDurationSeconds else {
            throw OfflineVideoTranslationError.videoTooLong
        }
        guard seconds <= FunASRTranscriber.maxDurationSeconds else {
            throw OfflineVideoTranslationError.videoTooLongForFunASR
        }
        try token.check()
        return seconds
    }

    private static func durationText(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds.rounded()) / 60, Int(seconds.rounded()) % 60)
    }

}
