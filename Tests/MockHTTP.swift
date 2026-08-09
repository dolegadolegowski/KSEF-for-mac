import Foundation

/// Protokół URL przechwytujący żądania w testach — pozwala odegrać pełny przebieg
/// komunikacji z KSeF bez łączenia się z siecią.
final class MockURLProtocol: URLProtocol {
    struct Recorded {
        let method: String
        let path: String
        let query: String?
        let headers: [String: String]
        let body: Data
    }

    nonisolated(unsafe) static var handler: ((Recorded) throws -> (Int, [String: String], Data))?
    nonisolated(unsafe) static private(set) var recorded: [Recorded] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        recorded = []
        handler = nil
        lock.unlock()
    }

    static func requests(matching path: String) -> [Recorded] {
        lock.lock()
        defer { lock.unlock() }
        return recorded.filter { $0.path.hasSuffix(path) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        // `URLSession` zamienia treść żądania na strumień, więc `httpBody` bywa puste.
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(contentsOf: buffer[0 ..< read])
            }
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let entry = Recorded(
            method: request.httpMethod ?? "GET",
            path: components?.path ?? url.path,
            query: components?.query,
            headers: request.allHTTPHeaderFields ?? [:],
            body: body
        )

        MockURLProtocol.lock.lock()
        MockURLProtocol.recorded.append(entry)
        let handler = MockURLProtocol.handler
        MockURLProtocol.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        do {
            let (status, headers, data) = try handler(entry)
            let response = HTTPURLResponse(url: url, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// Buduje `KsefHTTP` korzystający wyłącznie z tego protokołu.
    static func makeHTTP() -> KsefHTTP {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return KsefHTTP(baseURL: KsefHTTP.productionBaseURL, session: session)
    }
}

/// Serwer testowy odtwarzający zachowanie API KSeF dla przebiegu uwierzytelniania
/// i zapytań o metadane.
final class FakeKsefServer: @unchecked Sendable {
    let privateKey: SecKey
    let publicKeyDER: Data
    let ksefToken: String
    let challenge = "11111111-2222-3333-4444-555555555555"
    let challengeTimestampMs: Int64 = 1_784_000_123_456
    let referenceNumber = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    let operationToken = "OPERATION-TOKEN-0123456789"
    let accessToken = "eyJhbGciOiJIUzI1NiJ9.eyJhdXRoZW50aWNhdGlvbi1tZXRob2QiOiJUb2tlbiJ9.sig"
    let refreshToken = "eyJhbGciOiJIUzI1NiJ9.eyJ0b2tlbi10eXBlIjoiUmVmcmVzaCJ9.sig"
    let refreshedAccessToken = "eyJhbGciOiJIUzI1NiJ9.eyJyZWZyZXNoZWQiOnRydWV9.sig"

    /// Treść przekazana w polu `encryptedToken`, odszyfrowana kluczem prywatnym.
    private(set) var decryptedAuthPayload: String?

    private var statusPolls = 0
    private var redeemAttempts = 0

    /// Ile razy `redeem` ma zwrócić przejściowy błąd 21301 przed powodzeniem.
    var transientRedeemFailures = 1
    /// Ile razy zapytanie o status ma zwrócić „w toku" przed sukcesem.
    var pendingStatusPolls = 1

    /// Strony odpowiedzi dla `/invoices/query/metadata`, w kolejności odpytywania.
    var metadataPages: [(invoices: [InvoiceMetadata], hasMore: Bool)] = []
    private var metadataPageIndex = 0

    /// Liczba odpowiedzi 429, które serwer ma zwrócić przed poprawną odpowiedzią.
    var rateLimitResponses = 0

    init?(ksefToken: String = "TESTOWY-TOKEN-KSEF") {
        guard let keys = CryptoTests.makeKeyPair(),
              let pkcs1 = CryptoTests.pkcs1Representation(keys.public) else { return nil }
        privateKey = keys.private
        publicKeyDER = CryptoTests.wrapInSPKI(pkcs1: pkcs1)
        self.ksefToken = ksefToken
    }

    private func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Obsługuje pojedyncze żądanie zgodnie z kontraktem API KSeF 2.0.
    func handle(_ request: MockURLProtocol.Recorded) throws -> (Int, [String: String], Data) {
        let headers = ["Content-Type": "application/json"]

        if rateLimitResponses > 0, request.path.contains("/invoices/query/metadata") {
            rateLimitResponses -= 1
            let body = json(["status": ["code": 429, "description": "Too Many Requests",
                                        "details": ["Przekroczono limit żądań."]]])
            return (429, headers.merging(["Retry-After": "1"]) { _, new in new }, body)
        }

        switch (request.method, request.path) {
        case let (method, path) where method == "GET" && path.hasSuffix("/security/public-key-certificates"):
            return (200, headers, json([[
                "certificate": publicKeyDER.base64EncodedString(),
                "certificateId": "certyfikat-testowy",
                "publicKeyId": "klucz-testowy",
                "validFrom": iso(Date().addingTimeInterval(-86400)),
                "validTo": iso(Date().addingTimeInterval(86400 * 365)),
                "usage": ["KsefTokenEncryption", "SymmetricKeyEncryption"],
            ]]))

        case let (method, path) where method == "POST" && path.hasSuffix("/auth/challenge"):
            return (200, headers, json([
                "challenge": challenge,
                "timestamp": iso(Date(timeIntervalSince1970: TimeInterval(challengeTimestampMs) / 1000)),
                "timestampMs": challengeTimestampMs,
                "clientIp": "203.0.113.7",
            ]))

        case let (method, path) where method == "POST" && path.hasSuffix("/auth/ksef-token"):
            let payload = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] ?? [:]
            if let encoded = payload["encryptedToken"] as? String,
               let cipher = Data(base64Encoded: encoded) {
                var error: Unmanaged<CFError>?
                if let plain = SecKeyCreateDecryptedData(privateKey, .rsaEncryptionOAEPSHA256,
                                                         cipher as CFData, &error) as Data? {
                    decryptedAuthPayload = String(data: plain, encoding: .utf8)
                } else {
                    error?.release()
                }
            }
            return (202, headers, json([
                "referenceNumber": referenceNumber,
                "authenticationToken": [
                    "token": operationToken,
                    "validUntil": iso(Date().addingTimeInterval(600)),
                ],
            ]))

        case let (method, path) where method == "GET" && path.contains("/auth/\(referenceNumber)"):
            statusPolls += 1
            let inProgress = statusPolls <= pendingStatusPolls
            return (200, headers, json([
                "startDate": iso(Date()),
                "authenticationMethod": "Token",
                "authenticationMethodInfo": ["category": "Token", "code": "Token", "displayName": "Token KSeF"],
                "status": [
                    "code": inProgress ? 100 : 200,
                    "description": inProgress ? "Uwierzytelnianie w toku" : "Uwierzytelnianie zakończone sukcesem",
                ],
            ]))

        case let (method, path) where method == "POST" && path.hasSuffix("/auth/token/redeem"):
            redeemAttempts += 1
            if redeemAttempts <= transientRedeemFailures {
                // Znany przypadek: operacja zakończona sukcesem, ale tokeny jeszcze niegotowe.
                return (400, headers, json([
                    "title": "Bad Request",
                    "status": 400,
                    "detail": "Żądanie jest nieprawidłowe.",
                    "errors": [["code": 21301, "description": "Brak autoryzacji.",
                                "details": ["Status uwierzytelniania nie pozwala na pobranie tokenów."]]],
                    "traceId": "trace-21301",
                ]))
            }
            return (200, headers, json([
                "accessToken": ["token": accessToken, "validUntil": iso(Date().addingTimeInterval(900))],
                "refreshToken": ["token": refreshToken, "validUntil": iso(Date().addingTimeInterval(86400))],
            ]))

        case let (method, path) where method == "POST" && path.hasSuffix("/auth/token/refresh"):
            return (200, headers, json([
                "accessToken": ["token": refreshedAccessToken,
                                "validUntil": iso(Date().addingTimeInterval(900))],
            ]))

        case let (method, path) where method == "POST" && path.hasSuffix("/invoices/query/metadata"):
            let page = metadataPageIndex < metadataPages.count
                ? metadataPages[metadataPageIndex]
                : (invoices: [InvoiceMetadata](), hasMore: false)
            metadataPageIndex += 1

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let invoicesData = try encoder.encode(page.invoices)
            let invoicesArray = try JSONSerialization.jsonObject(with: invoicesData)
            return (200, headers, json([
                "hasMore": page.hasMore,
                "isTruncated": false,
                "invoices": invoicesArray,
            ]))

        case let (method, path) where method == "GET" && path.contains("/invoices/ksef/"):
            let xml = Fixtures.fa3Standard
            return (200, ["Content-Type": "application/xml"], Data(xml.utf8))

        default:
            return (404, headers, json([
                "title": "Not Found", "status": 404,
                "detail": "Nieznany zasób: \(request.path)",
                "errors": [], "traceId": "trace-404",
            ]))
        }
    }

    func install() {
        MockURLProtocol.handler = { [weak self] request in
            guard let self else { throw URLError(.cancelled) }
            return try self.handle(request)
        }
    }
}
