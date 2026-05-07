import Foundation

/// User-facing configuration. Persisted at `~/.config/voicepaste/config.json`.
///
/// API keys are NOT stored here — they live in macOS Keychain (see
/// `KeychainStore`). Legacy `apiKey` (and old `openrouterApiKey`) values are
/// auto-migrated to Keychain on first load and then stripped from disk.
struct Config: Codable {
    /// Provider identifier: "openrouter", "openai", "groq".
    var providerId: String = "openrouter"

    /// Model name for the selected provider, e.g. "openai/whisper-1",
    /// "whisper-1", or "whisper-large-v3".
    var providerModel: String = "openai/whisper-1"

    /// Optional ISO 639-1 language hint passed to the provider (e.g. "ru").
    var language: String?

    /// Auto-stop after this many seconds of (user-gated) silence.
    var silenceDuration: Double = 5.0

    /// Legacy RMS-amplitude threshold for the no-VAD path.
    var silenceThreshold: Float = 0.01

    var vadEnabled: Bool = true
    var vadThreshold: Float = 0.5
    var audioFilterEnabled: Bool = true
    var liveSpeakerVerification: Bool = true

    // Legacy fields retained for one-time migration. Never written back.
    var apiKey: String? = nil
    var baseURL: String? = nil
    var model: String? = nil
    var openrouterApiKey: String? = nil

    static let configDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/voicepaste")
    }()

    static let configPath: URL = {
        configDir.appendingPathComponent("config.json")
    }()

    /// Tolerant decoder so future fields don't break old binaries and missing
    /// fields fall back to defaults instead of nuking the file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.providerId = (try? c.decode(String.self, forKey: .providerId)) ?? "openrouter"
        self.providerModel = (try? c.decode(String.self, forKey: .providerModel)) ?? "openai/whisper-1"
        self.language = try? c.decodeIfPresent(String.self, forKey: .language)
        self.silenceDuration = (try? c.decode(Double.self, forKey: .silenceDuration)) ?? 5.0
        self.silenceThreshold = (try? c.decode(Float.self, forKey: .silenceThreshold)) ?? 0.01
        self.vadEnabled = (try? c.decode(Bool.self, forKey: .vadEnabled)) ?? true
        self.vadThreshold = (try? c.decode(Float.self, forKey: .vadThreshold)) ?? 0.5
        self.audioFilterEnabled = (try? c.decode(Bool.self, forKey: .audioFilterEnabled)) ?? true
        self.liveSpeakerVerification = (try? c.decode(Bool.self, forKey: .liveSpeakerVerification)) ?? true
        self.apiKey = try? c.decodeIfPresent(String.self, forKey: .apiKey)
        self.baseURL = try? c.decodeIfPresent(String.self, forKey: .baseURL)
        self.model = try? c.decodeIfPresent(String.self, forKey: .model)
        self.openrouterApiKey = try? c.decodeIfPresent(String.self, forKey: .openrouterApiKey)
    }

    init(
        providerId: String = "openrouter",
        providerModel: String = "openai/whisper-1",
        language: String? = nil,
        silenceDuration: Double = 5.0,
        silenceThreshold: Float = 0.01,
        vadEnabled: Bool = true,
        vadThreshold: Float = 0.5,
        audioFilterEnabled: Bool = true,
        liveSpeakerVerification: Bool = true
    ) {
        self.providerId = providerId
        self.providerModel = providerModel
        self.language = language
        self.silenceDuration = silenceDuration
        self.silenceThreshold = silenceThreshold
        self.vadEnabled = vadEnabled
        self.vadThreshold = vadThreshold
        self.audioFilterEnabled = audioFilterEnabled
        self.liveSpeakerVerification = liveSpeakerVerification
    }

    /// Encode only the live fields. Legacy keys are NOT written.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(providerId, forKey: .providerId)
        try c.encode(providerModel, forKey: .providerModel)
        try c.encodeIfPresent(language, forKey: .language)
        try c.encode(silenceDuration, forKey: .silenceDuration)
        try c.encode(silenceThreshold, forKey: .silenceThreshold)
        try c.encode(vadEnabled, forKey: .vadEnabled)
        try c.encode(vadThreshold, forKey: .vadThreshold)
        try c.encode(audioFilterEnabled, forKey: .audioFilterEnabled)
        try c.encode(liveSpeakerVerification, forKey: .liveSpeakerVerification)
    }

    enum CodingKeys: String, CodingKey {
        case providerId, providerModel, language
        case silenceDuration, silenceThreshold
        case vadEnabled, vadThreshold, audioFilterEnabled, liveSpeakerVerification
        // legacy
        case apiKey, baseURL, model, openrouterApiKey
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: configPath) else {
            return Config.defaultConfig
        }
        let decoder = JSONDecoder()
        guard var config = try? decoder.decode(Config.self, from: data) else {
            print("[VoicePaste] Config decode failed; using defaults")
            return Config.defaultConfig
        }

        // ---- One-time migration of legacy fields ----
        var migrated = false

        // Map legacy baseURL -> providerId (best-effort).
        if let legacyBase = config.baseURL?.lowercased() {
            if legacyBase.contains("openrouter") {
                config.providerId = "openrouter"
            } else if legacyBase.contains("groq") {
                config.providerId = "groq"
            } else if legacyBase.contains("openai") {
                config.providerId = "openai"
            }
            migrated = true
        }

        // Map legacy `model` (only if providerModel still default).
        if let legacyModel = config.model, !legacyModel.isEmpty,
           config.providerModel == "openai/whisper-1" {
            config.providerModel = legacyModel
            migrated = true
        }

        // Move any legacy keys into Keychain.
        if let legacyKey = config.apiKey, !legacyKey.isEmpty {
            try? KeychainStore.setKey(legacyKey, forProvider: config.providerId)
            migrated = true
        }
        if let legacyOR = config.openrouterApiKey, !legacyOR.isEmpty {
            try? KeychainStore.setKey(legacyOR, forProvider: "openrouter")
            migrated = true
        }

        // Drop legacy fields and rewrite the file once.
        config.apiKey = nil
        config.baseURL = nil
        config.model = nil
        config.openrouterApiKey = nil
        if migrated {
            try? config.save()
            print("[VoicePaste] Migrated legacy config fields into Keychain")
        }

        return config
    }

    static let defaultConfig = Config(
        providerId: "openrouter",
        providerModel: "openai/whisper-1",
        language: nil,
        silenceDuration: 5.0,
        silenceThreshold: 0.01,
        vadEnabled: true,
        vadThreshold: 0.5,
        audioFilterEnabled: true,
        liveSpeakerVerification: true
    )

    func save() throws {
        try FileManager.default.createDirectory(at: Config.configDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: Config.configPath, options: .atomic)
    }
}
