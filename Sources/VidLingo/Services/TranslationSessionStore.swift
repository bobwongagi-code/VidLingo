import AVFoundation
import AppKit
import Foundation
import Observation
import VidLingoCore

private enum SettingsKey {
    static let sourceLanguageID = "sourceLanguageID"
    static let isSourceAutoDetectionEnabled = "isSourceAutoDetectionEnabled"
    static let allowsCloudAudioTranscription = "allowsCloudAudioTranscription"
    static let allowsCloudVideoFrames = "allowsCloudVideoFrames"
    static let allowsVisualSalesCopy = "allowsVisualSalesCopy"
    static let translationProviderID = "translationProviderID"
    static let customTranslationBaseURL = "customTranslationBaseURL"

    static func translationModelName(provider: TranslationProviderID) -> String {
        "translationModelName.\(provider.rawValue)"
    }
}

@Observable
@MainActor
final class TranslationSessionStore {
    var sourceLanguage = LanguageOption.english {
        didSet { persistSelectedSettings() }
    }
    var targetLanguage = LanguageOption(id: "zh-CN", title: "Chinese Simplified", locale: Locale(identifier: "zh-CN")) {
        didSet { persistSelectedSettings() }
    }
    var isSourceAutoDetectionEnabled = true {
        didSet { persistSelectedSettings() }
    }
    var translationProvider = TranslationProviderID.rootify {
        didSet {
            guard !isRestoringSelectedSettings else { return }
            translationModelName = storedTranslationModelName(for: translationProvider)
            refreshAPIKeyAvailabilities()
            persistSelectedSettings()
        }
    }
    var translationModelName = TranslationProviderID.rootify.defaultModel {
        didSet { persistTranslationModelName() }
    }
    var customTranslationBaseURL = "" {
        didSet { persistSelectedSettings() }
    }
    private var translationAPIKeyState = APIKeyAvailabilityState()
    var translationAPIKeyAvailability: KeychainAvailability {
        get { translationAPIKeyState.value }
        set { translationAPIKeyState.set(newValue) }
    }
    var hasTranslationAPIKey: Bool { translationAPIKeyAvailability == .configured }
    private var funASRAPIKeyState = APIKeyAvailabilityState()
    var funASRAPIKeyAvailability: KeychainAvailability {
        get { funASRAPIKeyState.value }
        set { funASRAPIKeyState.set(newValue) }
    }
    var hasFunASRAPIKey: Bool { funASRAPIKeyAvailability == .configured }
    var allowsCloudAudioTranscription = false {
        didSet { persistSelectedSettings() }
    }
    var allowsCloudVideoFrames = false {
        didSet { persistSelectedSettings() }
    }
    var allowsVisualSalesCopy = false {
        didSet { persistSelectedSettings() }
    }
    var statusMessage = AppText.ready
    var transcriptionSourceDescription = AppText.originalDescription
    var lines: [CaptionLine] = []
    var timedSegments: [TimedTranscriptSegment] = []
    var offlineVideoProductContext = ""
    var offlineVideoURL: URL?
    var offlineVideoFileName = ""
    var offlineVideoDurationText = ""
    var isOfflineVideoProcessing = false
    var isProductContextInferenceEnabled = true
    var savedTranscripts: [SavedTranscript] = []
    var selectedSavedTranscriptID: String?
    var savedDraftSourceText = ""
    var savedDraftTranslationText = ""

    var offlineVideoExecutionPlan: String {
        var steps = ["本地提取音频"]
        if allowsCloudAudioTranscription {
            steps.append("上传口播音频到 Fun-ASR \(FunASRTranscriber.modelName) 完整转写，按词级时间戳在本地分段（1 次云端调用，可能产生费用）")
        } else {
            steps.append("等待允许上传音频到 Fun-ASR")
        }
        if isSourceAutoDetectionEnabled {
            steps.append("根据转写文本自动识别口播语言")
        }
        let supportsVision = LLMTranslationService.supportsProductContextFrames(
            provider: translationProvider,
            modelName: translationModelName
        )
        if allowsCloudVideoFrames && supportsVision {
            steps.append("上传视频截图到 \(translationProvider.title) \(translationModelName) 做商品识别（1 次视觉调用，可能产生费用）")
        }
        if allowsVisualSalesCopy && allowsCloudVideoFrames && supportsVision {
            steps.append("无口播时，再用同一组截图调用视觉模型分析并生成文案（2 次视觉调用，可能产生费用）")
        }
        steps.append("调用 \(translationProvider.title) \(translationModelName) 翻译为简体中文（1 次云端调用，可能产生费用）")
        return steps.joined(separator: "；")
    }

    var offlineTranslationConfigurationWarning: String? {
        guard funASRAPIKeyAvailability == .configured else {
            return AppText.funASRKeyConfigurationWarning(funASRAPIKeyAvailability)
        }
        guard allowsCloudAudioTranscription else {
            return AppText.cloudAudioConsentRequired
        }
        guard translationAPIKeyAvailability == .configured else {
            return AppText.keychainAvailabilityText(translationAPIKeyAvailability)
        }
        guard !translationModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return AppText.translationModelMissing
        }
        if translationProvider == .custom {
            let allowLocalHTTP = ProcessInfo.processInfo.environment["VIDLINGO_ALLOW_LOCAL_HTTP"] == "1"
            if (try? EndpointValidator.validate(customTranslationBaseURL, allowLoopbackHTTP: allowLocalHTTP)) == nil {
                return AppText.translationEndpointInvalid
            }
        }
        return nil
    }

    var canStartOfflineVideoTranslation: Bool {
        offlineVideoURL != nil && !isOfflineVideoProcessing && offlineTranslationConfigurationWarning == nil
    }

    private var isRestoringSelectedSettings = false
    private var processingTask: Task<Void, Never>?
    private var processingToken: ProcessCancellationToken?
    private let transcriptRepository: TranscriptRepository

    init() {
        transcriptRepository = TranscriptRepository()
        restoreSelectedSettings()
        loadSavedTranscripts()
        refreshAPIKeyAvailabilities()
    }

    init(transcriptRepository: TranscriptRepository) {
        self.transcriptRepository = transcriptRepository
        loadSavedTranscripts()
    }

    func selectOfflineVideo(_ videoURL: URL) {
        lines.removeAll()
        timedSegments.removeAll()
        transcriptionSourceDescription = AppText.originalDescription
        offlineVideoProductContext = ""
        offlineVideoURL = videoURL
        offlineVideoFileName = videoURL.lastPathComponent
        offlineVideoDurationText = ""
        statusMessage = AppText.confirmVideoContent

        Task { @MainActor in
            offlineVideoDurationText = await OfflineTranslationCoordinator.formattedVideoDuration(for: videoURL)
        }
    }

    func startOfflineVideoTranslation() {
        guard let offlineVideoURL else { return }
        guard canStartOfflineVideoTranslation else {
            statusMessage = offlineTranslationConfigurationWarning ?? AppText.translationInvalidResponse
            return
        }
        translateOfflineShortVideo(offlineVideoURL)
    }

    func cancelOfflineVideoTranslation() {
        guard isOfflineVideoProcessing else { return }
        processingToken?.cancel()
        processingTask?.cancel()
        statusMessage = AppText.offlineVideoCancelled
    }

    func translateOfflineShortVideo(_ videoURL: URL) {
        guard !isOfflineVideoProcessing else { return }
        guard offlineTranslationConfigurationWarning == nil else {
            statusMessage = offlineTranslationConfigurationWarning ?? AppText.translationInvalidResponse
            return
        }

        // 快照当前设置，避免任务运行中用户改动影响结果。
        let params = TranslationParams(
            fallbackSource: sourceLanguage,
            target: targetLanguage,
            initialProductContext: offlineVideoProductContext,
            provider: translationProvider,
            modelName: translationModelName,
            customBaseURL: customTranslationBaseURL,
            shouldAutoDetectLanguage: isSourceAutoDetectionEnabled,
            shouldInferProductContext: isProductContextInferenceEnabled,
            allowsCloudAudioTranscription: allowsCloudAudioTranscription,
            allowsCloudVideoFrames: allowsCloudVideoFrames,
            allowsVisualSalesCopy: allowsVisualSalesCopy
        )
        let token = ProcessCancellationToken(timeout: MediaProcessingLimits.totalTaskTimeout)
        processingToken = token
        let didAccess = videoURL.startAccessingSecurityScopedResource()

        offlineVideoURL = videoURL
        offlineVideoFileName = videoURL.lastPathComponent
        isOfflineVideoProcessing = true
        lines.removeAll()
        timedSegments.removeAll()
        transcriptionSourceDescription = AppText.originalDescription
        statusMessage = AppText.offlineVideoExtractingAudio(videoURL.lastPathComponent)

        let task = Task { @MainActor in
            defer {
                if didAccess { videoURL.stopAccessingSecurityScopedResource() }
                isOfflineVideoProcessing = false
                processingToken = nil
                processingTask = nil
            }

            do {
                offlineVideoDurationText = await OfflineTranslationCoordinator.formattedVideoDuration(for: videoURL)
                let result = try await OfflineTranslationCoordinator().run(
                    request: OfflineTranslationRunRequest(
                        videoURL: videoURL,
                        fallbackSource: params.fallbackSource,
                        target: params.target,
                        initialProductContext: params.initialProductContext,
                        provider: params.provider,
                        modelName: params.modelName,
                        customBaseURL: params.customBaseURL,
                        shouldAutoDetectLanguage: params.shouldAutoDetectLanguage,
                        shouldInferProductContext: params.shouldInferProductContext,
                        allowsCloudAudioTranscription: params.allowsCloudAudioTranscription,
                        allowsCloudVideoFrames: params.allowsCloudVideoFrames,
                        allowsVisualSalesCopy: params.allowsVisualSalesCopy
                    ),
                    token: token,
                    reportProgress: { message in
                        await MainActor.run {
                            self.statusMessage = message
                        }
                    }
                )
                transcriptionSourceDescription = result.sourceDescription
                if !result.productContext.isEmpty {
                    offlineVideoProductContext = result.productContext
                }
                try token.check()
                timedSegments = result.timedSegments
                lines = [CaptionLine(
                    sourceText: result.sourceText,
                    translatedText: result.translatedText,
                    translatedSourceText: result.sourceText,
                    createdAt: Date(),
                    isFinal: true,
                    revision: 2
                )]
                if let kind = result.artifactKind {
                    try saveOfflineVideoTranscript(
                        sourceText: result.sourceText,
                        translatedText: result.translatedText,
                        sourceLanguage: result.sourceLanguage,
                        params: params,
                        kind: kind,
                        frameData: result.frameData,
                        videoFileName: videoURL.lastPathComponent,
                        timedSegments: result.timedSegments
                    )
                }
                statusMessage = AppText.offlineVideoComplete(videoURL.lastPathComponent)
            } catch ProcessSupervisorError.cancelled {
                statusMessage = AppText.offlineVideoCancelled
            } catch is CancellationError {
                statusMessage = AppText.offlineVideoCancelled
            } catch ProcessSupervisorError.deadlineExceeded {
                statusMessage = AppText.offlineVideoFailed(ProcessSupervisorError.deadlineExceeded.localizedDescription)
            } catch {
                statusMessage = AppText.offlineVideoFailed(sanitizedErrorDescription(error))
            }
        }
        processingTask = task
    }

    // MARK: - Pipeline 参数快照

    private struct TranslationParams {
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

    func clearProductContext() {
        guard !isOfflineVideoProcessing else { return }
        offlineVideoProductContext = ""
    }

    func saveTranslationAPIKey(_ key: String) {
        do {
            try TranslationAPIKeyStore.saveAPIKey(key, for: translationProvider)
            translationAPIKeyAvailability = .configured
            statusMessage = AppText.translationAPIKeySaved(translationProvider.title)
        } catch let error as TranslationAPIKeyStoreError {
            translationAPIKeyAvailability = error.availability
            statusMessage = error.localizedDescription
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func removeTranslationAPIKey() {
        do {
            try TranslationAPIKeyStore.deleteAPIKey(for: translationProvider)
            translationAPIKeyAvailability = .missing
            statusMessage = AppText.translationAPIKeyRemoved(translationProvider.title)
        } catch let error as TranslationAPIKeyStoreError {
            translationAPIKeyAvailability = error.availability
            statusMessage = error.localizedDescription
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func saveFunASRAPIKey(_ key: String) {
        do {
            try TranslationAPIKeyStore.saveAPIKey(key, service: FunASRConfiguration.keychainService)
            funASRAPIKeyAvailability = .configured
            statusMessage = AppText.translationAPIKeySaved("Fun-ASR")
        } catch let error as TranslationAPIKeyStoreError {
            funASRAPIKeyAvailability = error.availability
            statusMessage = error.localizedDescription
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func removeFunASRAPIKey() {
        do {
            try TranslationAPIKeyStore.deleteAPIKey(service: FunASRConfiguration.keychainService)
            funASRAPIKeyAvailability = .missing
            statusMessage = AppText.translationAPIKeyRemoved("Fun-ASR")
        } catch let error as TranslationAPIKeyStoreError {
            funASRAPIKeyAvailability = error.availability
            statusMessage = error.localizedDescription
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func openTranscriptsFolder() {
        do {
            try FileManager.default.createDirectory(
                at: transcriptRepository.currentDirectoryURL,
                withIntermediateDirectories: true
            )
            NSWorkspace.shared.open(transcriptRepository.currentDirectoryURL)
        } catch {
            statusMessage = AppText.saveLibraryFailed(error.localizedDescription)
        }
    }

    func clearDiagnostics() {
        do {
            try OfflineTranslationDiagnostics.clear()
            statusMessage = AppText.diagnosticsCleared
        } catch {
            statusMessage = AppText.diagnosticsClearFailed(error.localizedDescription)
        }
    }

    @discardableResult
    func loadSavedTranscripts(selecting transcriptID: String? = nil) -> Bool {
        if let transcriptID {
            selectedSavedTranscriptID = transcriptID
        }
        do {
            try reloadSavedTranscripts()
            if let transcriptID,
               savedTranscripts.contains(where: { $0.id == transcriptID }) {
                selectSavedTranscript(transcriptID)
            }
            return true
        } catch {
            statusMessage = AppText.saveLibraryFailed(error.localizedDescription)
            return false
        }
    }

    var selectedSavedTranscript: SavedTranscript? {
        guard let selectedSavedTranscriptID else { return nil }
        return savedTranscripts.first { $0.id == selectedSavedTranscriptID }
    }

    func selectSavedTranscript(_ id: String) {
        guard let transcript = savedTranscripts.first(where: { $0.id == id }) else { return }
        selectedSavedTranscriptID = id
        savedDraftSourceText = transcript.sourceText
        savedDraftTranslationText = transcript.translatedText ?? ""
    }

    func saveSelectedTranscriptEdits() {
        guard let selectedTranscript = selectedSavedTranscript else { return }
        var publishedRecordID: String?
        do {
            publishedRecordID = try transcriptRepository.saveEdits(
                for: selectedTranscript,
                sourceText: savedDraftSourceText,
                translatedText: savedDraftTranslationText
            )
            statusMessage = AppText.savedEdits
        } catch let error as TranscriptRepositoryError {
            if case let .savedButRetirementFailed(recordID, _) = error {
                publishedRecordID = recordID
                statusMessage = error.localizedDescription
            } else {
                statusMessage = AppText.saveLibraryFailed(error.localizedDescription)
            }
        } catch {
            statusMessage = AppText.saveLibraryFailed(error.localizedDescription)
        }
        _ = loadSavedTranscripts(selecting: publishedRecordID)
    }

    func deleteSelectedTranscript() {
        guard let selectedTranscript = selectedSavedTranscript else { return }
        do {
            try transcriptRepository.delete(selectedTranscript)
            statusMessage = AppText.deletedSavedTranscript
            selectedSavedTranscriptID = nil
            savedDraftSourceText = ""
            savedDraftTranslationText = ""
        } catch {
            statusMessage = AppText.saveLibraryFailed(error.localizedDescription)
        }
        _ = loadSavedTranscripts()
    }

    func deleteAllSavedTranscripts() {
        let result = transcriptRepository.deleteAllCurrent(savedTranscripts)
        selectedSavedTranscriptID = nil
        savedDraftSourceText = ""
        savedDraftTranslationText = ""
        guard loadSavedTranscripts() else { return }
        statusMessage = result.failedIDs.isEmpty
            ? AppText.deletedCurrentTranscripts
            : AppText.deleteSomeTranscriptsFailed(result.failedIDs.count)
    }

    @discardableResult
    private func saveOfflineVideoTranscript(
        sourceText: String,
        translatedText: String,
        sourceLanguage: LanguageOption?,
        params: TranslationParams,
        kind: TranscriptArtifactKind,
        frameData: [Data] = [],
        videoFileName: String,
        timedSegments: [TimedTranscriptSegment] = []
    ) throws -> PublishedTranscriptArtifact {
        let artifact = try transcriptRepository.publish(
            sourceText: sourceText,
            translatedText: translatedText,
            sourceLanguage: sourceLanguage,
            targetLanguage: params.target,
            provider: params.provider,
            modelName: params.modelName,
            videoFileName: videoFileName,
            kind: kind,
            frameData: frameData,
            timedSegments: timedSegments
        )
        try reloadSavedTranscripts()
        return artifact
    }

    private func reloadSavedTranscripts() throws {
        savedTranscripts = try transcriptRepository.load()
    }

    private func sanitizedErrorDescription(_ error: Error) -> String {
        OfflineTranslationDiagnostics.sanitizedErrorDescription(error.localizedDescription)
    }

    private func restoreSelectedSettings() {
        isRestoringSelectedSettings = true
        defer { isRestoringSelectedSettings = false }

        let defaults = UserDefaults.standard
        if let sourceLanguageID = defaults.string(forKey: SettingsKey.sourceLanguageID),
           let language = LanguageOption.supported.first(where: { $0.id == sourceLanguageID }) {
            sourceLanguage = language
        }
        targetLanguage = LanguageOption.supported.first(where: { $0.id == "zh-CN" })
            ?? LanguageOption(id: "zh-CN", title: "Chinese Simplified", locale: Locale(identifier: "zh-CN"))
        if defaults.object(forKey: SettingsKey.isSourceAutoDetectionEnabled) != nil {
            isSourceAutoDetectionEnabled = defaults.bool(forKey: SettingsKey.isSourceAutoDetectionEnabled)
        }
        allowsCloudAudioTranscription = defaults.bool(forKey: SettingsKey.allowsCloudAudioTranscription)
        allowsCloudVideoFrames = defaults.bool(forKey: SettingsKey.allowsCloudVideoFrames)
        allowsVisualSalesCopy = defaults.bool(forKey: SettingsKey.allowsVisualSalesCopy)
        if let providerID = defaults.string(forKey: SettingsKey.translationProviderID),
           let provider = TranslationProviderID(rawValue: providerID) {
            translationProvider = provider
        }
        let storedCustomEndpoint = defaults.string(forKey: SettingsKey.customTranslationBaseURL) ?? ""
        let allowLocalHTTP = ProcessInfo.processInfo.environment["VIDLINGO_ALLOW_LOCAL_HTTP"] == "1"
        customTranslationBaseURL = (try? EndpointValidator.validate(
            storedCustomEndpoint,
            allowLoopbackHTTP: allowLocalHTTP
        ).url.absoluteString) ?? ""
        translationModelName = storedTranslationModelName(for: translationProvider)
    }

    private func refreshAPIKeyAvailabilities() {
        let provider = translationProvider
        let translationRevision = translationAPIKeyState.beginRefresh(reset: true)
        let funASRRevision = funASRAPIKeyState.beginRefresh(reset: false)
        Task { @MainActor [weak self] in
            let availabilities = await Task.detached(priority: .utility) {
                (
                    TranslationAPIKeyStore.availability(for: provider),
                    TranslationAPIKeyStore.availability(service: FunASRConfiguration.keychainService)
                )
            }.value
            guard let self, self.translationProvider == provider else { return }
            self.translationAPIKeyState.apply(availabilities.0, revision: translationRevision)
            self.funASRAPIKeyState.apply(availabilities.1, revision: funASRRevision)
        }
    }

    private func persistSelectedSettings() {
        guard !isRestoringSelectedSettings else { return }
        let defaults = UserDefaults.standard
        defaults.set(sourceLanguage.id, forKey: SettingsKey.sourceLanguageID)
        defaults.set(isSourceAutoDetectionEnabled, forKey: SettingsKey.isSourceAutoDetectionEnabled)
        defaults.set(allowsCloudAudioTranscription, forKey: SettingsKey.allowsCloudAudioTranscription)
        defaults.set(allowsCloudVideoFrames, forKey: SettingsKey.allowsCloudVideoFrames)
        defaults.set(allowsVisualSalesCopy, forKey: SettingsKey.allowsVisualSalesCopy)
        defaults.set(translationProvider.rawValue, forKey: SettingsKey.translationProviderID)
        let allowLocalHTTP = ProcessInfo.processInfo.environment["VIDLINGO_ALLOW_LOCAL_HTTP"] == "1"
        let persistedCustomEndpoint = (try? EndpointValidator.validate(
            customTranslationBaseURL,
            allowLoopbackHTTP: allowLocalHTTP
        ).url.absoluteString) ?? ""
        defaults.set(persistedCustomEndpoint, forKey: SettingsKey.customTranslationBaseURL)
    }

    private func persistTranslationModelName() {
        guard !isRestoringSelectedSettings else { return }
        UserDefaults.standard.set(
            translationModelName,
            forKey: SettingsKey.translationModelName(provider: translationProvider)
        )
    }

    private func storedTranslationModelName(for provider: TranslationProviderID) -> String {
        let storedModel = UserDefaults.standard.string(forKey: SettingsKey.translationModelName(provider: provider))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return storedModel.isEmpty ? provider.defaultModel : storedModel
    }
}
