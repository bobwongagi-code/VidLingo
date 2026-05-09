import AVFAudio
import AppKit
import Foundation
import Observation

private enum SettingsKey {
    static let sourceLanguageID = "sourceLanguageID"
    static let targetLanguageID = "targetLanguageID"
    static let selectedModelID = "selectedModelID"
    static let isDubbingEnabled = "isDubbingEnabled"
    static let isTranscriptLintEnabled = "isTranscriptLintEnabled"
    static let floatingCaptionDisplayMode = "floatingCaptionDisplayMode"
    static let floatingCaptionTextSize = "floatingCaptionTextSize"
    static let floatingCaptionLineCount = "floatingCaptionLineCount"
}

private struct TranslationRequest {
    let line: CaptionLine
    let sourceText: String
    let source: LanguageOption
    let target: LanguageOption
}

@Observable
@MainActor
final class TranslationSessionStore {
    var isRunning = false
    var isPaused = false
    var isDubbingEnabled = false {
        didSet {
            persistSelectedSettings()
            if isDubbingEnabled {
                primeDubbingBaselineToCurrentTranslation()
            } else {
                stopSpeaking()
                lastSpokenTranslatedText = ""
                clearSpokenTranslationUnits()
            }
        }
    }
    var sourceLanguage = LanguageOption.supported[0] {
        didSet {
            persistSelectedSettings()
            resetDubbingProgress()
        }
    }
    var targetLanguage = LanguageOption.supported[1] {
        didSet {
            persistSelectedSettings()
            resetDubbingProgress()
        }
    }
    var selectedModel = IntelligenceModel.appleSystem {
        didSet {
            persistSelectedSettings()
            resetDubbingProgress()
        }
    }
    var isTranscriptLintEnabled = false {
        didSet { persistSelectedSettings() }
    }
    var floatingCaptionDisplayMode = FloatingCaptionDisplayMode.originalAndTranslation {
        didSet { persistSelectedSettings() }
    }
    var floatingCaptionTextSize = FloatingCaptionTextSize.medium {
        didSet { persistSelectedSettings() }
    }
    var floatingCaptionLineCount = FloatingCaptionLineCount.three {
        didSet { persistSelectedSettings() }
    }
    var statusMessage = AppText.ready
    var lines: [CaptionLine] = []
    var savedTranscripts: [SavedTranscript] = []
    var selectedSavedTranscriptID: String?
    var savedDraftSourceText = ""

    private let capture = SystemAudioCapture()
    private let transcriber = LiveSpeechTranscriber()
    private let translator = AppleTranslationService()
    private let speechOutput = TranslatedSpeechOutput()
    private let spellChecker = NSSpellChecker.shared
    private let spellDocumentTag = NSSpellChecker.uniqueSpellDocumentTag()
    private var audioSampleCount = 0
    private var latestAudioLevel: Float?
    private var lastRecognizedText = ""
    private var lastRecognizedWasFinal = false
    private var lastRecognitionAt = Date.distantPast
    private var currentLineID: UUID?
    private var transcriptCleanupTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var latestTranslationRequest: TranslationRequest?
    private var translationBurstStartedAt = Date.distantPast
    private var committedSourceText = ""
    private var currentPartialText = ""
    private var pendingParagraphBreakBeforePartial = false
    private var pendingTranslationSourceText = ""
    private var translatedSegmentsBySource: [String: String] = [:]
    private var activeAutosaveTranscriptID: String?
    private var activeAutosaveSourceText = ""
    private var isRestoringSelectedSettings = false
    private var lastSpokenTranslatedText = ""
    private var spokenTranslationUnitKeys: Set<String> = []
    private var spokenTranslationUnitKeyOrder: [String] = []

    init() {
        restoreSelectedSettings()
        capture.delegate = self
        transcriber.delegate = self
        loadSavedTranscripts()
    }

    func start() {
        guard !isRunning else { return }

        resetLiveSessionState(clearsVisibleLines: true)
        isPaused = false
        transcriber.setPaused(false)
        isRunning = true
        statusMessage = AppText.checkingScreenPermission

        Task {
            do {
                try capture.requestScreenRecordingAccess()
                statusMessage = AppText.checkingSpeechPermission
                try await startCaptioners()
                statusMessage = AppText.startingCapture
                try await capture.start()
                statusMessage = AppText.listeningForSpeech
                warmTranslationSession()
            } catch {
                isRunning = false
                stopCaptioners()
                await capture.stop()
                statusMessage = AppText.startFailed(error.localizedDescription)
            }
        }
    }

    func stop() {
        guard isRunning else { return }

        flushPendingTranscriptSave()
        resetLiveSessionState(clearsVisibleLines: true)
        isPaused = false
        transcriber.setPaused(false)
        isRunning = false
        statusMessage = AppText.stopped
        stopCaptioners()

        Task {
            await capture.stop()
        }
    }

    func pause() {
        guard isRunning, !isPaused else { return }

        transcriptCleanupTask?.cancel()
        transcriptCleanupTask = nil
        commitCurrentPartial()
        organizeCurrentTranscript(sourceTextOverride: visibleTranscript())
        transcriber.setPaused(true)
        isPaused = true
        statusMessage = AppText.paused
    }

    func resume() {
        guard isRunning, isPaused else { return }

        transcriber.setPaused(false)
        isPaused = false
        lastRecognitionAt = Date()
        statusMessage = AppText.listeningForSpeech
    }

    func prepareForTermination() {
        flushPendingTranscriptSave()
    }

    func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }

        NSWorkspace.shared.open(url)
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

    var languageSummary: String {
        AppText.languageSummary(source: sourceLanguage.localizedTitle, target: targetLanguage.localizedTitle)
    }

    var floatingSourceText: String {
        floatingCaptionText(from: lines.last?.sourceText)
    }

    var floatingTranslationText: String {
        guard let translatedText = lines.last?.translatedText.trimmingCharacters(in: .whitespacesAndNewlines),
              translatedText != AppText.translating
        else {
            return ""
        }

        return floatingCaptionText(from: translatedText)
    }

    var hasFloatingCaptionContent: Bool {
        !floatingSourceText.isEmpty || !floatingTranslationText.isEmpty
    }

    func selectSavedTranscript(_ id: String) {
        guard let transcript = savedTranscripts.first(where: { $0.id == id }) else { return }

        selectedSavedTranscriptID = id
        savedDraftSourceText = transcript.sourceText
    }

    func saveSelectedTranscriptEdits() {
        guard let selectedSavedTranscriptID,
              let index = savedTranscripts.firstIndex(where: { $0.id == selectedSavedTranscriptID })
        else {
            return
        }

        let sourceText = savedDraftSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty else { return }

        let updatedAt = Date()
        guard writeTranscriptText(sourceText, fileName: selectedSavedTranscriptID) else { return }
        savedTranscripts[index] = SavedTranscript(
            fileName: selectedSavedTranscriptID,
            sourceText: sourceText,
            updatedAt: updatedAt
        )
        sortSavedTranscripts()
    }

    func deleteSelectedTranscript() {
        guard let selectedSavedTranscriptID else { return }

        savedTranscripts.removeAll { $0.id == selectedSavedTranscriptID }
        try? FileManager.default.removeItem(at: transcriptURL(fileName: selectedSavedTranscriptID))
        if activeAutosaveTranscriptID == selectedSavedTranscriptID {
            activeAutosaveTranscriptID = nil
            activeAutosaveSourceText = ""
        }
        self.selectedSavedTranscriptID = nil
        savedDraftSourceText = ""
    }

    private func startCaptioners() async throws {
        try await transcriber.start(languages: [sourceLanguage])
    }

    private func stopCaptioners() {
        transcriber.stop()
    }

    private func resetLiveSessionState(clearsVisibleLines: Bool) {
        audioSampleCount = 0
        latestAudioLevel = nil
        lastRecognizedText = ""
        lastRecognizedWasFinal = false
        currentLineID = nil
        committedSourceText = ""
        currentPartialText = ""
        pendingParagraphBreakBeforePartial = false
        pendingTranslationSourceText = ""
        latestTranslationRequest = nil
        translationBurstStartedAt = Date.distantPast
        activeAutosaveTranscriptID = nil
        activeAutosaveSourceText = ""
        stopSpeaking()
        lastSpokenTranslatedText = ""
        clearSpokenTranslationUnits()
        translationTask?.cancel()
        translationTask = nil
        transcriptCleanupTask?.cancel()
        transcriptCleanupTask = nil

        if clearsVisibleLines {
            lines.removeAll()
        }
    }

    private func warmTranslationSession() {
        let warmSourceLanguage = sourceLanguage
        let warmTargetLanguage = targetLanguage
        let warmSelectedModel = selectedModel

        Task { @MainActor in
            try? await translator.prepare(
                source: warmSourceLanguage,
                target: warmTargetLanguage,
                model: warmSelectedModel
            )
        }
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
        if let modelID = defaults.string(forKey: SettingsKey.selectedModelID),
           let model = IntelligenceModel(rawValue: modelID) {
            selectedModel = model
        }
        if defaults.object(forKey: SettingsKey.isDubbingEnabled) != nil {
            isDubbingEnabled = defaults.bool(forKey: SettingsKey.isDubbingEnabled)
        }
        if defaults.object(forKey: SettingsKey.isTranscriptLintEnabled) != nil {
            isTranscriptLintEnabled = defaults.bool(forKey: SettingsKey.isTranscriptLintEnabled)
        }
        if let modeID = defaults.string(forKey: SettingsKey.floatingCaptionDisplayMode),
           let mode = FloatingCaptionDisplayMode(rawValue: modeID) {
            floatingCaptionDisplayMode = mode
        }
        if let sizeID = defaults.string(forKey: SettingsKey.floatingCaptionTextSize),
           let size = FloatingCaptionTextSize(rawValue: sizeID) {
            floatingCaptionTextSize = size
        }
        if let lineCountID = defaults.string(forKey: SettingsKey.floatingCaptionLineCount),
           let rawValue = Int(lineCountID),
           let lineCount = FloatingCaptionLineCount(rawValue: rawValue) {
            floatingCaptionLineCount = lineCount
        }
    }

    private func persistSelectedSettings() {
        guard !isRestoringSelectedSettings else { return }

        let defaults = UserDefaults.standard
        defaults.set(sourceLanguage.id, forKey: SettingsKey.sourceLanguageID)
        defaults.set(targetLanguage.id, forKey: SettingsKey.targetLanguageID)
        defaults.set(selectedModel.id, forKey: SettingsKey.selectedModelID)
        defaults.set(isDubbingEnabled, forKey: SettingsKey.isDubbingEnabled)
        defaults.set(isTranscriptLintEnabled, forKey: SettingsKey.isTranscriptLintEnabled)
        defaults.set(floatingCaptionDisplayMode.id, forKey: SettingsKey.floatingCaptionDisplayMode)
        defaults.set(floatingCaptionTextSize.id, forKey: SettingsKey.floatingCaptionTextSize)
        defaults.set(floatingCaptionLineCount.id, forKey: SettingsKey.floatingCaptionLineCount)
    }

    private func floatingCaptionText(from text: String?) -> String {
        guard let text else { return "" }

        return text.floatingCaptionTail(maxLines: floatingCaptionLineCount.rawValue)
    }

    private func loadSavedTranscripts() {
        do {
            try FileManager.default.createDirectory(
                at: transcriptsDirectoryURL,
                withIntermediateDirectories: true
            )
            let fileURLs = try FileManager.default.contentsOfDirectory(
                at: transcriptsDirectoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            savedTranscripts = fileURLs
                .filter { $0.pathExtension == "txt" }
                .compactMap { fileURL in
                    guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
                        return nil
                    }
                    let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
                    return SavedTranscript(
                        fileName: fileURL.lastPathComponent,
                        sourceText: text.trimmingCharacters(in: .whitespacesAndNewlines),
                        updatedAt: values?.contentModificationDate ?? Date.distantPast
                    )
                }
            sortSavedTranscripts()
        } catch {
            savedTranscripts = []
        }
    }

    private func stageTranscriptForSave(_ sourceText: String) {
        let sourceText = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty else { return }

        activeAutosaveSourceText = sourceText
    }

    private func flushPendingTranscriptSave() {
        let sourceText = activeAutosaveSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty else { return }

        let updatedAt = Date()
        let fileName = activeAutosaveTranscriptID ?? makeTranscriptFileName(for: sourceText, date: updatedAt)
        guard writeTranscriptText(sourceText, fileName: fileName) else { return }
        activeAutosaveTranscriptID = nil
        activeAutosaveSourceText = ""
        upsertSavedTranscript(fileName: fileName, sourceText: sourceText, updatedAt: updatedAt)
    }

    @discardableResult
    private func writeTranscriptText(_ text: String, fileName: String) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: transcriptsDirectoryURL,
                withIntermediateDirectories: true
            )
            try text.write(
                to: transcriptURL(fileName: fileName),
                atomically: true,
                encoding: .utf8
            )
            return true
        } catch {
            statusMessage = AppText.saveLibraryFailed(error.localizedDescription)
            return false
        }
    }

    private func upsertSavedTranscript(fileName: String, sourceText: String, updatedAt: Date) {
        let transcript = SavedTranscript(
            fileName: fileName,
            sourceText: sourceText,
            updatedAt: updatedAt
        )

        if let index = savedTranscripts.firstIndex(where: { $0.id == fileName }) {
            savedTranscripts[index] = transcript
        } else {
            savedTranscripts.insert(transcript, at: 0)
        }

        if selectedSavedTranscriptID == fileName {
            savedDraftSourceText = sourceText
        }
        sortSavedTranscripts()
    }

    private func sortSavedTranscripts() {
        savedTranscripts.sort { $0.updatedAt > $1.updatedAt }
    }

    private var transcriptsDirectoryURL: URL {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return supportDirectory
            .appendingPathComponent("AirTranslate", isDirectory: true)
            .appendingPathComponent("Transcripts", isDirectory: true)
    }

    private func transcriptURL(fileName: String) -> URL {
        transcriptsDirectoryURL.appendingPathComponent(fileName)
    }

    private func makeTranscriptFileName(for sourceText: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let timestamp = formatter.string(from: date)
        let baseName = "\(timestamp)_\(shortFileTitle(from: sourceText))"
        var fileName = "\(baseName).txt"
        var suffix = 2

        while FileManager.default.fileExists(atPath: transcriptURL(fileName: fileName).path) {
            fileName = "\(baseName)-\(suffix).txt"
            suffix += 1
        }

        return fileName
    }

    private func shortFileTitle(from sourceText: String) -> String {
        let firstLine = sourceText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? AppText.untitledTranscript
        let allowedCharacters = CharacterSet.letters
            .union(.decimalDigits)
            .union(.whitespacesAndNewlines)
            .union(CharacterSet(charactersIn: "-_"))
        let readableText = String(firstLine.unicodeScalars.map { scalar in
            allowedCharacters.contains(scalar) ? Character(scalar) : " "
        })
        let sanitized = readableText
            .replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_ "))

        guard !sanitized.isEmpty else {
            return AppText.untitledTranscript.replacingOccurrences(of: " ", with: "-")
        }

        return String(sanitized.prefix(32))
    }

    private func appendCaption(
        sourceText: String,
        recognizedLanguage: LanguageOption,
        confidence _: Double,
        isFinal: Bool
    ) async {
        guard isRunning, !isPaused else { return }
        guard sourceText != lastRecognizedText || isFinal != lastRecognizedWasFinal else { return }
        guard let direction = translationDirection(for: sourceText, recognizedLanguage: recognizedLanguage) else { return }

        let now = Date()
        let hadLongSilence = now.timeIntervalSince(lastRecognitionAt) > 5

        let updatedSourceText = accumulatedTranscript(
            incoming: sourceText,
            hadLongSilence: hadLongSilence
        )
        guard !updatedSourceText.isEmpty else { return }

        lastRecognizedText = sourceText
        lastRecognizedWasFinal = isFinal
        lastRecognitionAt = now
        transcriptCleanupTask?.cancel()

        let line: CaptionLine
        if let currentLineID,
           let index = lines.firstIndex(where: { $0.id == currentLineID }) {
            let existingLine = lines[index]
            guard updatedSourceText != existingLine.sourceText else { return }

            line = CaptionLine(
                id: existingLine.id,
                sourceText: updatedSourceText,
                translatedText: existingLine.translatedText,
                translatedSourceText: existingLine.translatedSourceText,
                createdAt: existingLine.createdAt,
                isFinal: isFinal,
                revision: existingLine.revision + 1
            )
            lines[index] = line
        } else {
            line = CaptionLine(
                sourceText: updatedSourceText,
                translatedText: AppText.translating,
                createdAt: Date(),
                isFinal: isFinal,
                revision: 1
            )
            currentLineID = line.id
            lines.append(line)
        }

        stageTranscriptForSave(line.sourceText)
        requestTranslation(for: line, source: direction.source, target: direction.target)
    }

    private func accumulatedTranscript(incoming: String, hadLongSilence: Bool) -> String {
        let trimmedIncoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIncoming.isEmpty else { return visibleTranscript() }

        if hadLongSilence, !currentPartialText.isEmpty {
            commitCurrentPartial()
            pendingParagraphBreakBeforePartial = !committedSourceText.isEmpty
        }

        if currentPartialText.isEmpty {
            if committedTextAlreadyContains(trimmedIncoming) {
                return visibleTranscript()
            }
            currentPartialText = trimmedIncoming
            return visibleTranscript()
        }

        if trimmedIncoming.count + 2 >= currentPartialText.count
            || trimmedIncoming.hasPrefix(currentPartialText)
            || currentPartialText.hasPrefix(trimmedIncoming) {
            currentPartialText = trimmedIncoming.count >= currentPartialText.count ? trimmedIncoming : currentPartialText
            return visibleTranscript()
        }

        commitCurrentPartial()
        pendingParagraphBreakBeforePartial = hadLongSilence && !committedSourceText.isEmpty
        currentPartialText = trimmedIncoming
        return visibleTranscript()
    }

    private func commitCurrentPartial() {
        let partial = organizeTranscript(currentPartialText, language: sourceLanguage)
        guard !partial.isEmpty else { return }

        if committedSourceText.isEmpty {
            committedSourceText = partial
        } else if shouldAppendCommittedPartial(partial) {
            let separator = pendingParagraphBreakBeforePartial ? "\n\n" : "\n"
            committedSourceText += separator + partial
        }
        pendingParagraphBreakBeforePartial = false
        currentPartialText = ""
    }

    private func committedTextAlreadyContains(_ text: String) -> Bool {
        let committed = committedSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !committed.isEmpty else { return false }

        let normalizedCommitted = normalizedTranscriptForComparison(committed)
        let normalizedText = normalizedTranscriptForComparison(text)
        guard !normalizedText.isEmpty else { return false }

        return normalizedCommitted == normalizedText
            || normalizedCommitted.hasSuffix(normalizedText)
            || normalizedCommitted.contains(normalizedText)
    }

    private func shouldAppendCommittedPartial(_ partial: String) -> Bool {
        let normalizedCommitted = normalizedTranscriptForComparison(committedSourceText)
        let normalizedPartial = normalizedTranscriptForComparison(partial)
        guard !normalizedPartial.isEmpty else { return false }

        return !normalizedCommitted.hasSuffix(normalizedPartial)
            && !normalizedCommitted.contains(normalizedPartial)
    }

    private func normalizedTranscriptForComparison(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func visibleTranscript() -> String {
        let committed = committedSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let partial = currentPartialText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !committed.isEmpty else {
            return partial
        }
        guard !partial.isEmpty else {
            return committed
        }

        let separator = pendingParagraphBreakBeforePartial ? "\n\n" : "\n"
        return committed + separator + partial
    }

    private func scheduleTranscriptCleanup() {
        guard isRunning, currentLineID != nil else { return }
        guard Date().timeIntervalSince(lastRecognitionAt) > 1.5 else { return }

        transcriptCleanupTask?.cancel()
        transcriptCleanupTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            organizeCurrentTranscript()
        }
    }

    private func organizeCurrentTranscript(sourceTextOverride: String? = nil) {
        guard isRunning,
              let currentLineID,
              let index = lines.firstIndex(where: { $0.id == currentLineID })
        else {
            return
        }

        let line = lines[index]
        let sourceText = sourceTextOverride ?? line.sourceText
        let organizedSourceText = organizeTranscript(
            sourceText,
            language: sourceLanguage,
            appliesLint: isTranscriptLintEnabled
        )
        let organizedTranslatedText = organizeTranslatedText(line.translatedText)
        let sourceChanged = organizedSourceText != line.sourceText
        let translationChanged = organizedTranslatedText != line.translatedText
        let needsTranslationRefresh = line.translatedSourceText != organizedSourceText

        if !sourceChanged,
           !translationChanged,
           needsTranslationRefresh,
           pendingTranslationSourceText == organizedSourceText {
            return
        }

        guard sourceChanged || translationChanged || needsTranslationRefresh else {
            return
        }

        committedSourceText = organizedSourceText
        currentPartialText = ""
        lines[index] = CaptionLine(
            id: line.id,
            sourceText: organizedSourceText,
            translatedText: organizedTranslatedText,
            translatedSourceText: line.translatedSourceText,
            createdAt: line.createdAt,
            isFinal: line.isFinal,
            revision: line.revision + 1
        )

        let updatedLine = lines[index]
        stageTranscriptForSave(updatedLine.sourceText)
        if updatedLine.translatedSourceText != updatedLine.sourceText {
            requestTranslation(for: updatedLine, source: sourceLanguage, target: targetLanguage)
        }
    }

    private func organizeTranslatedText(_ text: String) -> String {
        guard text != AppText.translating else { return text }
        return organizeTranscript(text, language: targetLanguage)
    }

    private func organizeTranscript(_ text: String, language: LanguageOption) -> String {
        organizeTranscript(text, language: language, appliesLint: false)
    }

    private func organizeTranscript(
        _ text: String,
        language: LanguageOption,
        appliesLint: Bool
    ) -> String {
        paragraphParts(from: text)
            .map {
                let organized = organizeParagraph($0, language: language)
                return appliesLint ? lintParagraph(organized, language: language) : organized
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private func organizeParagraph(_ text: String, language: LanguageOption) -> String {
        var organized = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        organized = organized.replacingOccurrences(
            of: #"([.!?。！？]+)\s+"#,
            with: "$1\n",
            options: .regularExpression
        )

        if language.id == "ko-KR" {
            organized = organized.replacingOccurrences(
                of: #"(습니다|니다|어요|아요|세요|군요|네요|죠|지요|다)\s+"#,
                with: "$1\n",
                options: .regularExpression
            )
        }

        return organized
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func lintParagraph(_ text: String, language: LanguageOption) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { lintLine(String($0), language: language) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func lintLine(_ text: String, language: LanguageOption) -> String {
        var linted = text
            .replacingOccurrences(of: #"(^|[\s,，])[,，]{1,}(\s*[,，]+)*"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([,.!?。！？])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"([,.!?])(?=\S)"#, with: "$1 ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        linted = correctUnknownWords(in: linted, language: language)

        if language.id == "en-US" {
            linted = capitalizeSentenceStarts(linted)
        }

        return linted.trimmingCharacters(in: CharacterSet(charactersIn: " ,，"))
    }

    private func correctUnknownWords(in text: String, language: LanguageOption) -> String {
        guard let spellLanguage = spellCheckerLanguage(for: language) else { return text }

        var corrected = text
        var searchLocation = 0

        while searchLocation < (corrected as NSString).length {
            var wordCount = 0
            let misspelledRange = spellChecker.checkSpelling(
                of: corrected,
                startingAt: searchLocation,
                language: spellLanguage,
                wrap: false,
                inSpellDocumentWithTag: spellDocumentTag,
                wordCount: &wordCount
            )
            guard misspelledRange.location != NSNotFound, misspelledRange.length > 0 else { break }

            let textValue = corrected as NSString
            let word = textValue.substring(with: misspelledRange)
            if let replacement = safeSpellingReplacement(
                for: word,
                in: corrected,
                range: misspelledRange,
                language: spellLanguage
            ) {
                corrected = textValue.replacingCharacters(in: misspelledRange, with: replacement)
                searchLocation = misspelledRange.location + (replacement as NSString).length
            } else {
                searchLocation = misspelledRange.location + misspelledRange.length
            }
        }

        return corrected
    }

    private func spellCheckerLanguage(for language: LanguageOption) -> String? {
        let availableLanguages = spellChecker.availableLanguages
        let normalizedID = language.id.replacingOccurrences(of: "-", with: "_")
        if availableLanguages.contains(language.id) {
            return language.id
        }
        if availableLanguages.contains(normalizedID) {
            return normalizedID
        }
        if let baseID = language.id.split(separator: "-").first.map(String.init),
           availableLanguages.contains(baseID) {
            return baseID
        }
        return nil
    }

    private func safeSpellingReplacement(
        for word: String,
        in text: String,
        range: NSRange,
        language: String
    ) -> String? {
        guard shouldCorrectSpelledWord(word, language: language),
              let guesses = spellChecker.guesses(
                  forWordRange: range,
                  in: text,
                  language: language,
                  inSpellDocumentWithTag: spellDocumentTag
              ),
              let replacement = guesses.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              isConservativeReplacement(original: word, replacement: replacement)
        else {
            return nil
        }

        return replacement
    }

    private func shouldCorrectSpelledWord(_ word: String, language: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .punctuationCharacters)
        guard trimmed.count > 1 else { return false }
        guard trimmed.rangeOfCharacter(from: .decimalDigits) == nil else { return false }
        guard trimmed.range(of: #"[/\\@#_]"#, options: .regularExpression) == nil else { return false }

        if language.hasPrefix("en"),
           let first = trimmed.first,
           first.isUppercase {
            return false
        }

        return true
    }

    private func isConservativeReplacement(original: String, replacement: String) -> Bool {
        guard !replacement.isEmpty, !replacement.contains("\n") else { return false }
        let originalLength = max((original as NSString).length, 1)
        let replacementLength = (replacement as NSString).length
        guard replacementLength <= originalLength + 4 else { return false }
        guard replacementLength * 3 >= originalLength else { return false }
        return true
    }

    private func capitalizeSentenceStarts(_ text: String) -> String {
        var result = ""
        var shouldCapitalize = true

        for character in text {
            if shouldCapitalize, character.isLetter {
                result.append(String(character).uppercased())
                shouldCapitalize = false
                continue
            }

            result.append(character)
            if ".!?".contains(character) {
                shouldCapitalize = true
            } else if !character.isWhitespace {
                shouldCapitalize = false
            }
        }

        return result
    }

    private func paragraphParts(from text: String) -> [String] {
        let marker = "\u{1E}"
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"[ \t]*\n{2,}[ \t]*"#, with: marker, options: .regularExpression)

        return normalized
            .components(separatedBy: marker)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func translateTranscript(
        _ text: String,
        source: LanguageOption,
        target: LanguageOption
    ) async throws -> String {
        let paragraphs = paragraphParts(from: text)

        guard !paragraphs.isEmpty else { return "" }

        var translatedParagraphs: [String] = []
        for paragraph in paragraphs {
            let segments = paragraph
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            var translatedSegments: [String] = []

            for segment in segments {
                try Task.checkCancellation()
                let cacheKey = translationCacheKey(segment: segment, source: source, target: target)
                if let cachedSegment = translatedSegmentsBySource[cacheKey] {
                    translatedSegments.append(cachedSegment)
                    continue
                }

                let translatedSegment = try await translator.translate(
                    segment,
                    source: source,
                    target: target,
                    model: selectedModel
                )
                try Task.checkCancellation()
                let organizedSegment = organizeTranscript(translatedSegment, language: target)
                translatedSegmentsBySource[cacheKey] = organizedSegment
                translatedSegments.append(organizedSegment)
            }

            translatedParagraphs.append(translatedSegments.joined(separator: "\n"))
        }

        return translatedParagraphs.joined(separator: "\n\n")
    }

    private func translationCacheKey(segment: String, source: LanguageOption, target: LanguageOption) -> String {
        "\(source.id)\t\(target.id)\t\(selectedModel.id)\t\(segment)"
    }

    private func requestTranslation(for line: CaptionLine, source: LanguageOption, target: LanguageOption) {
        let sourceText = line.sourceText
        guard pendingTranslationSourceText != sourceText else { return }
        pendingTranslationSourceText = sourceText
        if latestTranslationRequest == nil {
            translationBurstStartedAt = Date()
        }
        latestTranslationRequest = TranslationRequest(
            line: line,
            sourceText: sourceText,
            source: source,
            target: target
        )

        guard translationTask == nil else {
            return
        }

        translationTask = Task { @MainActor in
            await processPendingTranslationRequests()
        }
    }

    private func processPendingTranslationRequests() async {
        while !Task.isCancelled, let request = latestTranslationRequest {
            latestTranslationRequest = nil

            do {
                let delay = translationDebounceDelay()
                if delay > 0 {
                    try await Task.sleep(for: .milliseconds(delay))
                }

                if latestTranslationRequest != nil {
                    continue
                }

                translationBurstStartedAt = .distantPast
                let translatedText = try await translateTranscript(
                    request.sourceText,
                    source: request.source,
                    target: request.target
                )
                try Task.checkCancellation()
                updateTranslation(translatedText, for: request.line, matching: request.sourceText)
            } catch is CancellationError {
                translationTask = nil
                return
            } catch {
                if pendingTranslationSourceText == request.sourceText {
                    pendingTranslationSourceText = ""
                }
                statusMessage = error.localizedDescription
            }
        }

        translationTask = nil
    }

    private func translationDebounceDelay() -> Int {
        guard translationBurstStartedAt != .distantPast else { return 45 }
        let burstAge = Date().timeIntervalSince(translationBurstStartedAt)
        return burstAge >= 0.45 ? 0 : 70
    }

    private func updateTranslation(_ translatedText: String, for line: CaptionLine, matching sourceText: String) {
        guard let index = lines.firstIndex(where: { $0.id == line.id }) else { return }
        guard lines[index].sourceText == sourceText else {
            if pendingTranslationSourceText == sourceText {
                pendingTranslationSourceText = ""
            }
            return
        }
        let organizedTranslatedText = organizeTranscript(translatedText, language: targetLanguage)
        if pendingTranslationSourceText == sourceText {
            pendingTranslationSourceText = ""
        }

        lines[index] = CaptionLine(
            id: line.id,
            sourceText: sourceText,
            translatedText: organizedTranslatedText,
            translatedSourceText: sourceText,
            createdAt: line.createdAt,
            isFinal: line.isFinal,
            revision: lines[index].revision + 1
        )

        speakTranslatedDeltaIfNeeded(organizedTranslatedText)
    }

    private func translationDirection(
        for text: String,
        recognizedLanguage: LanguageOption
    ) -> (source: LanguageOption, target: LanguageOption)? {
        (sourceLanguage, targetLanguage)
    }

    private func speak(_ text: String) {
        guard !text.isEmpty else { return }
        speechOutput.speak(text, language: targetLanguage)
    }

    private func speakTranslatedDeltaIfNeeded(_ translatedText: String) {
        guard isRunning, isDubbingEnabled else { return }

        let currentText = speechReadyText(translatedText)
        guard !currentText.isEmpty else { return }

        let previousText = lastSpokenTranslatedText
        lastSpokenTranslatedText = currentText

        guard let delta = speechDelta(previous: previousText, current: currentText),
              let unspokenDelta = unspokenSpeechText(from: delta)
        else {
            return
        }

        speak(unspokenDelta)
    }

    private func speechReadyText(_ text: String) -> String {
        guard text != AppText.translating else { return "" }

        return text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func speechDelta(previous: String, current: String) -> String? {
        guard previous != current else { return nil }
        guard !current.isEmpty else { return nil }

        if previous.isEmpty {
            return current
        }

        if current.hasPrefix(previous) {
            return speakableText(String(current.dropFirst(previous.count)))
        }

        let sharedPrefixLength = commonPrefixLength(previous, current)
        if sharedPrefixLength > previous.count / 2 {
            return speakableText(String(current.dropFirst(sharedPrefixLength)))
        }

        return nil
    }

    private func commonPrefixLength(_ lhs: String, _ rhs: String) -> Int {
        var length = 0
        for (leftCharacter, rightCharacter) in zip(lhs, rhs) {
            guard leftCharacter == rightCharacter else { break }
            length += 1
        }
        return length
    }

    private func speakableText(_ text: String) -> String? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.rangeOfCharacter(from: .letters.union(.decimalDigits)) != nil else {
            return nil
        }
        return trimmedText
    }

    private func unspokenSpeechText(from text: String) -> String? {
        let units = speechUnits(from: text)
        guard !units.isEmpty else { return nil }

        var unspokenUnits: [String] = []
        for unit in units {
            let key = normalizedSpeechUnitKey(unit)
            guard !key.isEmpty, !spokenTranslationUnitKeys.contains(key) else {
                continue
            }

            rememberSpokenTranslationUnitKey(key)
            unspokenUnits.append(unit)
        }

        guard !unspokenUnits.isEmpty else { return nil }
        return unspokenUnits.joined(separator: " ")
    }

    private func speechUnits(from text: String) -> [String] {
        var units: [String] = []
        var currentUnit = ""
        let terminators = CharacterSet(charactersIn: ".!?。！？\n")

        for scalar in text.unicodeScalars {
            currentUnit.unicodeScalars.append(scalar)
            if terminators.contains(scalar) {
                let unit = speechReadyText(currentUnit)
                if !unit.isEmpty {
                    units.append(unit)
                }
                currentUnit = ""
            }
        }

        let remainingUnit = speechReadyText(currentUnit)
        if !remainingUnit.isEmpty {
            units.append(remainingUnit)
        }

        return units
    }

    private func normalizedSpeechUnitKey(_ text: String) -> String {
        let foldedText = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: targetLanguage.locale)
        let allowedCharacters = CharacterSet.letters
            .union(.decimalDigits)
            .union(.whitespacesAndNewlines)
        let filteredText = String(foldedText.unicodeScalars.map { scalar in
            allowedCharacters.contains(scalar) ? Character(scalar) : " "
        })

        return filteredText
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rememberSpokenTranslationUnitKey(_ key: String) {
        spokenTranslationUnitKeys.insert(key)
        spokenTranslationUnitKeyOrder.append(key)

        while spokenTranslationUnitKeyOrder.count > 160 {
            let removedKey = spokenTranslationUnitKeyOrder.removeFirst()
            if !spokenTranslationUnitKeyOrder.contains(removedKey) {
                spokenTranslationUnitKeys.remove(removedKey)
            }
        }
    }

    private func rememberSpokenTranslationUnits(in text: String) {
        for unit in speechUnits(from: text) {
            let key = normalizedSpeechUnitKey(unit)
            if !key.isEmpty {
                rememberSpokenTranslationUnitKey(key)
            }
        }
    }

    private func clearSpokenTranslationUnits() {
        spokenTranslationUnitKeys.removeAll()
        spokenTranslationUnitKeyOrder.removeAll()
    }

    private func resetDubbingProgress() {
        lastSpokenTranslatedText = ""
        clearSpokenTranslationUnits()
        stopSpeaking()
    }

    private func primeDubbingBaselineToCurrentTranslation() {
        let currentTranslation = speechReadyText(lines.last?.translatedText ?? "")
        lastSpokenTranslatedText = currentTranslation
        clearSpokenTranslationUnits()
        rememberSpokenTranslationUnits(in: currentTranslation)
    }

    private func stopSpeaking() {
        speechOutput.stop()
    }
}

extension TranslationSessionStore: SystemAudioCaptureDelegate {
    nonisolated func systemAudioCapture(_ capture: SystemAudioCapture, didOutput sampleBuffer: CMSampleBuffer) {
        transcriber.append(sampleBuffer)
    }

    nonisolated func systemAudioCapture(_ capture: SystemAudioCapture, didReceiveAudioSampleCount count: Int, level: Float?) {
        Task { @MainActor in
            audioSampleCount = count
            latestAudioLevel = level
            guard !isPaused else {
                statusMessage = AppText.paused
                return
            }
            if isRunning, lines.isEmpty {
                statusMessage = audioStatusMessage(sampleCount: count, level: level)
            }
            if let level, level < -50 {
                scheduleTranscriptCleanup()
            }
        }
    }

    private func audioStatusMessage(sampleCount: Int, level: Float?) -> String {
        guard let level else {
            return AppText.receivingAudioWaiting(sampleCount: sampleCount)
        }

        let roundedLevel = Int(level.rounded())
        if level < -55 {
            return AppText.receivingSilentAudio(sampleCount: sampleCount, level: roundedLevel)
        }

        return AppText.receivingAudioTranscribing(sampleCount: sampleCount, level: roundedLevel)
    }
}

extension TranslationSessionStore: LiveSpeechTranscriberDelegate {
    nonisolated func liveSpeechTranscriber(
        _ transcriber: LiveSpeechTranscriber,
        didRecognize text: String,
        language: LanguageOption,
        confidence: Double
    ) {
        Task { @MainActor in
            await appendCaption(
                sourceText: text,
                recognizedLanguage: language,
                confidence: confidence,
                isFinal: false
            )
        }
    }

    nonisolated func liveSpeechTranscriber(_ transcriber: LiveSpeechTranscriber, didFail error: Error) {
        Task { @MainActor in
            statusMessage = error.localizedDescription
        }
    }
}
