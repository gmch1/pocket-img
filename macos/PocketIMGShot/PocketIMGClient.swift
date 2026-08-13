import Foundation

actor PocketIMGClient {
    private struct UploadResponse: Decodable {
        struct Image: Decodable {
            let url: String
        }

        let image: Image
    }

    private struct ErrorResponse: Decodable {
        let error: String
    }

    private let configuration: ServiceConfiguration
    private let session: URLSession
    private var authenticated = false

    init(configuration: ServiceConfiguration) {
        self.configuration = configuration
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.httpCookieAcceptPolicy = .always
        sessionConfiguration.httpShouldSetCookies = true
        sessionConfiguration.timeoutIntervalForRequest = 180
        sessionConfiguration.timeoutIntervalForResource = 300
        session = URLSession(configuration: sessionConfiguration)
    }

    func upload(_ payload: UploadPayload) async throws -> URL {
        if !authenticated {
            try await authenticate()
        }
        var response = try await performUpload(payload)
        if response.statusCode == 401 {
            authenticated = false
            try await authenticate()
            response = try await performUpload(payload)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw apiError(status: response.statusCode, data: response.data)
        }
        let decoded = try JSONDecoder().decode(UploadResponse.self, from: response.data)
        guard let result = URL(string: decoded.image.url, relativeTo: configuration.baseURL)?.absoluteURL else {
            throw PocketIMGClientError.invalidResponse
        }
        return result
    }

    private func authenticate() async throws {
        var request = URLRequest(url: try endpoint("/api/auth/session"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        let (data, rawResponse) = try await session.data(for: request)
        guard let response = rawResponse as? HTTPURLResponse else {
            throw PocketIMGClientError.invalidResponse
        }
        guard response.statusCode == 204 else {
            throw apiError(status: response.statusCode, data: data)
        }
        authenticated = true
    }

    private func performUpload(_ payload: UploadPayload) async throws -> HTTPResult {
        let boundary = "PocketIMGShot-\(UUID().uuidString)"
        var request = URLRequest(url: try endpoint("/api/images"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var body = Data()
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"file\"; filename=\"\(payload.fileName)\"\r\n")
        body.appendUTF8("Content-Type: \(payload.contentType)\r\n\r\n")
        body.append(payload.data)
        body.appendUTF8("\r\n--\(boundary)--\r\n")

        let (data, rawResponse) = try await session.upload(for: request, from: body)
        guard let response = rawResponse as? HTTPURLResponse else {
            throw PocketIMGClientError.invalidResponse
        }
        return HTTPResult(statusCode: response.statusCode, data: data)
    }

    private func endpoint(_ path: String) throws -> URL {
        guard let url = URL(string: path, relativeTo: configuration.baseURL)?.absoluteURL else {
            throw PocketIMGClientError.invalidResponse
        }
        return url
    }

    private func apiError(status: Int, data: Data) -> PocketIMGClientError {
        let serverMessage = try? JSONDecoder().decode(ErrorResponse.self, from: data).error
        return PocketIMGClientError.requestFailed(status: status, message: serverMessage)
    }
}

private struct HTTPResult {
    let statusCode: Int
    let data: Data
}

enum PocketIMGClientError: LocalizedError {
    case invalidResponse
    case requestFailed(status: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "PocketIMG 返回了无法识别的响应。"
        case .requestFailed(let status, let message):
            return message ?? "PocketIMG 请求失败（HTTP \(status)）。"
        }
    }
}

private extension Data {
    mutating func appendUTF8(_ value: String) {
        append(contentsOf: value.utf8)
    }
}
