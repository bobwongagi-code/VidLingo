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
    let allowsCloudThaiTranscription: Bool
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
    let elevenLabsAPIKeyAvailability: KeychainAvailability?
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
        var thaiDiagnostics: ThaiTranscriptionDiagnostics?
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
                thai: thaiDiagnostics,
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
                request: request,
                token: token,
                reportProgress: reportProgress
            )
            recordStage("transcription", startedAt: transcriptionStartedAt)
            thaiDiagnostics = transcription.diagnostics

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
                frameData: [],
                elevenLabsAPIKeyAvailability: transcription.elevenLabsAPIKeyAvailability
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
        request: OfflineTranslationRunRequest,
        token: ProcessCancellationToken,
        reportProgress: @escaping ProgressHandler
    ) async throws -> TranscriptionResult {
        try token.check()
        await reportProgress(AppText.offlineVideoTranscribing(videoURL.lastPathComponent))
        guard language.id == "th-TH" else {
            let rawTranscript = try await LocalWhisperRunner.transcribe(
                audioFileURL: audioURL,
                language: language,
                token: token
            )
            let sourceText = TranscriptTextProcessor.organizeTranscript(rawTranscript, languageID: language.id)
            guard !sourceText.isEmpty else {
                throw LocalWhisperError.transcriptionFailed("Whisper returned empty text.")
            }
            return TranscriptionResult(
                sourceText: sourceText,
                sourceDescription: AppText.localWhisperSource,
                diagnostics: nil,
                elevenLabsAPIKeyAvailability: nil
            )
        }

        await reportProgress(AppText.thaiDualWhisperTranscribing(videoURL.lastPathComponent))
        let candidates = try await LocalWhisperRunner.transcribeThaiCandidates(audioFileURL: audioURL, token: token)
        let assessment = TranscriptionQualityEvaluator.assess(candidates)
        let localText = TranscriptTextProcessor.organizeTranscript(assessment.selectedText, languageID: language.id)
        let localDescription = localDescription(for: assessment)
        let localDiagnostics = ThaiTranscriptionDiagnostics(
            qualityPolicyVersion: TranscriptionQualityEvaluator.policyVersion,
            segmentCount: assessment.segments.count,
            generalReviewSegmentIndexes: assessment.generalReviewSegmentIndexes,
            usedFullGeneralReview: assessment.usedFullGeneralReview,
            cloudReasons: assessment.cloudReasons,
            usedElevenLabs: false
        )

        guard assessment.shouldUseCloud else {
            return TranscriptionResult(
                sourceText: localText,
                sourceDescription: localDescription,
                diagnostics: localDiagnostics,
                elevenLabsAPIKeyAvailability: nil
            )
        }
        guard request.allowsCloudThaiTranscription else {
            return TranscriptionResult(
                sourceText: localText,
                sourceDescription: AppText.localWhisperCloudDisabled(localDescription),
                diagnostics: localDiagnostics,
                elevenLabsAPIKeyAvailability: nil
            )
        }

        let apiKey: String?
        let availability: KeychainAvailability
        do {
            apiKey = try ElevenLabsAPIKeyStore.readAPIKey()
            availability = apiKey?.isEmpty == false ? .configured : .missing
        } catch let error as ElevenLabsAPIKeyStoreError {
            return TranscriptionResult(
                sourceText: localText,
                sourceDescription: AppText.localWhisperCloudUnavailable(
                    localDescription,
                    reason: AppText.keychainAvailabilityText(error.availability)
                ),
                diagnostics: localDiagnostics,
                elevenLabsAPIKeyAvailability: error.availability
            )
        } catch {
            return TranscriptionResult(
                sourceText: localText,
                sourceDescription: AppText.localWhisperCloudUnavailable(
                    localDescription,
                    reason: AppText.keychainAvailabilityText(.corrupted)
                ),
                diagnostics: localDiagnostics,
                elevenLabsAPIKeyAvailability: .corrupted
            )
        }
        guard let apiKey, !apiKey.isEmpty else {
            return TranscriptionResult(
                sourceText: localText,
                sourceDescription: AppText.localWhisperCloudUnavailable(
                    localDescription,
                    reason: AppText.elevenLabsAPIKeyNotConfigured
                ),
                diagnostics: localDiagnostics,
                elevenLabsAPIKeyAvailability: availability
            )
        }

        let duration = await Self.audioDurationSeconds(for: audioURL)
        guard duration > 0 else {
            return TranscriptionResult(
                sourceText: localText,
                sourceDescription: AppText.localWhisperCloudUnavailable(
                    localDescription,
                    reason: AppText.elevenLabsDurationUnavailable
                ),
                diagnostics: localDiagnostics,
                elevenLabsAPIKeyAvailability: availability
            )
        }

        let estimatedCredits = ElevenLabsTranscriber.estimatedCredits(duration: duration)
        do {
            let quota = try await ElevenLabsTranscriber.quota(apiKey: apiKey, token: token)
            guard quota.remainingCredits >= estimatedCredits else {
                return TranscriptionResult(
                    sourceText: localText,
                    sourceDescription: AppText.localWhisperCloudUnavailable(
                        localDescription,
                        reason: AppText.elevenLabsQuotaInsufficient(
                            remaining: quota.remainingCredits,
                            required: estimatedCredits
                        )
                    ),
                    diagnostics: localDiagnostics,
                    elevenLabsAPIKeyAvailability: availability
                )
            }
            await reportProgress(AppText.elevenLabsReviewing(videoURL.lastPathComponent))
            let cloudTranscript = try await ElevenLabsTranscriber.transcribeThai(
                audioURL: audioURL,
                apiKey: apiKey,
                token: token
            )
            let cloudText = TranscriptTextProcessor.organizeTranscript(cloudTranscript.text, languageID: language.id)
            guard ElevenLabsTranscriber.isTrustedTeacher(cloudTranscript), !cloudText.isEmpty else {
                return TranscriptionResult(
                    sourceText: localText,
                    sourceDescription: AppText.localWhisperCloudUnavailable(
                        localDescription,
                        reason: AppText.elevenLabsQualityRejected
                    ),
                    diagnostics: localDiagnostics,
                    elevenLabsAPIKeyAvailability: availability
                )
            }
            return TranscriptionResult(
                sourceText: cloudText,
                sourceDescription: AppText.elevenLabsSource(reasons: assessment.cloudReasons),
                diagnostics: ThaiTranscriptionDiagnostics(
                    qualityPolicyVersion: TranscriptionQualityEvaluator.policyVersion,
                    segmentCount: localDiagnostics.segmentCount,
                    generalReviewSegmentIndexes: localDiagnostics.generalReviewSegmentIndexes,
                    usedFullGeneralReview: localDiagnostics.usedFullGeneralReview,
                    cloudReasons: localDiagnostics.cloudReasons,
                    usedElevenLabs: true
                ),
                elevenLabsAPIKeyAvailability: availability
            )
        } catch ProcessSupervisorError.cancelled {
            throw ProcessSupervisorError.cancelled
        } catch ProcessSupervisorError.deadlineExceeded {
            throw ProcessSupervisorError.deadlineExceeded
        } catch ProcessSupervisorError.processTimedOut {
            throw ProcessSupervisorError.processTimedOut
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return TranscriptionResult(
                sourceText: localText,
                sourceDescription: AppText.localWhisperCloudUnavailable(
                    localDescription,
                    reason: error.localizedDescription
                ),
                diagnostics: localDiagnostics,
                elevenLabsAPIKeyAvailability: availability
            )
        }
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
                frameData: [],
                elevenLabsAPIKeyAvailability: nil
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
                frameData: [],
                elevenLabsAPIKeyAvailability: nil
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
                frameData: frames,
                elevenLabsAPIKeyAvailability: nil
            )
        } catch let error as LLMTranslationError where error.allowsVisionFallback {
            return OfflineTranslationRunResult(
                sourceText: sourceText,
                translatedText: AppText.noEffectiveSpeechDescription,
                sourceLanguage: nil,
                sourceDescription: AppText.originalDescription,
                productContext: request.initialProductContext,
                artifactKind: nil,
                frameData: [],
                elevenLabsAPIKeyAvailability: nil
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

    private func localDescription(for assessment: LocalTranscriptionAssessment) -> String {
        let profiles = assessment.segments.compactMap(\.selectedProfile)
        return AppText.thaiLocalWhisperSource(
            specialistSegments: profiles.filter { $0 == .thaiSpecialistGreedy }.count,
            generalSegments: profiles.filter { $0 == .generalBeam }.count
        )
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

    private static func audioDurationSeconds(for audioURL: URL) async -> Double {
        let asset = AVURLAsset(url: audioURL)
        let duration = try? await withTaskCancellationHandler {
            try await AsyncOperationTimeout.run(timeout: 15) {
                try await asset.load(.duration)
            }
        } onCancel: {
            asset.cancelLoading()
        }
        let seconds = duration.map(CMTimeGetSeconds) ?? 0
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    private static func durationText(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds.rounded()) / 60, Int(seconds.rounded()) % 60)
    }

    private struct TranscriptionResult: Sendable {
        let sourceText: String
        let sourceDescription: String
        let diagnostics: ThaiTranscriptionDiagnostics?
        let elevenLabsAPIKeyAvailability: KeychainAvailability?
    }
}
