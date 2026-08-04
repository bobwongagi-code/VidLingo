import AppKit
import SwiftUI
import VidLingoCore

struct TimelineTranscriptPane: View {
    let segments: [TimedTranscriptSegment]
    let fallbackTranslation: String
    let seekPreview: ((Int) -> Void)?
    @State private var isCopyFeedbackVisible = false

    private var hasSegmentTranslations: Bool {
        segments.allSatisfy(\.hasTranslation)
    }

    private var description: String {
        guard hasSegmentTranslations else { return AppText.timelineFallbackDescription }
        return seekPreview == nil
            ? AppText.savedTimelineDescription
            : AppText.timelineDescription
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppText.timelineTitle)
                        .font(.headline.weight(.semibold))
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    copyTimeline()
                } label: {
                    Image(systemName: isCopyFeedbackVisible ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(AppText.copyTimeline)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(segments) { segment in
                        if let seekPreview {
                            Button {
                                seekPreview(segment.startMilliseconds)
                            } label: {
                                segmentRow(segment)
                            }
                            .buttonStyle(.plain)
                            .help(AppText.seekTimelineSegment)
                        } else {
                            segmentRow(segment)
                        }
                        Divider()
                    }
                }
            }

            if !hasSegmentTranslations {
                VStack(alignment: .leading, spacing: 6) {
                    Text(AppText.timelineTranslationFallback)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(fallbackTranslation)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 8)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private func segmentRow(_ segment: TimedTranscriptSegment) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(Self.timeRange(for: segment))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 92, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(segment.sourceText)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                if let translatedText = segment.translatedText,
                   !translatedText.isEmpty {
                    Text(translatedText)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func copyTimeline() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SRTTimelineCodec.encode(segments), forType: .string)
        isCopyFeedbackVisible = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            isCopyFeedbackVisible = false
        }
    }

    private static func timeRange(for segment: TimedTranscriptSegment) -> String {
        "\(timecode(segment.startMilliseconds)) - \(timecode(segment.endMilliseconds))"
    }

    private static func timecode(_ milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds) / 1_000
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}
