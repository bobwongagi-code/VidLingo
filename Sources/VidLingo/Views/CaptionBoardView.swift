import AppKit
import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct CaptionBoardView: View {
    @Bindable var session: TranslationSessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OfflineVideoImportPanel(
                session: session,
                importVideo: openOfflineVideoPanel,
                startTranslation: session.startOfflineVideoTranslation
            )

            TranscriptResultView(session: session)
        }
        .padding(24)
    }

    private func openOfflineVideoPanel() {
        let panel = NSOpenPanel()
        panel.title = AppText.importVideo
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.quickTimeMovie, .mpeg4Movie, .movie]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        session.selectOfflineVideo(url)
    }
}

private struct OfflineVideoImportPanel: View {
    @Bindable var session: TranslationSessionStore
    let importVideo: () -> Void
    let startTranslation: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "film.stack.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(AppText.shortVideoOfflineTranslator)
                        .font(.headline.weight(.semibold))
                    Text(session.statusMessage)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(session.isOfflineVideoProcessing ? Color.accentColor : Color.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                if session.isOfflineVideoProcessing {
                    ProcessingStatusPill(text: AppText.processing)
                } else {
                    Button(action: importVideo) {
                        Label(AppText.importVideo, systemImage: "plus.rectangle.on.folder")
                            .font(.callout.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            HStack(spacing: 10) {
                Text(AppText.productContext)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)

                TextField(AppText.productContextPlaceholder, text: $session.offlineVideoProductContext)
                    .textFieldStyle(.roundedBorder)
                    .disabled(session.isOfflineVideoProcessing)

                Button(AppText.clearProductContext) {
                    session.clearProductContext()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(session.isOfflineVideoProcessing || session.offlineVideoProductContext.isEmpty)
                .help(AppText.clearProductContext)
            }

            Toggle(AppText.inferProductContext, isOn: $session.isProductContextInferenceEnabled)
                .font(.caption.weight(.medium))
                .disabled(session.isOfflineVideoProcessing)
                .help(AppText.inferringProductContextHelp)

            if let videoURL = session.offlineVideoURL {
                OfflineVideoPreviewCard(
                    videoURL: videoURL,
                    fileName: session.offlineVideoFileName,
                    durationText: session.offlineVideoDurationText,
                    isProcessing: session.isOfflineVideoProcessing,
                    canStartTranslation: !session.isOfflineVideoProcessing,
                    startTranslation: startTranslation
                )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct OfflineVideoPreviewCard: View {
    let videoURL: URL
    let fileName: String
    let durationText: String
    let isProcessing: Bool
    let canStartTranslation: Bool
    let startTranslation: () -> Void
    @State private var thumbnail: NSImage?
    @State private var isPreviewVisible = false
    @State private var player: AVPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Button {
                    togglePreview()
                } label: {
                    ZStack {
                        thumbnailView
                        Image(systemName: isPreviewVisible ? "pause.fill" : "play.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(.black.opacity(0.42), in: Circle())
                    }
                    .frame(width: 112, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(isPreviewVisible ? AppText.hidePreview : AppText.playPreview)

                VStack(alignment: .leading, spacing: 4) {
                    Text(AppText.selectedVideo)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(fileName.isEmpty ? videoURL.lastPathComponent : fileName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(videoMetaText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 10)

                if isProcessing {
                    ProcessingStatusPill(text: AppText.processingVideo)
                } else {
                    Button {
                        togglePreview()
                    } label: {
                        Label(isPreviewVisible ? AppText.hidePreview : AppText.playPreview, systemImage: isPreviewVisible ? "chevron.up" : "play.rectangle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        startTranslation()
                    } label: {
                        Label(AppText.startOfflineTranslation, systemImage: "text.bubble.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!canStartTranslation)
                }
            }

            if isPreviewVisible {
                VideoPlayer(player: player)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: videoURL) {
            thumbnail = await Self.makeThumbnail(for: videoURL)
        }
        .onChange(of: videoURL) { _, newURL in
            player?.pause()
            player = AVPlayer(url: newURL)
            isPreviewVisible = false
        }
        .onAppear {
            if player == nil {
                player = AVPlayer(url: videoURL)
            }
        }
        .onDisappear {
            player?.pause()
        }
        .animation(.snappy(duration: 0.18), value: isPreviewVisible)
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Rectangle()
                    .fill(.black.opacity(0.72))
                Image(systemName: "film")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
            }
        }
    }

    private var videoMetaText: String {
        let duration = durationText.isEmpty ? "" : " · \(durationText)"
        return AppText.confirmVideoContent + duration
    }

    private func togglePreview() {
        if isPreviewVisible {
            player?.pause()
            isPreviewVisible = false
        } else {
            if player == nil {
                player = AVPlayer(url: videoURL)
            }
            isPreviewVisible = true
            player?.seek(to: .zero)
            player?.play()
        }
    }

    private static func makeThumbnail(for videoURL: URL) async -> NSImage? {
        await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: videoURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 360, height: 220)
            let requestedTime = CMTime(seconds: 0.35, preferredTimescale: 600)

            return await withCheckedContinuation { continuation in
                generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: requestedTime)]) { _, cgImage, _, result, _ in
                    guard result == .succeeded, let cgImage else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: NSImage(cgImage: cgImage, size: .zero))
                }
            }
        }.value
    }
}

private struct ProcessingStatusPill: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.72)

            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.055), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.primary.opacity(0.08))
        }
        .accessibilityLabel(text)
    }
}

private struct TranscriptResultView: View {
    @Bindable var session: TranslationSessionStore

    var body: some View {
        if let line = session.lines.last {
            HStack(alignment: .top, spacing: 16) {
                TranscriptPane(title: AppText.original, description: AppText.originalDescription, text: line.sourceText)
                TranscriptPane(title: AppText.translation, description: AppText.translationDescription, text: line.translatedText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                AppText.noCaptionsYet,
                systemImage: "captions.bubble",
                description: Text(AppText.noCaptionsDescription)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

private struct TranscriptPane: View {
    let title: String
    let description: String
    let text: String
    @State private var isCopyFeedbackVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    copyText()
                } label: {
                    Image(systemName: isCopyFeedbackVisible ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text(description)
                .font(.caption)
                .foregroundStyle(.tertiary)

            ScrollView {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        isCopyFeedbackVisible = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            isCopyFeedbackVisible = false
        }
    }
}
