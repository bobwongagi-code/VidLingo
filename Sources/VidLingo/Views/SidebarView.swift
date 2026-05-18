import SwiftUI

struct SidebarView: View {
    @Bindable var session: TranslationSessionStore
    @State private var apiKey = ""
    @State private var isLibraryPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                appHeader
                languageSection
                apiKeySection
                librarySection
            }
            .padding(18)
        }
        .background(.bar)
        .sheet(isPresented: $isLibraryPresented) {
            TranscriptLibraryView(session: session)
        }
    }

    private var appHeader: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(AppText.appName)
                    .font(.title3.weight(.semibold))
                Text(AppText.shortVideoOfflineTranslator)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppText.languages)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Toggle(AppText.autoDetectInput, isOn: $session.isSourceAutoDetectionEnabled)

            HStack {
                Text(AppText.from)
                    .foregroundStyle(.secondary)
                Picker(AppText.from, selection: $session.sourceLanguage) {
                    ForEach(LanguageOption.supported) { language in
                        Text(language.localizedTitle).tag(language)
                    }
                }
                .labelsHidden()
                .disabled(session.isSourceAutoDetectionEnabled || session.isOfflineVideoProcessing)
            }

            HStack {
                Text(AppText.to)
                    .foregroundStyle(.secondary)
                Picker(AppText.to, selection: $session.targetLanguage) {
                    ForEach(LanguageOption.supported) { language in
                        Text(language.localizedTitle).tag(language)
                    }
                }
                .labelsHidden()
                .disabled(session.isOfflineVideoProcessing)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppText.deepSeekAPIKey)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            SecureField(AppText.deepSeekAPIKeyPlaceholder, text: $apiKey)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text(session.hasDeepSeekAPIKey ? AppText.deepSeekAPIKeyConfigured : AppText.deepSeekAPIKeyNotConfigured)
                    .font(.caption)
                    .foregroundStyle(session.hasDeepSeekAPIKey ? .green : .secondary)
                Spacer()
                Button(AppText.saveDeepSeekAPIKey) {
                    session.saveDeepSeekAPIKey(apiKey)
                    apiKey = ""
                }
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Button(AppText.removeDeepSeekAPIKey) {
                session.removeDeepSeekAPIKey()
                apiKey = ""
            }
            .disabled(!session.hasDeepSeekAPIKey)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppText.savedTranscripts)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(AppText.autoSaveDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                isLibraryPresented = true
            } label: {
                Label(AppText.manageSavedTranscripts, systemImage: "tray.full")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                session.openTranscriptsFolder()
            } label: {
                Label(AppText.openSaveFolder, systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
