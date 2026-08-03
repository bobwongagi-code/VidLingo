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
    let allowsCloudVideoFrames: Bool
    let allowsVisualSalesCopy: Bool
}

struct OfflineTranslationRunResult: Sendable {
    let sourceText: String
    let translatedText: String
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

            let languageStartedAt = Date()
            let sourceLanguage = try await detectLanguage(
                audioURL: audioURL,
                request: request,
                token: token,
                reportProgress: reportProgress
            )
            recordStage("languageDetection", startedAt: languageStartedAt)
            detectedLanguageID = sourceLanguage.id

            let transcriptionStartedAt = Date()
            let transcription = try await transcribe(
                audioURL: audioURL,
                videoURL: request.videoURL,
                language: sourceLanguage,
                token: token,
                reportProgress: reportProgress
            )
            recordStage("transcription", startedAt: transcriptionStartedAt)
            await reportTranscription(transcription.sourceText, transcription.sourceDescription)

            guard SpeechTranscriptValidator.hasEffectiveSpeechTranscript(
                transcription.sourceText,
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
                sourceText: transcription.sourceText,
                language: sourceLanguage,
                request: request,
                token: token,
                reportProgress: reportProgress
            )
            recordStage("productContext", startedAt: productContextStartedAt)

            let translationStartedAt = Date()
            await reportProgress(AppText.offlineVideoTranslating(request.videoURL.lastPathComponent, provider: request.provider.title))
            let translatedText = try await LLMTranslationService().translateShortVideoTranscript(
                transcription.sourceText,
                source: sourceLanguage,
                target: request.target,
                productContext: productContext,
                provider: request.provider,
                modelName: request.modelName,
                customBaseURL: request.customBaseURL,
                token: token
            )
            recordStage("translation", startedAt: translationStartedAt)
            diagnosticOutcome = "completed"
            return OfflineTranslationRunResult(
                sourceText: transcription.sourceText,
                translatedText: translatedText,
                sourceLanguage: sourceLanguage,
                sourceDescription: transcription.sourceDescription,
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
        audioURL: URL,
        request: OfflineTranslationRunRequest,
        token: ProcessCancellationToken,
        reportProgress: @escaping ProgressHandler
    ) async throws -> LanguageOption {
        guard request.shouldAutoDetectLanguage else { return request.fallbackSource }
        try token.check()
        await reportProgress(AppText.offlineVideoDetectingLanguage(request.videoURL.lastPathComponent))
        if let detection = try await LocalWhisperRunner.detectLanguageWithTranscript(
            audioFileURL: audioURL,
            token: token
        ) {
            await reportProgress(AppText.offlineVideoDetectedLanguage(detection.language.localizedTitle))
            return detection.language
        }
        await reportProgress(AppText.offlineVideoDetectedLanguage(LanguageOption.undetermined.localizedTitle))
        return .undetermined
    }

    private func transcribe(
        audioURL: URL,
        videoURL: URL,
        language: LanguageOption,
        token: ProcessCancellationToken,
        reportProgress: @escaping ProgressHandler
    ) async throws -> TranscriptionResult {
        try token.check()
        await reportProgress(AppText.offlineVideoTranscribing(videoURL.lastPathComponent))
        let primaryText = try await transcribeWithWhisper(
            audioURL: audioURL,
            language: language,
            token: token,
            beamSize: 5
        )
        guard !primaryText.isEmpty else {
            throw LocalWhisperError.transcriptionFailed("Whisper returned empty text.")
        }

        if SpeechTranscriptValidator.hasEffectiveSpeechTranscript(primaryText, language: language)
            || language.id != "ms-MY" {
            return TranscriptionResult(
                sourceText: primaryText,
                sourceDescription: AppText.localWhisperSource
            )
        }

        await reportProgress(AppText.malayWhisperRetrying(videoURL.lastPathComponent))
        do {
            let fallbackText = try await transcribeWithWhisper(
                audioURL: audioURL,
                language: language,
                token: token,
                beamSize: 1
            )
            if !fallbackText.isEmpty,
               SpeechTranscriptValidator.hasEffectiveSpeechTranscript(fallbackText, language: language) {
                return TranscriptionResult(
                    sourceText: fallbackText,
                    sourceDescription: AppText.malayGreedyWhisperSource
                )
            }
        } catch ProcessSupervisorError.cancelled {
            throw ProcessSupervisorError.cancelled
        } catch ProcessSupervisorError.deadlineExceeded {
            throw ProcessSupervisorError.deadlineExceeded
        } catch ProcessSupervisorError.processTimedOut {
            throw ProcessSupervisorError.processTimedOut
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 备用解码失败时保留首次结果，让统一的无口播兜底流程继续处理。
        }

        return TranscriptionResult(
            sourceText: primaryText,
            sourceDescription: AppText.localWhisperSource
        )
    }

    private func transcribeWithWhisper(
        audioURL: URL,
        language: LanguageOption,
        token: ProcessCancellationToken,
        beamSize: Int
    ) async throws -> String {
        let rawTranscript = try await LocalWhisperRunner.transcribe(
            audioFileURL: audioURL,
            language: language,
            token: token,
            beamSize: beamSize
        )
        return TranscriptTextProcessor.organizeTranscript(rawTranscript, languageID: language.id)
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
                sourceLanguage: nil,
                sourceDescription: AppText.originalDescription,
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
                sourceLanguage: nil,
                sourceDescription: AppText.originalDescription,
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
                sourceLanguage: nil,
                sourceDescription: AppText.originalDescription,
                productContext: request.initialProductContext,
                artifactKind: .visualGeneratedCopy,
                frameData: frames
            )
        } catch let error as LLMTranslationError where error.allowsVisionFallback {
            return OfflineTranslationRunResult(
                sourceText: sourceText,
                translatedText: AppText.noEffectiveSpeechDescription,
                sourceLanguage: nil,
                sourceDescription: AppText.originalDescription,
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
        try token.check()
        return seconds
    }

    private static func durationText(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds.rounded()) / 60, Int(seconds.rounded()) % 60)
    }

    private struct TranscriptionResult: Sendable {
        let sourceText: String
        let sourceDescription: String
    }
}
