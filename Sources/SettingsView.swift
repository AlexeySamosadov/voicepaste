import SwiftUI
import AppKit

/// Settings window — provider, model, API key, and the audio knobs that
/// previously required hand-editing `~/.config/voicepaste/config.json`.
@MainActor
struct SettingsView: View {
    @ObservedObject var store: VoiceStore
    var onClose: () -> Void

    // Provider + model + key (mirrored from store.config / Keychain on appear).
    @State private var providerId: String = "openrouter"
    @State private var selectedModel: String = "openai/whisper-1"
    @State private var customModel: String = ""
    @State private var useCustomModel: Bool = false
    @State private var apiKey: String = ""

    // Audio knobs.
    @State private var vadEnabled: Bool = true
    @State private var vadThreshold: Double = 0.5
    @State private var audioFilterEnabled: Bool = true
    @State private var liveSpeakerVerification: Bool = true
    @State private var silenceDuration: Double = 5.0
    @State private var language: String = ""

    // Test Connection state.
    @State private var isTesting: Bool = false
    @State private var testResultGood: Bool? = nil
    @State private var testMessage: String = ""

    private var provider: TranscriptionProvider {
        ProviderRegistry.provider(forId: providerId)
    }

    private var effectiveModel: String {
        useCustomModel ? customModel : selectedModel
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("VoicePaste Settings")
                    .font(.title2)
                    .bold()

                providerSection
                Divider()
                audioSection
                Divider()
                footer
            }
            .padding(20)
        }
        .frame(width: 480, height: 600)
        .onAppear(perform: loadFromStore)
    }

    // MARK: - Sections

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcription Provider")
                .font(.headline)

            HStack {
                Text("Provider")
                    .frame(width: 80, alignment: .leading)
                Picker("", selection: $providerId) {
                    ForEach(ProviderRegistry.all, id: \.id) { p in
                        Text(p.displayName).tag(p.id)
                    }
                }
                .labelsHidden()
                .onChange(of: providerId) { _, newId in
                    onProviderChanged(to: newId)
                }
            }

            HStack(alignment: .top) {
                Text("Model")
                    .frame(width: 80, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    Picker("", selection: Binding(
                        get: { useCustomModel ? "__custom__" : selectedModel },
                        set: { newValue in
                            if newValue == "__custom__" {
                                useCustomModel = true
                            } else {
                                useCustomModel = false
                                selectedModel = newValue
                            }
                        }
                    )) {
                        ForEach(provider.availableModels, id: \.self) { m in
                            Text(m).tag(m)
                        }
                        Text("Custom...").tag("__custom__")
                    }
                    .labelsHidden()

                    if useCustomModel {
                        TextField("e.g. whisper-large-v3", text: $customModel)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            HStack {
                Text("API Key")
                    .frame(width: 80, alignment: .leading)
                SecureField("Paste API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Text("Language")
                    .frame(width: 80, alignment: .leading)
                TextField("optional, e.g. ru / en", text: $language)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 10) {
                Button {
                    runTestConnection()
                } label: {
                    if isTesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Test Connection")
                    }
                }
                .disabled(isTesting || apiKey.isEmpty)

                if let ok = testResultGood {
                    HStack(spacing: 4) {
                        Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(ok ? .green : .red)
                        Text(testMessage)
                            .font(.caption)
                            .foregroundColor(ok ? .green : .red)
                            .lineLimit(2)
                    }
                }
                Spacer()
            }

            Text("API keys are stored in macOS Keychain, never in config.json.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Audio")
                .font(.headline)

            Toggle("Voice activity detection (Silero VAD)", isOn: $vadEnabled)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("VAD threshold")
                    Spacer()
                    Text(String(format: "%.2f", vadThreshold))
                        .foregroundColor(.secondary)
                        .font(.system(.caption, design: .monospaced))
                }
                Slider(value: $vadThreshold, in: 0...1)
                HStack {
                    Text("More permissive")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("More strict")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .disabled(!vadEnabled)

            Toggle("80–3400 Hz bandpass filter", isOn: $audioFilterEnabled)

            Toggle("Only transcribe my voice (speaker verification)",
                   isOn: $liveSpeakerVerification)

            HStack {
                Text("Silence auto-stop after")
                Stepper(value: $silenceDuration, in: 1...30, step: 1) {
                    Text("\(Int(silenceDuration)) s")
                        .frame(minWidth: 40, alignment: .trailing)
                        .font(.system(.body, design: .monospaced))
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { onClose() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Actions

    private func loadFromStore() {
        let cfg = store.config!
        providerId = cfg.providerId
        let p = ProviderRegistry.provider(forId: providerId)
        if p.availableModels.contains(cfg.providerModel) {
            selectedModel = cfg.providerModel
            useCustomModel = false
        } else {
            selectedModel = p.defaultModel
            customModel = cfg.providerModel
            useCustomModel = true
        }
        apiKey = KeychainStore.getKey(forProvider: providerId) ?? ""
        vadEnabled = cfg.vadEnabled
        vadThreshold = Double(cfg.vadThreshold)
        audioFilterEnabled = cfg.audioFilterEnabled
        liveSpeakerVerification = cfg.liveSpeakerVerification
        silenceDuration = cfg.silenceDuration
        language = cfg.language ?? ""
    }

    private func onProviderChanged(to newId: String) {
        let p = ProviderRegistry.provider(forId: newId)
        // Reset model to that provider's default.
        selectedModel = p.defaultModel
        useCustomModel = false
        customModel = ""
        // Load whichever key the user previously saved for this provider.
        apiKey = KeychainStore.getKey(forProvider: newId) ?? ""
        // Clear any stale test result.
        testResultGood = nil
        testMessage = ""
    }

    private func runTestConnection() {
        let provider = self.provider
        let key = apiKey
        let model = effectiveModel
        isTesting = true
        testResultGood = nil
        testMessage = ""
        Task {
            do {
                try await provider.testConnection(apiKey: key, model: model)
                await MainActor.run {
                    isTesting = false
                    testResultGood = true
                    testMessage = "OK"
                }
            } catch {
                await MainActor.run {
                    isTesting = false
                    testResultGood = false
                    testMessage = error.localizedDescription
                }
            }
        }
    }

    private func save() {
        // 1. Persist the API key for the selected provider.
        try? KeychainStore.setKey(apiKey, forProvider: providerId)

        // 2. Build the new config.
        var cfg = store.config!
        cfg.providerId = providerId
        cfg.providerModel = effectiveModel.isEmpty ? provider.defaultModel : effectiveModel
        cfg.language = language.isEmpty ? nil : language
        cfg.vadEnabled = vadEnabled
        cfg.vadThreshold = Float(vadThreshold)
        cfg.audioFilterEnabled = audioFilterEnabled
        cfg.liveSpeakerVerification = liveSpeakerVerification
        cfg.silenceDuration = silenceDuration

        // 3. Save and trigger a config reload in VoiceStore.
        do {
            try cfg.save()
            store.loadConfig()
            NotificationCenter.default.post(name: .voicePasteConfigChanged, object: nil)
            onClose()
        } catch {
            testResultGood = false
            testMessage = "Save failed: \(error.localizedDescription)"
        }
    }
}
