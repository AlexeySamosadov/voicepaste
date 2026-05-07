import Foundation

class TranscriptionService {
    private let apiKey: String
    private let baseURL: String
    private let model: String
    private let language: String?

    init(config: Config) {
        self.apiKey = config.apiKey
        self.baseURL = config.baseURL
        self.model = config.model
        self.language = config.language
    }

    func transcribe(fileURL: URL) async throws -> String {
        guard let url = URL(string: "\(baseURL)/audio/transcriptions") else {
            throw TranscriptionError.invalidURL
        }

        let boundary = UUID().uuidString

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let body = try createMultipartBody(fileURL: fileURL, boundary: boundary)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TranscriptionError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        let result = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return result.text
    }

    private func createMultipartBody(fileURL: URL, boundary: String) throws -> Data {
        var body = Data()

        // Model
        body.appendField(name: "model", value: model, boundary: boundary)

        // Language (optional)
        if let language = language {
            body.appendField(name: "language", value: language, boundary: boundary)
        }

        // Audio file
        let fileData = try Data(contentsOf: fileURL)
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\n")
        body.appendString("Content-Type: audio/wav\r\n\r\n")
        body.append(fileData)
        body.appendString("\r\n")

        // End
        body.appendString("--\(boundary)--\r\n")

        return body
    }
}

// MARK: - Helpers

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

struct TranscriptionResponse: Codable {
    let text: String
}

enum TranscriptionError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case apiError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid API URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .apiError(let code, let message):
            return "API error (\(code)): \(message)"
        }
    }
}
