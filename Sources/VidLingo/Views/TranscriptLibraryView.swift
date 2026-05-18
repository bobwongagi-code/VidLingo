import AppKit
import SwiftUI

private enum DraftEditorField: Hashable {
    case source
    case translation
}

struct TranscriptLibraryView: View {
    @Bindable var session: TranslationSessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var isDeleteAllConfirmationPresented = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(18)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 760, height: 500)
        .confirmationDialog(
            AppText.deleteAllSavedTranscriptsConfirmation,
            isPresented: $isDeleteAllConfirmationPresented
        ) {
            Button(AppText.deleteAllSavedTranscripts, role: .destructive) {
                session.deleteAllSavedTranscripts()
            }
            Button(AppText.close, role: .cancel) {}
        }
        .onAppear {
            ensureSelection()
        }
        .onChange(of: session.savedTranscripts.count) { _, _ in
            ensureSelection()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.full")
                .font(.title3)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 3) {
                Text(AppText.savedTranscripts)
                    .font(.title3.weight(.semibold))
                Text(AppText.autoSaveDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            Button {
                session.openTranscriptsFolder()
            } label: {
                Label(AppText.openSaveFolder, systemImage: "folder")
            }

            Button(role: .destructive) {
                isDeleteAllConfirmationPresented = true
            } label: {
                Label(AppText.deleteAllSavedTranscripts, systemImage: "trash")
            }
            .disabled(session.savedTranscripts.isEmpty)

            Button(AppText.close) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder
    private var content: some View {
        if session.savedTranscripts.isEmpty {
            ContentUnavailableView(
                AppText.savedEmpty,
                systemImage: "tray",
                description: Text(AppText.autoSaveDescription)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                transcriptList
                    .frame(width: 260)

                Divider()

                editor
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var transcriptList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(session.savedTranscripts) { transcript in
                    Button {
                        session.selectSavedTranscript(transcript.id)
                    } label: {
                        TranscriptLibraryRow(
                            transcript: transcript,
                            isSelected: session.selectedSavedTranscriptID == transcript.id
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
        .background(.bar)
    }

    @ViewBuilder
    private var editor: some View {
        if session.selectedSavedTranscript != nil {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(AppText.editSaved)
                        .font(.headline)
                    Spacer()
                    Button {
                        copyDraftText()
                    } label: {
                        Label(AppText.copy, systemImage: "clipboard")
                    }
                }

                HStack(alignment: .top, spacing: 12) {
                    draftEditorPane(title: AppText.original, text: $session.savedDraftSourceText)
                    draftEditorPane(title: AppText.translation, text: $session.savedDraftTranslationText)
                }

                HStack {
                    Button {
                        session.saveSelectedTranscriptEdits()
                    } label: {
                        Label(AppText.saveEdits, systemImage: "checkmark")
                    }
                    .keyboardShortcut("s", modifiers: [.command])

                    Spacer()

                    Button(role: .destructive) {
                        session.deleteSelectedTranscript()
                    } label: {
                        Label(AppText.deleteSavedTranscript, systemImage: "trash")
                    }
                }
            }
            .padding(18)
        } else {
            ContentUnavailableView(AppText.noSavedTranscriptSelected, systemImage: "doc.text")
        }
    }

    private func draftEditorPane(title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            TextEditor(text: text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copyDraftText() {
        let sourceText = session.savedDraftSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let translatedText = session.savedDraftTranslationText.trimmingCharacters(in: .whitespacesAndNewlines)
        let copiedText = "\(AppText.original)\n\(sourceText)\n\n\(AppText.translation)\n\(translatedText)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copiedText, forType: .string)
    }

    private func ensureSelection() {
        if let selectedSavedTranscriptID = session.selectedSavedTranscriptID,
           session.savedTranscripts.contains(where: { $0.id == selectedSavedTranscriptID }) {
            return
        }

        if let firstTranscript = session.savedTranscripts.first {
            session.selectSavedTranscript(firstTranscript.id)
        }
    }
}

private struct TranscriptLibraryRow: View {
    let transcript: SavedTranscript
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: transcript.isOriginalAndTranslation ? "doc.on.doc.fill" : "doc.text")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(transcript.title)
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                Text(transcript.updatedAt, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
