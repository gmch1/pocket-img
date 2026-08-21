import Foundation
import XCTest
@testable import PocketIMGShot

final class PocketIMGClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testChecksServerAvailabilityBeforeEveryUpload() async throws {
        let requests = LockedRecorder<(path: String, timeout: TimeInterval)>()
        MockURLProtocol.handler = { request in
            requests.append((request.url?.path ?? "", request.timeoutInterval))

            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/healthz"):
                return (200, Data(#"{"status":"ok"}"#.utf8))
            case ("POST", "/api/auth/session"):
                return (204, Data())
            case ("POST", "/api/images"):
                return (201, Data(#"{"image":{"url":"/i/test.webp"}}"#.utf8))
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                return (500, Data())
            }
        }

        let client = PocketIMGClient(
            configuration: ServiceConfiguration(
                baseURL: try XCTUnwrap(URL(string: "https://unit.test")),
                token: "test-token"
            ),
            protocolClasses: [MockURLProtocol.self]
        )
        let payload = UploadPayload(
            data: Data("image".utf8),
            fileName: "test.webp",
            contentType: "image/webp",
            displaySize: CGSize(width: 1, height: 1)
        )

        _ = try await client.upload(payload)
        _ = try await client.upload(payload)

        let capturedRequests = requests.values
        XCTAssertEqual(
            capturedRequests.map(\.path),
            ["/healthz", "/api/auth/session", "/api/images", "/healthz", "/api/images"]
        )
        XCTAssertEqual(capturedRequests[0].timeout, PocketIMGClient.availabilityTimeout)
        XCTAssertEqual(capturedRequests[3].timeout, PocketIMGClient.availabilityTimeout)
        for index in [1, 2, 4] {
            XCTAssertEqual(
                capturedRequests[index].timeout,
                PocketIMGClient.requestInactivityTimeout
            )
        }
    }

    func testUnavailableServerStopsBeforeAuthenticationAndUpload() async throws {
        let paths = LockedRecorder<String>()
        MockURLProtocol.handler = { request in
            paths.append(request.url?.path ?? "")
            return (503, Data(#"{"error":"offline"}"#.utf8))
        }

        let client = PocketIMGClient(
            configuration: ServiceConfiguration(
                baseURL: try XCTUnwrap(URL(string: "https://unit.test")),
                token: "test-token"
            ),
            protocolClasses: [MockURLProtocol.self]
        )
        let payload = UploadPayload(
            data: Data("image".utf8),
            fileName: "test.webp",
            contentType: "image/webp",
            displaySize: CGSize(width: 1, height: 1)
        )

        do {
            _ = try await client.upload(payload)
            XCTFail("Expected the health check to fail")
        } catch let error as PocketIMGClientError {
            guard case .requestFailed(let status, _) = error else {
                return XCTFail("Unexpected client error: \(error)")
            }
            XCTAssertEqual(status, 503)
        }

        XCTAssertEqual(paths.values, ["/healthz"])
    }
}

private final class LockedRecorder<Value> {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (status: Int, data: Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler,
              let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let result = handler(request)
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: result.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !result.data.isEmpty {
            client?.urlProtocol(self, didLoad: result.data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
