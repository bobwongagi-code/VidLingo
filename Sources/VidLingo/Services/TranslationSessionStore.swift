import AVFoundation
import AppKit
import Foundation
import Observation
import VidLingoCore

private enum SettingsKey {
    static let sourceLanguageID = "sourceLanguageID"
    static let targetLanguageID = "targetLanguageID"
    static let isSourceAutoDetectionEnabled = "isSourceAutoDetectionEnabled"
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
    var translationProvider = TranslationProviderID.deepSeek {
        didSet {
            guard !isRestoringSelectedSettings else { return }
            translationModelName = storedTranslationModelName(for: translationProvider)
            hasTranslationAPIKey = TranslationAPIKeyStore.hasAPIKey(for: translationProvider)
            persistSelectedSettings()
        }
    }
    var translationModelName = TranslationProviderID.deepSeek.defaultModel {
        didSet { persistTranslationModelName() }
    }
    var customTranslationBaseURL = "" {
        didSet { persistSelectedSettings() }
    }
    var hasTranslationAPIKey = TranslationAPIKeyStore.hasAPIKey(for: .deepSeek)
    var statusMessage = AppText.ready
    var lines: [CaptionLine] = []
    var offlineVideoProductContext = ""
    var offlineVideoURL: URL?
    var offlineVideoFileName = ""
    var offlineVideoDurationText = ""
    var isOfflineVideoProcessing = false
    var isProductContextInferenceEnabled = true
    var savedTranscriptContentMode = SavedTranscriptContentMode.originalAndTranslation
    var savedTranscripts: [SavedTranscript] = []
    var selectedSavedTranscriptID: String?
    var savedDraftSourceText = ""
    var savedDraftTranslationText = ""

    private var isRestoringSelectedSettings = false

    init() {
        restoreSelectedSettings()
        loadSavedTranscripts()
    }

    func selectOfflineVideo(_ videoURL: URL) {
        lines.removeAll()
        offlineVideoProductContext = ""
        offlineVideoURL = videoURL
        offlineVideoFileName = videoURL.lastPathComponent
        offlineVideoDurationText = ""
        statusMessage = AppText.confirmVideoContent

        Task { @MainActor in
            offlineVideoDurationText = await Self.formattedVideoDuration(for: videoURL)
        }
    }

    func startOfflineVideoTranslation() {
        guard let offlineVideoURL else { return }
        translateOfflineShortVideo(offlineVideoURL)
    }

    func translateOfflineShortVideo(_ videoURL: URL) {
        guard !isOfflineVideoProcessing else { return }

        let fallbackSource = sourceLanguage
        let target = targetLanguage
        let initialProductContext = offlineVideoProductContext
        let provider = translationProvider
        let modelName = translationModelName
        let customBaseURL = customTranslationBaseURL
        let shouldAutoDetectLanguage = isSourceAutoDetectionEnabled
        let shouldInferProductContext = isProductContextInferenceEnabled
        let didAccess = videoURL.startAccessingSecurityScopedResource()

        offlineVideoURL = videoURL
        offlineVideoFileName = videoURL.lastPathComponent
        isOfflineVideoProcessing = true
        lines.removeAll()
        statusMessage = AppText.offlineVideoExtractingAudio(videoURL.lastPathComponent)

        Task { @MainActor in
            offlineVideoDurationText = await Self.formattedVideoDuration(for: videoURL)

            var audioURL: URL?
            defer {
                if let audioURL {
                    OfflineVideoAudioExtractor.removeTemporaryAudio(audioURL)
                }
                if didAccess {
                    videoURL.stopAccessingSecurityScopedResource()
                }
                isOfflineVideoProcessing = false
            }

            do {
                audioURL = try await OfflineVideoAudioExtractor.extractSpeechAudio(from: videoURL)
                guard let audioURL else { return }

                var transcriptSource = fallbackSource
                if shouldAutoDetectLanguage {
                    statusMessage = AppText.offlineVideoDetectingLanguage(videoURL.lastPathComponent)
                    if let detection = try await LocalWhisperRunner.detectLanguageWithTranscript(audioFileURL: audioURL) {
                        transcriptSource = detection.language
                        sourceLanguage = detection.language
                        statusMessage = AppText.offlineVideoDetectedLanguage(detection.language.localizedTitle)
                    }
                }

                statusMessage = AppText.offlineVideoTranscribing(videoURL.lastPathComponent)
                let rawTranscript = try await LocalWhisperRunner.transcribe(
                    audioFileURL: audioURL,
                    language: transcriptSource
                )
                let sourceText = organizeTranscript(rawTranscript, language: transcriptSource)
                guard !sourceText.isEmpty else {
                    throw LocalWhisperError.transcriptionFailed("Whisper returned empty text.")
                }
                guard hasEffectiveSpeechTranscript(sourceText, language: transcriptSource) else {
                    let visualSourceText = AppText.noEffectiveSpeech
                    if LLMTranslationService.supportsProductContextFrames(provider: provider, modelName: modelName) {
                        statusMessage = AppText.generatingVisualSalesCopy(videoURL.lastPathComponent)
                        let frameJPEGData = await OfflineVideoFrameExtractor.extractProductContextFrames(from: videoURL)
                        if let visualCopy = try? await LLMTranslationService().generateVisualSalesCopy(
                            fileName: videoURL.lastPathComponent,
                            durationText: offlineVideoDurationText,
                            productContext: initialProductContext,
                            frameJPEGData: frameJPEGData,
                            provider: provider,
                            modelName: modelName,
                            customBaseURL: customBaseURL
                        ) {
                            let translatedText = "\(AppText.visualSalesCopyNotice)\n\n\(visualCopy)"
                            lines = [
                                CaptionLine(
                                    sourceText: visualSourceText,
                                    translatedText: translatedText,
                                    translatedSourceText: visualSourceText,
                                    createdAt: Date(),
                                    isFinal: true
                                )
                            ]
                            saveOfflineVideoTranscript(sourceText: visualSourceText, translatedText: translatedText)
                            statusMessage = AppText.offlineVideoComplete(videoURL.lastPathComponent)
                            return
                        }
                    }

                    lines = [
                        CaptionLine(
                            sourceText: visualSourceText,
                            translatedText: AppText.noEffectiveSpeechDescription,
                            translatedSourceText: visualSourceText,
                            createdAt: Date(),
                            isFinal: true
                        )
                    ]
                    statusMessage = AppText.noEffectiveSpeech
                    return
                }

                let createdAt = Date()
                lines = [
                    CaptionLine(
                        sourceText: sourceText,
                        translatedText: AppText.translating,
                        translatedSourceText: sourceText,
                        createdAt: createdAt,
                        isFinal: true,
                        revision: 1
                    )
                ]

                var productContext = initialProductContext.trimmingCharacters(in: .whitespacesAndNewlines)
                if shouldInferProductContext && productContext.isEmpty {
                    statusMessage = AppText.inferringProductContext(videoURL.lastPathComponent)
                    let frameJPEGData = if LLMTranslationService.supportsProductContextFrames(
                        provider: provider,
                        modelName: modelName
                    ) {
                        await OfflineVideoFrameExtractor.extractProductContextFrames(from: videoURL)
                    } else {
                        [Data]()
                    }
                    if let inferredContext = try? await LLMTranslationService().inferProductContext(
                        from: sourceText,
                        fileName: videoURL.lastPathComponent,
                        frameJPEGData: frameJPEGData,
                        source: transcriptSource,
                        provider: provider,
                        modelName: modelName,
                        customBaseURL: customBaseURL
                    ) {
                        if !inferredContext.isEmpty && inferredContext != AppText.unknownProductContext {
                            productContext = inferredContext
                            offlineVideoProductContext = inferredContext
                        }
                    }
                }

                statusMessage = AppText.offlineVideoTranslating(videoURL.lastPathComponent, provider: provider.title)
                let translatedText = try await LLMTranslationService().translateShortVideoTranscript(
                    sourceText,
                    source: transcriptSource,
                    target: target,
                    productContext: productContext,
                    provider: provider,
                    modelName: modelName,
                    customBaseURL: customBaseURL
                )

                lines = [
                    CaptionLine(
                        sourceText: sourceText,
                        translatedText: translatedText,
                        translatedSourceText: sourceText,
                        createdAt: createdAt,
                        isFinal: true,
                        revision: 2
                    )
                ]
                saveOfflineVideoTranscript(sourceText: sourceText, translatedText: translatedText)
                statusMessage = AppText.offlineVideoComplete(videoURL.lastPathComponent)
            } catch {
                statusMessage = AppText.offlineVideoFailed(error.localizedDescription)
                if lines.isEmpty {
                    lines = [
                        CaptionLine(
                            sourceText: videoURL.lastPathComponent,
                            translatedText: statusMessage,
                            translatedSourceText: videoURL.lastPathComponent,
                            createdAt: Date(),
                            isFinal: true
                        )
                    ]
                }
            }
        }
    }

    func clearProductContext() {
        guard !isOfflineVideoProcessing else { return }
        offlineVideoProductContext = ""
    }

    func saveTranslationAPIKey(_ key: String) {
        do {
            try TranslationAPIKeyStore.saveAPIKey(key, for: translationProvider)
            hasTranslationAPIKey = true
            statusMessage = AppText.translationAPIKeySaved(translationProvider.title)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func removeTranslationAPIKey() {
        do {
            try TranslationAPIKeyStore.deleteAPIKey(for: translationProvider)
            hasTranslationAPIKey = false
            statusMessage = AppText.translationAPIKeyRemoved(translationProvider.title)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func openTranscriptsFolder() {
        do {
            try FileManager.default.createDirectory(
                at: transcriptsDirectoryURL,
                withIntermediateDirectories: true
            )
            NSWorkspace.shared.open(transcriptsDirectoryURL)
        } catch {
            statusMessage = AppText.saveLibraryFailed(error.localizedDescription)
        }
    }

    func loadSavedTranscripts() {
        do {
            try FileManager.default.createDirectory(
                at: transcriptsDirectoryURL,
                withIntermediateDirectories: true
            )
            let fileURLs = try transcriptSearchDirectories().flatMap { directoryURL in
                try FileManager.default.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )
            }
            let originalFiles = fileURLs
                .filter { $0.pathExtension == "txt" && $0.lastPathComponent.hasSuffix("_original.txt") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            savedTranscripts = originalFiles.compactMap { originalURL in
                let stem = String(originalURL.lastPathComponent.dropLast("_original.txt".count))
                let translationURL = originalURL.deletingLastPathComponent().appendingPathComponent("\(stem)_translation.txt")
                guard let sourceText = try? String(contentsOf: originalURL, encoding: .utf8),
                      let translatedText = try? String(contentsOf: translationURL, encoding: .utf8)
                else {
                    return nil
                }
                let updatedAt = (try? originalURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                return SavedTranscript(
                    id: stem,
                    sourceFileURL: originalURL,
                    translationFileURL: translationURL,
                    sourceText: sourceText,
                    translatedText: translatedText,
                    updatedAt: updatedAt
                )
            }
            savedTranscripts.sort { $0.updatedAt > $1.updatedAt }
        } catch {
            statusMessage = AppText.saveLibraryFailed(error.localizedDescription)
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
        writeTranscriptText(savedDraftSourceText, to: selectedTranscript.sourceFileURL)
        if let translationFileURL = selectedTranscript.translationFileURL {
            writeTranscriptText(savedDraftTranslationText, to: translationFileURL)
        }
        loadSavedTranscripts()
    }

    func deleteSelectedTranscript() {
        guard let selectedTranscript = selectedSavedTranscript else { return }
        try? FileManager.default.removeItem(at: selectedTranscript.sourceFileURL)
        if let translationFileURL = selectedTranscript.translationFileURL {
            try? FileManager.default.removeItem(at: translationFileURL)
        }
        selectedSavedTranscriptID = nil
        savedDraftSourceText = ""
        savedDraftTranslationText = ""
        loadSavedTranscripts()
    }

    func deleteAllSavedTranscripts() {
        for transcript in savedTranscripts {
            try? FileManager.default.removeItem(at: transcript.sourceFileURL)
            if let translationFileURL = transcript.translationFileURL {
                try? FileManager.default.removeItem(at: translationFileURL)
            }
        }
        savedTranscripts.removeAll()
        selectedSavedTranscriptID = nil
        savedDraftSourceText = ""
        savedDraftTranslationText = ""
    }

    private func saveOfflineVideoTranscript(sourceText: String, translatedText: String) {
        let updatedAt = Date()
        let baseFileName = makeTranscriptFileName(for: sourceText, date: updatedAt)
        let originalFileName = transcriptVariantFileName(baseFileName, suffix: "original")
        let translationFileName = transcriptVariantFileName(baseFileName, suffix: "translation")

        guard writeTranscriptText(sourceText, fileName: originalFileName),
              writeTranscriptText(translatedText, fileName: translationFileName)
        else {
            return
        }
        loadSavedTranscripts()
    }

    @discardableResult
    private func writeTranscriptText(_ text: String, fileName: String) -> Bool {
        writeTranscriptText(text, to: transcriptURL(fileName: fileName))
    }

    @discardableResult
    private func writeTranscriptText(_ text: String, to fileURL: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            statusMessage = AppText.saveLibraryFailed(error.localizedDescription)
            return false
        }
    }

    private func makeTranscriptFileName(for text: String, date: Date) -> String {
        let title = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "video"
        let safeTitle = title
            .replacingOccurrences(of: #"[^A-Za-z0-9가-힣一-龥ぁ-んァ-ン]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(formatter.string(from: date))-\(String(safeTitle.prefix(36))).txt"
    }

    private func transcriptVariantFileName(_ fileName: String, suffix: String) -> String {
        let stem = fileName.hasSuffix(".txt") ? String(fileName.dropLast(4)) : fileName
        return "\(stem)_\(suffix).txt"
    }

    private var transcriptsDirectoryURL: URL {
        currentApplicationSupportDirectory.appendingPathComponent("Transcripts", isDirectory: true)
    }

    private var currentApplicationSupportDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VidLingo", isDirectory: true)
    }

    private var legacyTranscriptsDirectoryURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AirTranslate", isDirectory: true)
            .appendingPathComponent("Transcripts", isDirectory: true)
    }

    private func transcriptURL(fileName: String) -> URL {
        transcriptsDirectoryURL.appendingPathComponent(fileName)
    }

    private func transcriptSearchDirectories() -> [URL] {
        let fileManager = FileManager.default
        var directories = [transcriptsDirectoryURL]
        if fileManager.fileExists(atPath: legacyTranscriptsDirectoryURL.path) {
            directories.append(legacyTranscriptsDirectoryURL)
        }
        return directories
    }

    private func organizeTranscript(_ text: String, language: LanguageOption) -> String {
        TranscriptTextProcessor.organizeTranscript(text, languageID: language.id)
    }

    private func hasEffectiveSpeechTranscript(_ text: String, language: LanguageOption) -> Bool {
        let normalizedText = text.lowercased()
        let letterCount = normalizedText.unicodeScalars.filter {
            CharacterSet.letters.contains($0)
        }.count
        guard letterCount >= 12 else { return false }

        if usesUnspacedScript(language) {
            return !containsKnownHallucination(in: normalizedText)
        }

        let words = normalizedText
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        guard words.count >= 6 else { return false }

        let uniqueWordRatio = Double(Set(words).count) / Double(words.count)
        if uniqueWordRatio < 0.35 {
            return false
        }

        let lines = normalizedText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if lines.count >= 3, Set(lines).count <= max(1, lines.count / 3) {
            return false
        }

        if containsKnownHallucination(in: normalizedText) {
            return false
        }

        return true
    }

    private func usesUnspacedScript(_ language: LanguageOption) -> Bool {
        ["th-TH", "zh-CN", "ja-JP"].contains(language.id)
    }

    private func containsKnownHallucination(in normalizedText: String) -> Bool {
        let hallucinationPhrases = [
            "*trips*",
            "trips trips",
            "do you know how to put the person in it",
            "you can see the person in it",
            "i can see the person in it"
        ]
        return hallucinationPhrases.contains(where: { normalizedText.contains($0) })
    }

    private static func formattedVideoDuration(for videoURL: URL) async -> String {
        let asset = AVURLAsset(url: videoURL)
        let duration = try? await asset.load(.duration)
        let seconds = duration.map(CMTimeGetSeconds) ?? 0
        guard seconds.isFinite, seconds > 0 else { return "" }
        return String(format: "%d:%02d", Int(seconds.rounded()) / 60, Int(seconds.rounded()) % 60)
    }

    private func restoreSelectedSettings() {
        isRestoringSelectedSettings = true
        defer { isRestoringSelectedSettings = false }

        let defaults = UserDefaults.standard
        if let sourceLanguageID = defaults.string(forKey: SettingsKey.sourceLanguageID),
           let language = LanguageOption.supported.first(where: { $0.id == sourceLanguageID }) {
            sourceLanguage = language
        }
        if let targetLanguageID = defaults.string(forKey: SettingsKey.targetLanguageID),
           let language = LanguageOption.supported.first(where: { $0.id == targetLanguageID }) {
            targetLanguage = language
        }
        if defaults.object(forKey: SettingsKey.isSourceAutoDetectionEnabled) != nil {
            isSourceAutoDetectionEnabled = defaults.bool(forKey: SettingsKey.isSourceAutoDetectionEnabled)
        }
        if let providerID = defaults.string(forKey: SettingsKey.translationProviderID),
           let provider = TranslationProviderID(rawValue: providerID) {
            translationProvider = provider
        }
        customTranslationBaseURL = defaults.string(forKey: SettingsKey.customTranslationBaseURL) ?? ""
        translationModelName = storedTranslationModelName(for: translationProvider)
        hasTranslationAPIKey = TranslationAPIKeyStore.hasAPIKey(for: translationProvider)
    }

    private func persistSelectedSettings() {
        guard !isRestoringSelectedSettings else { return }
        let defaults = UserDefaults.standard
        defaults.set(sourceLanguage.id, forKey: SettingsKey.sourceLanguageID)
        defaults.set(targetLanguage.id, forKey: SettingsKey.targetLanguageID)
        defaults.set(isSourceAutoDetectionEnabled, forKey: SettingsKey.isSourceAutoDetectionEnabled)
        defaults.set(translationProvider.rawValue, forKey: SettingsKey.translationProviderID)
        defaults.set(customTranslationBaseURL, forKey: SettingsKey.customTranslationBaseURL)
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
