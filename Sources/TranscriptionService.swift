import Foundation

/// Thin wrapper that picks a `TranscriptionProvider` based on `Config` and
/// fetches the API key from Keychain at call time. Holding the key on the
/// stack (not in a stored property) avoids stale-key bugs after Settings save.
class TranscriptionService {
    private let providerId: String
    private let model: String
    private let language: String?

    init(config: Config) {
        self.providerId = config.providerId
        self.model = config.providerModel
        self.language = config.language
    }

    func transcribe(fileURL: URL) async throws -> String {
        let provider = ProviderRegistry.provider(forId: providerId)
        let apiKey = KeychainStore.getKey(forProvider: providerId) ?? ""
        return try await provider.transcribe(
            fileURL: fileURL, model: model, language: language, apiKey: apiKey
        )
    }
}

// MARK: - Helpers (used by TranscriptionProvider's multipart bodies)

extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }

    mutating func appendField(name: String, value: String, boundary: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        appendString("\(value)\r\n")
    }
}
