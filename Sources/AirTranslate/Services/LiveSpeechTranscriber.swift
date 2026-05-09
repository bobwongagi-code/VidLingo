import AVFoundation
import CoreMedia
import Speech

protocol LiveSpeechTranscriberDelegate: AnyObject {
    func liveSpeechTranscriber(
        _ transcriber: LiveSpeechTranscriber,
        didRecognize text: String,
        language: LanguageOption,
        confidence: Double
    )
    func liveSpeechTranscriber(_ transcriber: LiveSpeechTranscriber, didFail error: Error)
}

final class LiveSpeechTranscriber: @unchecked Sendable {
    weak var delegate: LiveSpeechTranscriberDelegate?

    private static let reusablePCMBufferCount = 48

    private let audioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzeTask: Task<Void, Never>?
    private var resultTasks: [Task<Void, Never>] = []
    private var reservedLocales: [Locale] = []
    private let stateLock = NSLock()
    private let conversionLock = NSLock()
    private var isPaused = false
    private var reusablePCMBuffers = [AVAudioPCMBuffer?](
        repeating: nil,
        count: reusablePCMBufferCount
    )
    private var reusablePCMBufferCursor = 0

    func start(languages: [LanguageOption]) async throws {
        let authorized = await requestAuthorization()
        guard authorized else { throw SpeechError.notAuthorized }

        stop()

        let uniqueLanguages = Array(
            Dictionary(grouping: languages, by: \.id).compactMap { $0.value.first }
        ).sorted { $0.id < $1.id }
        var transcribers: [(language: LanguageOption, transcriber: SpeechTranscriber)] = []
        for language in uniqueLanguages {
            guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: language.locale) else {
                throw SpeechError.recognizerUnavailable
            }

            try await AssetInventory.reserve(locale: supportedLocale)
            reservedLocales.append(supportedLocale)
            transcribers.append((
                language: language,
                transcriber: SpeechTranscriber(
                    locale: supportedLocale,
                    transcriptionOptions: [],
                    reportingOptions: [.volatileResults, .fastResults],
                    attributeOptions: [.transcriptionConfidence]
                )
            ))
        }
        let modules: [any SpeechModule] = transcribers.map(\.transcriber)
        let inputStream = AsyncStream<AnalyzerInput> { continuation in
            self.inputContinuation = continuation
        }
        let analyzer = SpeechAnalyzer(modules: modules)

        try await analyzer.prepareToAnalyze(in: audioFormat)

        self.analyzer = analyzer
        analyzeTask = Task { [weak self] in
            do {
                try await analyzer.start(inputSequence: inputStream)
            } catch {
                guard let self else { return }
                self.delegate?.liveSpeechTranscriber(self, didFail: error)
            }
        }

        resultTasks = transcribers.map { entry in
            Task { [weak self] in
                do {
                    for try await result in entry.transcriber.results {
                        let text = String(result.text.characters)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        guard let self else { return }
                        self.delegate?.liveSpeechTranscriber(
                            self,
                            didRecognize: text,
                            language: entry.language,
                            confidence: Self.averageConfidence(in: result.text)
                        )
                    }
                } catch {
                    guard let self else { return }
                    self.delegate?.liveSpeechTranscriber(self, didFail: error)
                }
            }
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        stateLock.lock()
        let isPaused = isPaused
        stateLock.unlock()

        guard !isPaused, let inputContinuation else { return }

        conversionLock.lock()
        let pcmBuffer = pcmBuffer(from: sampleBuffer)
        conversionLock.unlock()

        guard let pcmBuffer else {
            return
        }

        inputContinuation.yield(AnalyzerInput(buffer: pcmBuffer))
    }

    func setPaused(_ isPaused: Bool) {
        stateLock.lock()
        self.isPaused = isPaused
        stateLock.unlock()
    }

    func stop() {
        setPaused(false)
        inputContinuation?.finish()
        inputContinuation = nil
        analyzeTask?.cancel()
        analyzeTask = nil
        resultTasks.forEach { $0.cancel() }
        resultTasks = []
        resetReusablePCMBuffers()

        if let analyzer {
            Task {
                await analyzer.cancelAndFinishNow()
            }
        }
        analyzer = nil

        let localesToRelease = reservedLocales
        reservedLocales = []
        Task {
            for locale in localesToRelease {
                await AssetInventory.release(reservedLocale: locale)
            }
        }
    }

    private func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private static func averageConfidence(in text: AttributedString) -> Double {
        var total = 0.0
        var count = 0

        for run in text.runs {
            if let confidence = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] {
                total += confidence
                count += 1
            }
        }

        return count == 0 ? 0.5 : total / Double(count)
    }

    private func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let pcmBuffer = reusablePCMBuffer(frameCount: frameCount),
              let destination = pcmBuffer.int16ChannelData?.pointee,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            return nil
        }

        var listSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &listSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard listSize > 0 else { return nil }

        return withUnsafeTemporaryAllocation(
            byteCount: listSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        ) { rawList -> AVAudioPCMBuffer? in
            guard let baseAddress = rawList.baseAddress else { return nil }

            let audioBufferList = baseAddress.bindMemory(to: AudioBufferList.self, capacity: 1)
            var blockBuffer: CMBlockBuffer?
            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: audioBufferList,
                bufferListSize: listSize,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                blockBufferOut: &blockBuffer
            )
            guard status == noErr else { return nil }

            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let sourceIsFloat = streamDescription.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0
            var copiedSamples = 0

            for buffer in buffers {
                guard let data = buffer.mData else { continue }

                if sourceIsFloat {
                    let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    let samples = data.bindMemory(to: Float.self, capacity: sampleCount)
                    for index in 0..<sampleCount where copiedSamples < frameCount {
                        let sample = max(-1, min(1, samples[index]))
                        destination[copiedSamples] = Int16(sample * Float(Int16.max))
                        copiedSamples += 1
                    }
                } else {
                    let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                    let samples = data.bindMemory(to: Int16.self, capacity: sampleCount)
                    let remainingSamples = frameCount - copiedSamples
                    let samplesToCopy = min(sampleCount, remainingSamples)
                    guard samplesToCopy > 0 else { break }

                    destination
                        .advanced(by: copiedSamples)
                        .update(from: samples, count: samplesToCopy)
                    copiedSamples += samplesToCopy
                }
            }

            guard copiedSamples > 0 else { return nil }
            pcmBuffer.frameLength = AVAudioFrameCount(copiedSamples)
            return pcmBuffer
        }
    }

    private func reusablePCMBuffer(frameCount: Int) -> AVAudioPCMBuffer? {
        let frameCapacity = AVAudioFrameCount(frameCount)
        let index = reusablePCMBufferCursor
        reusablePCMBufferCursor = (reusablePCMBufferCursor + 1) % Self.reusablePCMBufferCount

        if let buffer = reusablePCMBuffers[index],
           buffer.frameCapacity >= frameCapacity {
            buffer.frameLength = 0
            return buffer
        }

        let buffer = AVAudioPCMBuffer(
            pcmFormat: audioFormat,
            frameCapacity: frameCapacity
        )
        reusablePCMBuffers[index] = buffer
        return buffer
    }

    private func resetReusablePCMBuffers() {
        conversionLock.lock()
        reusablePCMBuffers = [AVAudioPCMBuffer?](
            repeating: nil,
            count: Self.reusablePCMBufferCount
        )
        reusablePCMBufferCursor = 0
        conversionLock.unlock()
    }
}
