import SwiftUI
import VidLingoCore

struct SidebarView: View {
    @Bindable var session: TranslationSessionStore
    @State private var apiKeyDraft: (identity: String, text: String)?
    @State private var funASRAPIKey = ""
    @State private var isLibraryPresented = false

    private var currentAPIKeyDraft: String {
        guard let apiKeyDraft, apiKeyDraft.identity == session.translationCredentialIdentity else { return "" }
        return apiKeyDraft.text
    }

    private var apiKeyBinding: Binding<String> {
        let identity = session.translationCredentialIdentity
        return Binding(
            get: { currentAPIKeyDraft },
            set: { text in
                guard session.translationCredentialIdentity == identity else { return }
                apiKeyDraft = (identity, text)
            }
        )
    }

    private var translationKeyStatus: String {
        if session.translationProvider == .custom, session.translationAPIKeyAvailability == .missing {
            return AppText.customEndpointAPIKeyMissing
        }
        return AppText.keychainAvailabilityText(session.translationAPIKeyAvailability)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                appHeader
                languageSection
                processingPermissionsSection
                modelSection
                librarySection
            }
            .padding(18)
        }
        .background(.bar)
        .onChange(of: session.translationCredentialIdentity) { _, identity in
            if apiKeyDraft?.identity != identity { apiKeyDraft = nil }
        }
        .sheet(isPresented: $isLibraryPresented) {
            TranscriptLibraryView(session: session)
        }
    }

    private var processingPermissionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppText.processingPermissions)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Toggle(AppText.cloudAudioTranscriptionConsent, isOn: $session.allowsCloudAudioTranscription)
                .disabled(session.isOfflineVideoProcessing)
            Toggle(AppText.cloudVideoFramesConsent, isOn: $session.allowsCloudVideoFrames)
                .disabled(session.isOfflineVideoProcessing)
            Toggle(AppText.visualSalesCopyConsent, isOn: $session.allowsVisualSalesCopy)
                .disabled(session.isOfflineVideoProcessing)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                Text("简体中文")
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
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

            DisclosureGroup("管理密钥") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("翻译 API key")
                        .font(.caption.weight(.semibold))
                    SecureField(
                        AppText.translationAPIKeyPlaceholder(session.translationProvider.title),
                        text: apiKeyBinding
                    )
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Text(translationKeyStatus)
                            .font(.caption)
                            .foregroundStyle(session.translationAPIKeyAvailability == .configured ? .green : .secondary)
                        Spacer()
                        Button(AppText.saveTranslationAPIKey) {
                            let key = currentAPIKeyDraft
                            guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                            session.saveTranslationAPIKey(key)
                            apiKeyDraft = nil
                        }
                        .disabled(currentAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    Button(AppText.removeTranslationAPIKey) {
                        session.removeTranslationAPIKey()
                        apiKeyDraft = nil
                    }
                    .disabled(!session.hasTranslationAPIKey)

                    Divider()
                    Text("Fun-ASR API key")
                        .font(.caption.weight(.semibold))
                    SecureField("粘贴 Fun-ASR API key", text: $funASRAPIKey)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Text(AppText.keychainAvailabilityText(session.funASRAPIKeyAvailability))
                            .font(.caption)
                            .foregroundStyle(session.hasFunASRAPIKey ? .green : .secondary)
                        Spacer()
                        Button(AppText.saveTranslationAPIKey) {
                            session.saveFunASRAPIKey(funASRAPIKey)
                            funASRAPIKey = ""
                        }
                        .disabled(funASRAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    Button(AppText.removeTranslationAPIKey) {
                        session.removeFunASRAPIKey()
                        funASRAPIKey = ""
                    }
                    .disabled(!session.hasFunASRAPIKey)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
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

            Button {
                session.clearDiagnostics()
            } label: {
                Label(AppText.clearDiagnostics, systemImage: "waveform.path.ecg")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
