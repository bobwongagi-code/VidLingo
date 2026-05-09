import SwiftUI

struct StreamingTranscriptText: View {
    let text: String
    let font: Font
    var foregroundColor = Color.primary
    var isTextSelectionEnabled = true
    var lineLimit: Int?
    var textAlignment: TextAlignment = .leading
    var frameAlignment: Alignment = .topLeading
    var truncationMode: Text.TruncationMode = .head

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var settledText = ""
    @State private var appearingText = ""
    @State private var appearingOpacity = 1.0
    @State private var streamTask: Task<Void, Never>?

    var body: some View {
        textView
            .onAppear {
                stream(to: text)
            }
            .onChange(of: text) { _, newText in
                stream(to: newText)
            }
            .onDisappear {
                streamTask?.cancel()
            }
    }

    @ViewBuilder
    private var textView: some View {
        if isTextSelectionEnabled {
            baseText.textSelection(.enabled)
        } else {
            baseText.textSelection(.disabled)
        }
    }

    private var baseText: some View {
        Text(renderedText)
            .font(font)
            .foregroundStyle(foregroundColor)
            .lineLimit(lineLimit)
            .multilineTextAlignment(textAlignment)
            .truncationMode(truncationMode)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    private var renderedText: AttributedString {
        var rendered = AttributedString(settledText)
        var appearing = AttributedString(appearingText)
        appearing.foregroundColor = foregroundColor.opacity(appearingOpacity)
        rendered.append(appearing)
        return rendered
    }

    private var visibleText: String {
        settledText + appearingText
    }

    private func stream(to newText: String) {
        streamTask?.cancel()

        if !appearingText.isEmpty {
            settledText += appearingText
            appearingText = ""
            appearingOpacity = 1
        }

        guard !newText.isEmpty else {
            settledText = ""
            appearingText = ""
            return
        }

        guard !reduceMotion else {
            settledText = newText
            return
        }

        guard newText.hasPrefix(visibleText), newText.count > visibleText.count else {
            settledText = newText
            appearingText = ""
            appearingOpacity = 1
            return
        }

        let remainingText = String(newText.dropFirst(visibleText.count))
        let chunkSize = remainingText.count > 72 ? 8 : (remainingText.count > 28 ? 6 : 4)
        let delay = remainingText.count > 72 ? 10_000_000 : (remainingText.count > 28 ? 14_000_000 : 18_000_000)
        let fadeDuration = remainingText.count > 72 ? 0.08 : 0.12
        let chunks = remainingText.chunkedForTranscriptStreaming(maxCharacters: chunkSize)

        streamTask = Task { @MainActor in
            for chunk in chunks {
                if Task.isCancelled {
                    return
                }

                if !appearingText.isEmpty {
                    settledText += appearingText
                }

                appearingText = chunk
                appearingOpacity = 0.12

                withAnimation(.easeOut(duration: fadeDuration)) {
                    appearingOpacity = 1
                }

                try? await Task.sleep(nanoseconds: UInt64(delay))
            }

            if !appearingText.isEmpty {
                settledText += appearingText
                appearingText = ""
                appearingOpacity = 1
            }
        }
    }
}

private extension String {
    func chunkedForTranscriptStreaming(maxCharacters: Int) -> [String] {
        guard maxCharacters > 0 else { return [self] }

        var chunks: [String] = []
        var current = ""

        for character in self {
            current.append(character)
            if current.count >= maxCharacters || character.isWhitespace || character.isPunctuation {
                chunks.append(current)
                current = ""
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        return chunks
    }
}
