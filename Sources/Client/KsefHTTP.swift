import Foundation

/// Warstwa HTTP dla API KSeF. Aplikacja łączy się wyłącznie ze środowiskiem produkcyjnym.
actor KsefHTTP {
    /// Jedyny obsługiwany adres. Brak przełącznika środowisk jest celowy.
    static let productionBaseURL = URL(string: "https://api.ksef.mf.gov.pl/v2/")!

    /// Bazowy adres serwisu weryfikacji faktur (kody QR) dla środowiska produkcyjnego.
    static let productionQrBaseURL = "https://qr.ksef.mf.gov.pl"

    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = KsefHTTP.productionBaseURL, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 300
            config.httpAdditionalHeaders = ["User-Agent": AppInfo.userAgent]
            config.waitsForConnectivity = true
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Kodowanie i dekodowanie

    /// Dekoder tolerujący warianty formatu daty spotykane w API KSeF:
    /// z offsetem i bez, z ułamkiem sekundy o dowolnej długości (do 7 cyfr) i bez niego.
    /// Koder i dekoder tworzone są na żądanie: nie są typami `Sendable`, a powstają
    /// najwyżej raz na żądanie HTTP, więc ich koszt nie ma znaczenia.
    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = KsefHTTP.parseDate(raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Nierozpoznany format daty: \(raw)"
                )
            }
            return date
        }
        return d
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    /// Parsuje datę z odpowiedzi KSeF. Ułamek sekundy jest skracany do trzech cyfr,
    /// bo `ISO8601DateFormatter` nie przyjmuje siedmiu cyfr zwracanych przez API.
    static func parseDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        let normalized = normalizeFractionalSeconds(trimmed)

        let isoWithFraction = ISO8601DateFormatter()
        isoWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoWithFraction.date(from: normalized) { return d }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: normalized) { return d }

        // Warianty bez informacji o strefie — interpretowane jako czas UTC,
        // zgodnie z opisem pola `timestamp` w dokumentacji.
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 0)
            f.dateFormat = format
            if let d = f.date(from: normalized) { return d }
        }
        return nil
    }

    /// Skraca ułamek sekundy do trzech cyfr, zachowując ewentualny sufiks strefy.
    private static func normalizeFractionalSeconds(_ input: String) -> String {
        guard let dotIndex = input.firstIndex(of: ".") else { return input }
        var digitsEnd = input.index(after: dotIndex)
        while digitsEnd < input.endIndex, input[digitsEnd].isNumber {
            digitsEnd = input.index(after: digitsEnd)
        }
        let digits = input[input.index(after: dotIndex) ..< digitsEnd]
        guard digits.count > 3 else { return input }
        let truncated = digits.prefix(3)
        return String(input[input.startIndex ... dotIndex]) + truncated + String(input[digitsEnd...])
    }

    // MARK: - Wykonanie żądania

    struct Response {
        let data: Data
        let http: HTTPURLResponse
    }

    /// Wysyła żądanie i mapuje błędy HTTP na `KsefError`.
    ///
    /// `accessToken` trafia wyłącznie do nagłówka `Authorization`; nie jest logowany.
    func send(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        accessToken: String? = nil,
        acceptXML: Bool = false
    ) async throws -> Response {
        let url = try makeURL(path: path, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("problem-details", forHTTPHeaderField: "X-Error-Format")
        request.setValue(acceptXML ? "application/xml" : "application/json",
                         forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        logDebug("→ \(method) \(url.path)\(url.query.map { "?\($0)" } ?? "")")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw KsefError.cancelled
        } catch {
            throw KsefError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw KsefError.network("Odpowiedź bez nagłówka HTTP.")
        }

        logDebug("← \(http.statusCode) \(url.path) (\(data.count) B)")

        guard (200 ..< 300).contains(http.statusCode) else {
            throw Self.makeError(status: http.statusCode, headers: http, data: data)
        }
        return Response(data: data, http: http)
    }

    /// Pobiera część paczki eksportu spod adresu podpisanego przez KSeF.
    /// Taki adres nie wymaga tokenu i nie podlega limitom API.
    func downloadPackagePart(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw KsefError.network("Odpowiedź bez nagłówka HTTP.")
            }
            guard (200 ..< 300).contains(http.statusCode) else {
                throw Self.makeError(status: http.statusCode, headers: http, data: data)
            }
            return data
        } catch let error as KsefError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw KsefError.cancelled
        } catch {
            throw KsefError.network(error.localizedDescription)
        }
    }

    private func makeURL(path: String, query: [URLQueryItem]) throws -> URL {
        let cleaned = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(cleaned),
            resolvingAgainstBaseURL: false
        ) else {
            throw KsefError.network("Nieprawidłowy adres: \(path)")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw KsefError.network("Nieprawidłowy adres: \(path)")
        }
        return url
    }

    // MARK: - Mapowanie błędów

    /// Buduje `KsefError` z odpowiedzi błędnej, próbując kolejno wszystkich formatów,
    /// jakie zwraca API. Treść jest redagowana, zanim trafi do komunikatu.
    static func makeError(status: Int, headers: HTTPURLResponse, data: Data) -> KsefError {
        let raw = String(data: data, encoding: .utf8) ?? ""
        let body = Log.redact(raw)

        if status == 429 {
            let retryAfter = parseRetryAfter(headers) ?? 60
            var message = ""
            if let legacy = try? decoder.decode(TooManyRequestsResponse.self, from: data),
               let s = legacy.status {
                message = s.fullDescription
            } else if let problem = try? decoder.decode(ProblemDetails.self, from: data) {
                message = describe(problem)
            }
            return .rateLimited(retryAfter: retryAfter, message: Log.redact(message))
        }

        // Format Problem Details.
        if let problem = try? decoder.decode(ProblemDetails.self, from: data),
           problem.status != nil || problem.errors != nil || problem.title != nil {
            let codes = (problem.errors ?? []).compactMap(\.code)
            let message = describe(problem)
            return .api(httpStatus: status,
                        codes: codes,
                        message: Log.redact(message.isEmpty ? defaultMessage(status) : message),
                        traceId: problem.traceId)
        }

        // Starszy format ExceptionResponse.
        if let legacy = try? decoder.decode(ExceptionResponse.self, from: data),
           let info = legacy.exception {
            let list = info.exceptionDetailList ?? []
            let codes = list.compactMap(\.exceptionCode)
            let message = list.map { detail -> String in
                let base = detail.exceptionDescription ?? "Błąd KSeF"
                let extra = (detail.details ?? []).joined(separator: " ")
                return extra.isEmpty ? base : "\(base) \(extra)"
            }.joined(separator: " ")
            return .api(httpStatus: status,
                        codes: codes,
                        message: Log.redact(message.isEmpty ? defaultMessage(status) : message),
                        traceId: info.referenceNumber)
        }

        let snippet = body.prefix(400)
        let message = snippet.isEmpty ? defaultMessage(status) : String(snippet)
        return .api(httpStatus: status, codes: [], message: message, traceId: nil)
    }

    private static func describe(_ problem: ProblemDetails) -> String {
        var parts: [String] = []
        if let detail = problem.detail, !detail.isEmpty { parts.append(detail) }
        else if let title = problem.title, !title.isEmpty { parts.append(title) }
        for error in problem.errors ?? [] {
            var line = error.description ?? ""
            let extra = (error.details ?? []).joined(separator: " ")
            if !extra.isEmpty { line += line.isEmpty ? extra : " \(extra)" }
            if !line.isEmpty { parts.append(line) }
        }
        return parts.joined(separator: " ")
    }

    private static func defaultMessage(_ status: Int) -> String {
        switch status {
        case 401: return "Żądanie odrzucone — token dostępu jest nieważny lub wygasł."
        case 403: return "Brak uprawnień do wykonania tej operacji w podanym kontekście."
        case 404: return "Zasób nie został znaleziony w KSeF."
        case 500 ... 599: return "Błąd po stronie systemu KSeF."
        default: return "Żądanie do KSeF zakończone kodem HTTP \(status)."
        }
    }

    /// Odczytuje `Retry-After` w postaci liczby sekund lub daty HTTP.
    static func parseRetryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }

        if let seconds = TimeInterval(value) { return max(0, seconds) }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return max(0, date.timeIntervalSinceNow)
            }
        }
        return nil
    }
}

/// Metryka aplikacji używana w nagłówku User-Agent, PDF-ach i stopce e-maila.
enum AppInfo {
    static let name = "KSeF Faktury"
    static let version = "1.0.0"
    static let bundleIdentifier = "pl.ksef.faktury"
    static var userAgent: String { "KSeFFaktury/\(version) (macOS)" }
    static var displayVersion: String { "\(name) \(version)" }
}
