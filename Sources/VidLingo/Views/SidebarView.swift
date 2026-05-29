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
                modelSection
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

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppText.translationModelSettings)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker(AppText.translationProvider, selection: $session.translationProvider) {
                ForEach(TranslationProviderID.allCases) { provider in
                    Text(provider.title).tag(provider)
                }
            }
            .pickerStyle(.menu)
            .disabled(session.isOfflineVideoProcessing)

            TextField(AppText.translationModelPlaceholder, text: $session.translationModelName)
                .textFieldStyle(.roundedBorder)
                .disabled(session.isOfflineVideoProcessing)

            if session.translationProvider == .custom {
                TextField(AppText.translationEndpointPlaceholder, text: $session.customTranslationBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .disabled(session.isOfflineVideoProcessing)
            }

            SecureField(AppText.translationAPIKeyPlaceholder(session.translationProvider.title), text: $apiKey)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text(session.hasTranslationAPIKey ? AppText.translationAPIKeyConfigured : AppText.translationAPIKeyNotConfigured)
                    .font(.caption)
                    .foregroundStyle(session.hasTranslationAPIKey ? .green : .secondary)
                Spacer()
                Button(AppText.saveTranslationAPIKey) {
                    session.saveTranslationAPIKey(apiKey)
                    apiKey = ""
                }
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Button(AppText.removeTranslationAPIKey) {
                session.removeTranslationAPIKey()
                apiKey = ""
            }
            .disabled(!session.hasTranslationAPIKey)
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

