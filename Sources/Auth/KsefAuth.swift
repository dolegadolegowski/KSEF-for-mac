import Foundation

/// Wynik przycisku „Sprawdź połączenie".
struct ConnectionCheckResult {
    let contextNip: String
    let authenticationMethod: String
    let accessTokenValidUntil: Date
    let hasInvoiceRead: Bool
    let note: String?
}

/// Pełny przebieg uwierzytelniania tokenem KSeF w kontekście NIP.
///
/// challenge → RSA-OAEP SHA-256 → żądanie auth → odpytywanie statusu → wykup tokenów →
/// odświeżanie access tokena refresh tokenem.
actor KsefAuth {
    private let http: KsefHTTP

    private var accessToken: TokenInfo?
    private var refreshToken: TokenInfo?
    private var contextNip: String?
    private var ksefToken: String?

    /// Odświeżamy access token z zapasem, zanim faktycznie wygaśnie.
    private let refreshMargin: TimeInterval = 120

    /// Aby uniknąć równoległych, zbędnych uwierzytelnień przy wielu żądaniach naraz.
    private var inFlight: Task<String, Error>?

    init(http: KsefHTTP) {
        self.http = http
    }

    // MARK: - Stan

    /// Czyści stan sesji. Wywoływane przy zmianie NIP-u i przy wylogowaniu.
    func reset() {
        accessToken = nil
        refreshToken = nil
        contextNip = nil
        ksefToken = nil
        inFlight?.cancel()
        inFlight = nil
    }

    /// Podaje dane logowania bez natychmiastowego uwierzytelniania.
    func configure(nip: String, token: String) {
        let normalized = Nip.normalize(nip)
        if contextNip != normalized || ksefToken != token {
            accessToken = nil
            refreshToken = nil
        }
        contextNip = normalized
        ksefToken = token
        Log.shared.registerSecret(token)
    }

    var isAuthenticated: Bool {
        guard let accessToken else { return false }
        return accessToken.validUntil.timeIntervalSinceNow > refreshMargin
    }

    /// Unieważnia lokalnie przechowywany token dostępu, wymuszając jego odświeżenie
    /// przy następnym żądaniu. Używane po odpowiedzi 401 z API, gdy token przestał
    /// być akceptowany wcześniej, niż wynikałoby to z daty ważności.
    func invalidateAccessToken() {
        accessToken = nil
    }

    // MARK: - Token dostępu

    /// Zwraca ważny access token, w razie potrzeby odświeżając go lub przechodząc
    /// pełne uwierzytelnienie od nowa.
    func validAccessToken() async throws -> String {
        if let accessToken, accessToken.validUntil.timeIntervalSinceNow > refreshMargin {
            return accessToken.token
        }

        if let inFlight {
            return try await inFlight.value
        }

        let task = Task<String, Error> { [self] in
            // Najpierw tania ścieżka: odświeżenie istniejącym refresh tokenem.
            if let refresh = refreshToken, refresh.validUntil.timeIntervalSinceNow > 5 {
                do {
                    let info = try await refreshAccessToken(using: refresh.token)
                    return info.token
                } catch let error as KsefError {
                    logWarn("Odświeżenie tokena nie powiodło się, pełne uwierzytelnienie: "
                        + (error.errorDescription ?? "brak opisu"))
                }
            }
            let tokens = try await performFullAuthentication()
            return tokens.accessToken.token
        }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    // MARK: - Pełne uwierzytelnienie

    @discardableResult
    func performFullAuthentication() async throws -> AuthenticationTokensResponse {
        guard let nip = contextNip, let token = ksefToken, !token.isEmpty else {
            throw KsefError.notAuthenticated
        }
        guard Nip.isValid(nip) else {
            throw KsefError.notAuthenticated
        }

        logInfo("Rozpoczęcie uwierzytelniania w kontekście NIP \(Nip.formatted(nip)).")

        // 1. Klucz publiczny KSeF przeznaczony do szyfrowania tokenów.
        let certificate = try await fetchTokenEncryptionCertificate()
        guard let der = certificate.derData else {
            throw CryptoError.invalidCertificate
        }
        let publicKey = try Crypto.publicKey(fromDER: der)

        // 2. Challenge.
        let challenge = try await fetchChallenge()

        // 3-4. Szyfrowanie ciągu "{token}|{timestampMs}".
        let encryptedToken = try Crypto.encryptKsefToken(
            token,
            challengeTimestampMs: challenge.timestampMs,
            publicKey: publicKey
        )

        // 5. Żądanie uwierzytelnienia.
        let request = InitTokenAuthenticationRequest(
            challenge: challenge.challenge,
            contextIdentifier: .nip(nip),
            encryptedToken: encryptedToken,
            publicKeyId: certificate.publicKeyId
        )
        let body = try KsefHTTP.encoder.encode(request)
        let initResponse: AuthenticationInitResponse = try decode(
            await http.send(method: "POST", path: "auth/ksef-token", body: body)
        )
        Log.shared.registerSecret(initResponse.authenticationToken.token)

        // 6. Odpytywanie o status operacji.
        try await waitForAuthentication(
            referenceNumber: initResponse.referenceNumber,
            operationToken: initResponse.authenticationToken.token
        )

        // 7. Wykup pary tokenów.
        let tokens = try await redeemTokens(operationToken: initResponse.authenticationToken.token)
        Log.shared.registerSecret(tokens.accessToken.token)
        Log.shared.registerSecret(tokens.refreshToken.token)
        accessToken = tokens.accessToken
        refreshToken = tokens.refreshToken

        logInfo("Uwierzytelnienie zakończone powodzeniem, token ważny do \(Fmt.dateTime(tokens.accessToken.validUntil)).")
        return tokens
    }

    private func fetchTokenEncryptionCertificate() async throws -> PublicKeyCertificate {
        let response = try await http.send(method: "GET", path: "security/public-key-certificates")
        let certificates: [PublicKeyCertificate] = try decode(response)

        let now = Date()
        let candidates = certificates
            .filter { $0.usage.contains(PublicKeyCertificate.usageTokenEncryption) }
            .filter { $0.isValid(at: now) }

        // Przy rotacji klucza wybieramy ten o najpóźniejszej dacie ważności.
        guard let chosen = candidates.max(by: { $0.validTo < $1.validTo }) else {
            throw KsefError.api(
                httpStatus: 200,
                codes: [],
                message: "KSeF nie udostępnił ważnego klucza publicznego do szyfrowania tokenów.",
                traceId: nil
            )
        }
        logDebug("Wybrano klucz publiczny KSeF publicKeyId=\(chosen.publicKeyId) ważny do \(Fmt.dateTime(chosen.validTo)).")
        return chosen
    }

    private func fetchChallenge() async throws -> AuthChallengeResponse {
        // Endpoint nie przyjmuje treści żądania — kontekst przekazywany jest dopiero
        // w żądaniu uwierzytelnienia tokenem.
        let response = try await http.send(method: "POST", path: "auth/challenge")
        return try decode(response)
    }

    /// Odpytuje `GET /auth/{referenceNumber}` aż do statusu końcowego.
    private func waitForAuthentication(referenceNumber: String, operationToken: String) async throws {
        let deadline = Date().addingTimeInterval(120)
        var delay: TimeInterval = 0.8

        while Date() < deadline {
            let response = try await http.send(
                method: "GET",
                path: "auth/\(referenceNumber)",
                accessToken: operationToken
            )
            let status: AuthenticationStatusResponse = try decode(response)

            if status.status.isSuccess { return }
            if status.status.isTerminal {
                throw KsefError.authenticationFailed(
                    code: status.status.code,
                    message: status.status.fullDescription
                )
            }

            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                throw KsefError.cancelled
            }
            delay = min(delay * 1.4, 4)
        }
        throw KsefError.authenticationFailed(
            code: 100,
            message: "Przekroczono czas oczekiwania na zakończenie uwierzytelniania."
        )
    }

    /// Wykupuje parę tokenów. Zgodnie z dokumentacją tokeny można pobrać tylko raz,
    /// a bezpośrednio po sukcesie operacji API bywa jeszcze niegotowe i zwraca 21301 —
    /// stąd krótkie ponowienia z narastającym opóźnieniem.
    private func redeemTokens(operationToken: String) async throws -> AuthenticationTokensResponse {
        var delay: TimeInterval = 0.6
        var lastError: Error?

        for attempt in 1 ... 6 {
            do {
                let response = try await http.send(
                    method: "POST",
                    path: "auth/token/redeem",
                    accessToken: operationToken
                )
                return try decode(response)
            } catch let error as KsefError where error.isTransientRedeem {
                lastError = error
                logWarn("Wykup tokenów — próba \(attempt) zwróciła przejściowy błąd 21301, ponawiam za \(String(format: "%.1f", delay)) s.")
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    throw KsefError.cancelled
                }
                delay = min(delay * 1.8, 6)
            } catch let error as KsefError where error.isRetryable {
                lastError = error
                if case let .rateLimited(retryAfter, _) = error {
                    try await Task.sleep(nanoseconds: UInt64(max(1, retryAfter) * 1_000_000_000))
                } else {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    delay = min(delay * 1.8, 6)
                }
            }
        }
        throw lastError ?? KsefError.authenticationFailed(
            code: 21301,
            message: "Nie udało się pobrać tokenów dostępowych."
        )
    }

    private func refreshAccessToken(using refresh: String) async throws -> TokenInfo {
        struct RefreshResponse: Decodable { let accessToken: TokenInfo }
        let response = try await http.send(
            method: "POST",
            path: "auth/token/refresh",
            accessToken: refresh
        )
        let decoded: RefreshResponse = try decode(response)
        Log.shared.registerSecret(decoded.accessToken.token)
        accessToken = decoded.accessToken
        logDebug("Access token odświeżony, ważny do \(Fmt.dateTime(decoded.accessToken.validUntil)).")
        return decoded.accessToken
    }

    // MARK: - Sprawdzenie połączenia

    /// Uwierzytelnia się naprawdę i potwierdza uprawnienie `InvoiceRead`,
    /// wykonując zapytanie o metadane na wąskim zakresie dat.
    func checkConnection(nip: String, token: String) async throws -> ConnectionCheckResult {
        // Sprawdzenie połączenia zawsze przechodzi pełne uwierzytelnienie od zera,
        // żeby nie potwierdzić działania na podstawie wcześniej wydanego tokena.
        reset()
        configure(nip: nip, token: token)

        let tokens = try await performFullAuthentication()
        let claims = Jwt.claims(from: tokens.accessToken.token)

        let method = claims["authentication-method"] as? String ?? "Token KSeF"
        var note: String?
        var hasInvoiceRead = true

        // Realna weryfikacja uprawnienia: zapytanie o metadane wymaga `InvoiceRead`.
        let probe = InvoiceQueryFilters(
            subjectType: InvoiceSubjectType.subject1.rawValue,
            dateRange: InvoiceQueryDateRange(
                dateType: InvoiceDateType.issue.rawValue,
                from: MonthPeriod.previousMonth().isoFrom,
                to: MonthPeriod.previousMonth().isoTo
            )
        )
        do {
            let body = try KsefHTTP.encoder.encode(probe)
            _ = try await http.send(
                method: "POST",
                path: "invoices/query/metadata",
                query: [
                    URLQueryItem(name: "pageOffset", value: "0"),
                    URLQueryItem(name: "pageSize", value: "10"),
                ],
                body: body,
                accessToken: tokens.accessToken.token
            )
        } catch let error as KsefError {
            if case let .api(httpStatus, _, message, _) = error, httpStatus == 403 {
                hasInvoiceRead = false
                note = message
            } else if case .rateLimited = error {
                note = "Uwierzytelnienie działa, ale weryfikacja uprawnienia została "
                    + "wstrzymana przez limit żądań. Spróbuj ponownie za chwilę."
            } else {
                throw error
            }
        }

        return ConnectionCheckResult(
            contextNip: Nip.formatted(contextNip ?? nip),
            authenticationMethod: method,
            accessTokenValidUntil: tokens.accessToken.validUntil,
            hasInvoiceRead: hasInvoiceRead,
            note: note
        )
    }

    // MARK: - Pomocnicze

    private func decode<T: Decodable>(_ response: KsefHTTP.Response) throws -> T {
        do {
            return try KsefHTTP.decoder.decode(T.self, from: response.data)
        } catch {
            throw KsefError.decoding(Log.redact(String(describing: error)))
        }
    }
}

/// Odczyt jawnych pól JWT. Podpis nie jest weryfikowany — token pochodzi z zaufanego
/// połączenia TLS z KSeF, a odczytujemy jedynie dane informacyjne pokazywane użytkownikowi.
enum Jwt {
    static func claims(from token: String) -> [String: Any] {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return [:] }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    static func expiry(from token: String) -> Date? {
        guard let exp = claims(from: token)["exp"] as? TimeInterval else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}
