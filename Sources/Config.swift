import Foundation

struct Config: Codable {
    var apiKey: String
    var baseURL: String
    var model: String
    var language: String?
    var silenceDuration: Double
    var silenceThreshold: Float
    var vadEnabled: Bool = true
    var vadThreshold: Float = 0.5
    var audioFilterEnabled: Bool = true
    var liveSpeakerVerification: Bool = true

    static let configDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/voicepaste")
    }()

    static let configPath: URL = {
        configDir.appendingPathComponent("config.json")
    }()

    static func load() -> Config {
        guard let data = try? Data(contentsOf: configPath),
              let config = try? JSONDecoder().decode(Config.self, from: data) else {
            return Config.defaultConfig
        }
        return config
    }

    static let defaultConfig = Config(
        apiKey: "",
        baseURL: "https://api.openai.com/v1",
        model: "whisper-1",
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
        try data.write(to: Config.configPath)
    }
}
