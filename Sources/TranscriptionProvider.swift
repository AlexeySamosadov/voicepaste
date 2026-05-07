import Foundation

/// Abstraction over a Whisper-compatible transcription backend.
///
/// All concrete providers in VoicePaste speak the OpenAI multipart audio API
/// (POST `/audio/transcriptions` with `file` + `model`). The differences are
/// only the host, default model list, and how to validate a key.
protocol TranscriptionProvider {
    var id: String { get }
    var displayName: String { get }
    var defaultModel: String { get }
    var availableModels: [String] { get }

    /// Run a real transcription. Returns the transcript text.
    func transcribe(fileURL: URL, model: String, language: String?, apiKey: String) async throws -> String

    /// Lightweight liveness check. Throws on auth/key/model failure.
    func testConnection(apiKey: String, model: String) async throws
}

// MARK: - Errors

enum ProviderError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case http(status: Int, body: String)
    case missingKey

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid provider URL"
        case .invalidResponse: return "Invalid response from server"
        case .http(let s, let b): return "HTTP \(s): \(b)"
        case .missingKey: return "API key is empty"
        }
    }
}

// MARK: - Registry

enum ProviderRegistry {
    static let all: [TranscriptionProvider] = [
        OpenRouterProvider(),
        OpenAIProvider(),
        GroqProvider()
    ]

    static func provider(forId id: String) -> TranscriptionProvider {
        all.first(where: { $0.id == id }) ?? OpenAIProvider()
    }
}

// MARK: - OpenAI multipart helpers (shared)

enum OpenAIMultipart {
    /// Builds the standard `multipart/form-data` body that OpenAI / Groq /
    /// OpenRouter all accept on `/audio/transcriptions`.
    static func body(fileURL: URL, model: String, language: String?, boundary: String) throws -> Data {
        var body = Data()
        body.appendField(name: "model", value: model, boundary: boundary)
        if let language = language, !language.isEmpty {
            body.appendField(name: "language", value: language, boundary: boundary)
        }
        let fileData = try Data(contentsOf: fileURL)
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\n")
        body.appendString("Content-Type: audio/wav\r\n\r\n")
        body.append(fileData)
        body.appendString("\r\n")
        body.appendString("--\(boundary)--\r\n")
        return body
    }

    /// Body using raw audio bytes (used by `testConnection` with a synthetic WAV).
    static func body(fileBytes: Data, model: String, language: String?, boundary: String) -> Data {
        var body = Data()
        body.appendField(name: "model", value: model, boundary: boundary)
        if let language = language, !language.isEmpty {
            body.appendField(name: "language", value: language, boundary: boundary)
        }
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"silence.wav\"\r\n")
        body.appendString("Content-Type: audio/wav\r\n\r\n")
        body.append(fileBytes)
        body.appendString("\r\n")
        body.appendString("--\(boundary)--\r\n")
        return body
    }

    /// Posts a multipart audio request to `endpoint`, decodes `{text: ...}`.
    static func postTranscription(
        endpoint: URL,
        apiKey: String,
        body: Data,
        boundary: String,
        timeout: TimeInterval = 60
    ) async throws -> String {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout
        req.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        guard http.statusCode == 200 else {
            throw ProviderError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        struct R: Codable { let text: String }
        return try JSONDecoder().decode(R.self, from: data).text
    }

    /// 1-second silent 16 kHz mono PCM16 WAV. Used for `testConnection`.
    static func silentWav() -> Data {
        let sampleRate: UInt32 = 16000
        let numSamples: UInt32 = sampleRate
        let bitsPerSample: UInt16 = 16
        let numChannels: UInt16 = 1
        let byteRate: UInt32 = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign: UInt16 = numChannels * (bitsPerSample / 8)
        let dataSize: UInt32 = numSamples * UInt32(blockAlign)
        let chunkSize: UInt32 = 36 + dataSize

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian, Array.init))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian, Array.init))   // PCM
        data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian, Array.init))
        data.append(contentsOf: Array("data".utf8))
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian, Array.init))
        // dataSize zero-bytes (silence)
        data.append(Data(count: Int(dataSize)))
        return data
    }
}

// MARK: - OpenRouter (current default)

/// OpenRouter proxies many transcription providers behind one key. They
/// expose the same `/api/v1/audio/transcriptions` shape as OpenAI.
struct OpenRouterProvider: TranscriptionProvider {
    let id = "openrouter"
    let displayName = "OpenRouter"
    let defaultModel = "openai/whisper-1"
    let availableModels = ["openai/whisper-1"]
    let baseURL = "https://openrouter.ai/api/v1"

    func transcribe(fileURL: URL, model: String, language: String?, apiKey: String) async throws -> String {
        guard !apiKey.isEmpty else { throw ProviderError.missingKey }
        guard let endpoint = URL(string: "\(baseURL)/audio/transcriptions") else { throw ProviderError.invalidURL }
        let boundary = UUID().uuidString
        let body = try OpenAIMultipart.body(
            fileURL: fileURL, model: model, language: language, boundary: boundary
        )
        return try await OpenAIMultipart.postTranscription(
            endpoint: endpoint, apiKey: apiKey, body: body, boundary: boundary
        )
    }

    /// OpenRouter doesn't accept tiny silent audio reliably across all
    /// upstream providers, so we ping the cheap `/models` endpoint instead.
    func testConnection(apiKey: String, model: String) async throws {
        guard !apiKey.isEmpty else { throw ProviderError.missingKey }
        guard let url = URL(string: "\(baseURL)/models") else { throw ProviderError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        guard http.statusCode == 200 else {
            throw ProviderError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
    }
}

// MARK: - OpenAI

struct OpenAIProvider: TranscriptionProvider {
    let id = "openai"
    let displayName = "OpenAI"
    let defaultModel = "whisper-1"
    let availableModels = ["whisper-1"]
    let baseURL = "https://api.openai.com/v1"

    func transcribe(fileURL: URL, model: String, language: String?, apiKey: String) async throws -> String {
        guard !apiKey.isEmpty else { throw ProviderError.missingKey }
        guard let endpoint = URL(string: "\(baseURL)/audio/transcriptions") else { throw ProviderError.invalidURL }
        let boundary = UUID().uuidString
        let body = try OpenAIMultipart.body(
            fileURL: fileURL, model: model, language: language, boundary: boundary
        )
        return try await OpenAIMultipart.postTranscription(
            endpoint: endpoint, apiKey: apiKey, body: body, boundary: boundary
        )
    }

    func testConnection(apiKey: String, model: String) async throws {
        guard !apiKey.isEmpty else { throw ProviderError.missingKey }
        guard let endpoint = URL(string: "\(baseURL)/audio/transcriptions") else { throw ProviderError.invalidURL }
        let boundary = UUID().uuidString
        let body = OpenAIMultipart.body(
            fileBytes: OpenAIMultipart.silentWav(),
            model: model, language: nil, boundary: boundary
        )
        // Whisper happily transcribes silence as "" — that's still a 200 OK.
        _ = try await OpenAIMultipart.postTranscription(
            endpoint: endpoint, apiKey: apiKey, body: body, boundary: boundary, timeout: 30
        )
    }
}

// MARK: - Groq

struct GroqProvider: TranscriptionProvider {
    let id = "groq"
    let displayName = "Groq"
    let defaultModel = "whisper-large-v3"
    let availableModels = [
        "whisper-large-v3",
        "whisper-large-v3-turbo",
        "distil-whisper-large-v3-en"
    ]
    let baseURL = "https://api.groq.com/openai/v1"

    func transcribe(fileURL: URL, model: String, language: String?, apiKey: String) async throws -> String {
        guard !apiKey.isEmpty else { throw ProviderError.missingKey }
        guard let endpoint = URL(string: "\(baseURL)/audio/transcriptions") else { throw ProviderError.invalidURL }
        let boundary = UUID().uuidString
        let body = try OpenAIMultipart.body(
            fileURL: fileURL, model: model, language: language, boundary: boundary
        )
        return try await OpenAIMultipart.postTranscription(
            endpoint: endpoint, apiKey: apiKey, body: body, boundary: boundary
        )
    }

    func testConnection(apiKey: String, model: String) async throws {
        guard !apiKey.isEmpty else { throw ProviderError.missingKey }
        guard let endpoint = URL(string: "\(baseURL)/audio/transcriptions") else { throw ProviderError.invalidURL }
        let boundary = UUID().uuidString
        let body = OpenAIMultipart.body(
            fileBytes: OpenAIMultipart.silentWav(),
            model: model, language: nil, boundary: boundary
        )
        _ = try await OpenAIMultipart.postTranscription(
            endpoint: endpoint, apiKey: apiKey, body: body, boundary: boundary, timeout: 30
        )
    }
}
