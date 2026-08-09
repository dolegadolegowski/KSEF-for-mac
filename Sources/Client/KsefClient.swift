import Foundation

/// Sposób, w jaki pobrano treści faktur — pokazywany w UI, żeby użytkownik wiedział,
/// którą ścieżką poszła aplikacja.
enum DownloadStrategy: String {
    case single
    case export

    var displayName: String {
        switch self {
        case .single: return "pojedyncze pobieranie faktur"
        case .export: return "eksport paczki faktur"
        }
    }
}

/// Postęp długotrwałej operacji, raportowany do UI.
struct FetchProgress: Sendable {
    var stage: String
    var current: Int
    var total: Int
    var detail: String?

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(current) / Double(total))
    }
}

/// Klient wysokopoziomowy: zapytania o metadane, pobieranie treści faktur i eksport wsadowy.
actor KsefClient {
    private let http: KsefHTTP
    private let auth: KsefAuth
    private let downloadLimiter: RateLimiter
    private let queryLimiter: RateLimiter

    /// Maksymalna strona wyników dopuszczana przez API.
    private static let pageSize = 250

    /// Limit godzinowy pobierania pojedynczych faktur; powyżej opłaca się eksport paczki.
    private static let hourlyDownloadLimit = 64

    init(http: KsefHTTP, auth: KsefAuth, stateDirectory: URL?) {
        self.http = http
        self.auth = auth
        downloadLimiter = RateLimiter(
            limits: .invoiceDownload,
            storageURL: stateDirectory?.appendingPathComponent("rate-invoice-download.json")
        )
        queryLimiter = RateLimiter(
            limits: .invoiceQuery,
            storageURL: stateDirectory?.appendingPathComponent("rate-invoice-query.json")
        )
    }

    // MARK: - Metadane

    /// Pobiera wszystkie strony metadanych dla danego typu podmiotu i deduplikuje po numerze KSeF.
    func fetchAllMetadata(
        period: MonthPeriod,
        subjectType: InvoiceSubjectType,
        dateType: InvoiceDateType,
        onProgress: @Sendable (FetchProgress) -> Void = { _ in }
    ) async throws -> [InvoiceMetadata] {
        let filters = InvoiceQueryFilters(
            subjectType: subjectType.rawValue,
            dateRange: InvoiceQueryDateRange(
                dateType: dateType.rawValue,
                from: period.isoFrom,
                to: period.isoTo
            )
        )
        let body = try KsefHTTP.encoder.encode(filters)

        var collected: [InvoiceMetadata] = []
        var seen = Set<String>()
        var offset = 0
        var truncated = false

        let stage = subjectType == .subject1
            ? "Metadane faktur wystawionych"
            : "Metadane faktur otrzymanych"

        while true {
            try Task.checkCancellation()
            onProgress(FetchProgress(stage: stage, current: collected.count, total: collected.count + 1,
                                     detail: "strona \(offset + 1)"))

            let page: QueryInvoicesMetadataResponse = try await withRateLimit(queryLimiter) {
                let token = try await self.auth.validAccessToken()
                let response = try await self.http.send(
                    method: "POST",
                    path: "invoices/query/metadata",
                    query: [
                        URLQueryItem(name: "sortOrder", value: "Asc"),
                        URLQueryItem(name: "pageOffset", value: String(offset)),
                        URLQueryItem(name: "pageSize", value: String(Self.pageSize)),
                    ],
                    body: body,
                    accessToken: token
                )
                return try Self.decode(response)
            }

            // Deduplikacja po numerze KSeF — ten sam dokument nie może trafić do wyniku dwukrotnie.
            for invoice in page.invoices where seen.insert(invoice.ksefNumber).inserted {
                collected.append(invoice)
            }

            if page.isTruncated { truncated = true }
            guard page.hasMore, !page.invoices.isEmpty else { break }
            offset += 1
        }

        if truncated {
            logWarn("Zapytanie o metadane (\(subjectType.rawValue)) osiągnęło limit 10 000 wyników — "
                + "część faktur może nie zostać wykazana.")
        }
        logInfo("Pobrano \(collected.count) pozycji metadanych dla \(subjectType.rawValue) za \(period.tag).")
        return collected
    }

    // MARK: - Wybór ścieżki pobierania

    /// Decyduje, czy pobrać faktury pojedynczo, czy eksportem paczki.
    /// Eksport wybieramy, gdy pojedyncze pobieranie nie zmieściłoby się w limicie godzinnym.
    func chooseStrategy(invoiceCount: Int) async -> DownloadStrategy {
        guard invoiceCount > 0 else { return .single }
        let remaining = await downloadLimiter.remainingInHour
        if invoiceCount > min(Self.hourlyDownloadLimit, remaining) {
            return .export
        }
        return .single
    }

    /// Szacowany czas pobierania pojedynczego — do komunikatu w UI.
    func estimatedSingleDownloadDuration(invoiceCount: Int) async -> TimeInterval {
        await downloadLimiter.estimatedDuration(for: invoiceCount)
    }

    func remainingHourlyDownloads() async -> Int {
        await downloadLimiter.remainingInHour
    }

    // MARK: - Pobieranie pojedynczych faktur

    /// Pobiera oryginalny XML faktury. Zwracane bajty to dokument źródłowy — zapisujemy je bez zmian.
    func downloadInvoiceXML(ksefNumber: String) async throws -> Data {
        try await withRateLimit(downloadLimiter) {
            let token = try await self.auth.validAccessToken()
            let response = try await self.http.send(
                method: "GET",
                path: "invoices/ksef/\(ksefNumber)",
                accessToken: token,
                acceptXML: true
            )
            return response.data
        }
    }

    // MARK: - Eksport paczki faktur

    /// Uruchamia eksport, czeka na gotowość paczki, pobiera części, odszyfrowuje i rozpakowuje.
    /// Zwraca mapę: numer KSeF → oryginalny XML.
    func exportInvoices(
        period: MonthPeriod,
        subjectType: InvoiceSubjectType,
        dateType: InvoiceDateType,
        onProgress: @Sendable (FetchProgress) -> Void = { _ in }
    ) async throws -> [String: Data] {
        // Klucz AES-256 i IV generowane lokalnie; klucz przekazujemy opakowany kluczem publicznym KSeF.
        let symmetricKey = Crypto.randomBytes(32)
        let iv = Crypto.randomBytes(16)

        let certificate = try await fetchSymmetricEncryptionCertificate()
        guard let der = certificate.derData else { throw CryptoError.invalidCertificate }
        let publicKey = try Crypto.publicKey(fromDER: der)
        let wrappedKey = try Crypto.rsaOaepSha256Encrypt(symmetricKey, publicKey: publicKey)

        let request = InvoiceExportRequest(
            encryption: EncryptionInfo(
                encryptedSymmetricKey: wrappedKey.base64EncodedString(),
                initializationVector: iv.base64EncodedString(),
                publicKeyId: certificate.publicKeyId
            ),
            filters: InvoiceQueryFilters(
                subjectType: subjectType.rawValue,
                dateRange: InvoiceQueryDateRange(
                    dateType: dateType.rawValue,
                    from: period.isoFrom,
                    to: period.isoTo
                )
            ),
            onlyMetadata: false
        )

        onProgress(FetchProgress(stage: "Eksport paczki faktur", current: 0, total: 1,
                                 detail: "zlecanie eksportu"))

        let body = try KsefHTTP.encoder.encode(request)
        let initiated: InvoiceExportResponse = try await withRateLimit(queryLimiter) {
            let token = try await self.auth.validAccessToken()
            let response = try await self.http.send(
                method: "POST",
                path: "invoices/exports",
                body: body,
                accessToken: token
            )
            return try Self.decode(response)
        }

        let package = try await waitForExport(
            referenceNumber: initiated.referenceNumber,
            onProgress: onProgress
        )

        // Pobranie i odszyfrowanie części paczki.
        var archive = Data()
        for (index, part) in package.parts.sorted(by: { $0.ordinalNumber < $1.ordinalNumber }).enumerated() {
            try Task.checkCancellation()
            onProgress(FetchProgress(stage: "Eksport paczki faktur",
                                     current: index,
                                     total: package.parts.count,
                                     detail: "pobieranie części \(index + 1) z \(package.parts.count)"))

            guard let url = URL(string: part.url) else {
                throw KsefError.network("Nieprawidłowy adres części paczki: \(part.partName)")
            }
            // Adresy części są podpisane, nie wymagają tokenu i nie podlegają limitom API.
            let encrypted = try await http.downloadPackagePart(url: url)

            let actualHash = Crypto.sha256Base64(encrypted)
            if actualHash != part.encryptedPartHash {
                logWarn("Skrót zaszyfrowanej części \(part.partName) różni się od zadeklarowanego.")
            }

            let decrypted = try Crypto.aes256CBCDecrypt(encrypted, key: symmetricKey, iv: iv)
            archive.append(decrypted)
        }

        onProgress(FetchProgress(stage: "Eksport paczki faktur",
                                 current: package.parts.count,
                                 total: package.parts.count,
                                 detail: "rozpakowywanie"))

        let entries = try ZipArchive.entries(in: archive)
        var result: [String: Data] = [:]
        for entry in entries {
            let name = (entry.name as NSString).lastPathComponent
            guard name.lowercased().hasSuffix(".xml") else { continue }
            let ksefNumber = String(name.dropLast(4))
            result[ksefNumber] = entry.data
        }

        if package.isTruncated {
            logWarn("Paczka eksportu została ucięta (limit 10 000 faktur lub 1 GB).")
        }
        logInfo("Eksport zwrócił \(result.count) plików XML.")
        return result
    }

    /// Odczytuje `_metadata.json` z paczki eksportu — używane jako źródło metadanych,
    /// gdy eksport zastępuje zapytanie stronicowane.
    static func metadataFromExport(archive: Data) throws -> [InvoiceMetadata] {
        let entries = try ZipArchive.entries(in: archive)
        guard let file = entries.first(where: { ($0.name as NSString).lastPathComponent == "_metadata.json" }) else {
            return []
        }
        let decoded = try KsefHTTP.decoder.decode(ExportMetadataFile.self, from: file.data)
        return decoded.invoices
    }

    private func waitForExport(
        referenceNumber: String,
        onProgress: @Sendable (FetchProgress) -> Void
    ) async throws -> InvoicePackage {
        let deadline = Date().addingTimeInterval(1800)
        var delay: TimeInterval = 2

        while Date() < deadline {
            try Task.checkCancellation()

            let status: InvoiceExportStatusResponse = try await withRateLimit(queryLimiter) {
                let token = try await self.auth.validAccessToken()
                let response = try await self.http.send(
                    method: "GET",
                    path: "invoices/exports/\(referenceNumber)",
                    accessToken: token
                )
                return try Self.decode(response)
            }

            if status.status.isSuccess, let package = status.package {
                return package
            }
            if status.status.code >= 400 {
                throw KsefError.exportFailed(code: status.status.code,
                                             message: status.status.fullDescription)
            }

            onProgress(FetchProgress(stage: "Eksport paczki faktur", current: 0, total: 1,
                                     detail: "KSeF przygotowuje paczkę…"))
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                throw KsefError.cancelled
            }
            delay = min(delay * 1.3, 15)
        }
        throw KsefError.exportFailed(code: 100, message: "Przekroczono czas oczekiwania na paczkę faktur.")
    }

    private func fetchSymmetricEncryptionCertificate() async throws -> PublicKeyCertificate {
        let response = try await http.send(method: "GET", path: "security/public-key-certificates")
        let certificates: [PublicKeyCertificate] = try Self.decode(response)
        let now = Date()
        let candidates = certificates
            .filter { $0.usage.contains(PublicKeyCertificate.usageSymmetricKeyEncryption) }
            .filter { $0.isValid(at: now) }
        guard let chosen = candidates.max(by: { $0.validTo < $1.validTo }) else {
            throw KsefError.api(
                httpStatus: 200,
                codes: [],
                message: "KSeF nie udostępnił klucza publicznego do szyfrowania klucza symetrycznego.",
                traceId: nil
            )
        }
        return chosen
    }

    // MARK: - Pomocnicze

    /// Wykonuje operację z poszanowaniem limitera i automatycznie wznawia po 429,
    /// czekając tyle, ile wskazał nagłówek `Retry-After`.
    private func withRateLimit<T>(_ limiter: RateLimiter, _ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            try await limiter.acquire()
            do {
                return try await operation()
            } catch let error as KsefError {
                guard case let .rateLimited(retryAfter, _) = error, attempt < 5 else { throw error }
                attempt += 1
                try await limiter.penalize(retryAfter: retryAfter)
            }
        }
    }

    private static func decode<T: Decodable>(_ response: KsefHTTP.Response) throws -> T {
        do {
            return try KsefHTTP.decoder.decode(T.self, from: response.data)
        } catch {
            throw KsefError.decoding(Log.redact(String(describing: error)))
        }
    }
}
