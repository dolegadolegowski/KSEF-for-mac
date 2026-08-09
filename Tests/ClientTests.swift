import Foundation

enum ClientTests {
    /// Buduje metadane faktury na potrzeby testów paginacji.
    private static func metadata(_ index: Int) -> InvoiceMetadata {
        InvoiceMetadata(
            ksefNumber: String(format: "5260250274-20260715-%08X-01", index),
            invoiceNumber: "FV/\(index)/2026",
            issueDate: "2026-07-15",
            invoicingDate: nil, acquisitionDate: nil, permanentStorageDate: nil,
            seller: InvoiceMetadataSeller(nip: "5260250274", name: "Sprzedawca"),
            buyer: InvoiceMetadataBuyer(
                identifier: InvoiceMetadataBuyerIdentifier(type: "Nip", value: "7010001453"),
                name: "Nabywca"
            ),
            netAmount: 100, grossAmount: 123, vatAmount: 23, currency: "PLN",
            invoicingMode: "Online", invoiceType: "Vat",
            formCode: FormCode(systemCode: "FA (3)", schemaVersion: "1-0E", value: "FA"),
            isSelfInvoicing: false, hasAttachment: false,
            invoiceHash: nil, hashOfCorrectedInvoice: nil
        )
    }

    static func run() {
        T.suite("Warstwa HTTP") {
            T.test("parsuje warianty formatu daty zwracane przez KSeF") {
                // Siedem cyfr ułamka sekundy z offsetem — postać z przykładów w dokumentacji.
                T.notNil(KsefHTTP.parseDate("2025-07-11T12:23:56.0154302+00:00"), "data z ułamkiem i offsetem")
                T.notNil(KsefHTTP.parseDate("2025-10-11T12:23:56.0154302"), "data z ułamkiem bez offsetu")
                T.notNil(KsefHTTP.parseDate("2025-07-11T12:23:56Z"), "data w UTC")
                T.notNil(KsefHTTP.parseDate("2026-07-15"), "sama data")
                T.isNil(KsefHTTP.parseDate("to nie jest data"), "tekst nieparsowalny")

                let reference = KsefHTTP.parseDate("2025-07-11T12:23:56Z")!
                let withFraction = KsefHTTP.parseDate("2025-07-11T12:23:56.0154302Z")!
                T.expect(abs(withFraction.timeIntervalSince(reference)) < 1,
                         "skrócenie ułamka sekundy nie może przesuwać znacznika czasu")
            }

            T.test("odczytuje nagłówek Retry-After w sekundach i jako datę") {
                let url = URL(string: "https://api.ksef.mf.gov.pl/v2/invoices/query/metadata")!
                let seconds = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil,
                                              headerFields: ["Retry-After": "30"])!
                T.equal(KsefHTTP.parseRetryAfter(seconds), 30, "Retry-After w sekundach")

                let future = Date().addingTimeInterval(120)
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
                let asDate = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil,
                                             headerFields: ["Retry-After": formatter.string(from: future)])!
                if let value = KsefHTTP.parseRetryAfter(asDate) {
                    T.expect(value > 100 && value < 130, "Retry-After jako data HTTP (otrzymano \(value))")
                } else {
                    T.fail("nie odczytano Retry-After podanego jako data")
                }

                let missing = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: [:])!
                T.isNil(KsefHTTP.parseRetryAfter(missing), "brak nagłówka Retry-After")
            }

            T.test("mapuje Problem Details na błąd z kodem KSeF") {
                let url = URL(string: "https://api.ksef.mf.gov.pl/v2/auth/token/redeem")!
                let response = HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: [:])!
                let body = Data("""
                {"title":"Bad Request","status":400,"detail":"Żądanie jest nieprawidłowe.",
                 "errors":[{"code":21301,"description":"Brak autoryzacji.","details":["Tokeny już pobrane."]}],
                 "traceId":"trace-1"}
                """.utf8)

                let error = KsefHTTP.makeError(status: 400, headers: response, data: body)
                T.equal(error.codes, [21301], "kod błędu KSeF")
                T.expect(error.isTransientRedeem, "błąd 21301 musi być rozpoznany jako przejściowy")
                let description = error.errorDescription ?? ""
                T.expect(description.contains("21301"), "opis błędu musi zawierać kod KSeF")
                T.expect(description.contains("Brak autoryzacji"), "opis błędu musi zawierać treść z API")
                T.expect(description.contains("trace-1"), "opis błędu musi zawierać traceId")
            }

            T.test("mapuje odpowiedź 429 wraz z czasem oczekiwania") {
                let url = URL(string: "https://api.ksef.mf.gov.pl/v2/invoices/query/metadata")!
                let response = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil,
                                               headerFields: ["Retry-After": "45"])!
                let body = Data(#"{"status":{"code":429,"description":"Too Many Requests","details":["Limit 20/min."]}}"#.utf8)

                let error = KsefHTTP.makeError(status: 429, headers: response, data: body)
                guard case let .rateLimited(retryAfter, message) = error else {
                    T.fail("oczekiwano błędu rateLimited, otrzymano \(error)")
                    return
                }
                T.equal(retryAfter, 45, "czas oczekiwania z nagłówka")
                T.expect(message.contains("Limit"), "komunikat z API musi zostać zachowany")
                T.expect(error.isRetryable, "429 musi być ponawialny")
            }

            T.test("redaguje sekrety w komunikacie błędu") {
                let url = URL(string: "https://api.ksef.mf.gov.pl/v2/auth/ksef-token")!
                let response = HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: [:])!
                let body = Data(#"{"title":"Bad Request","status":400,"detail":"Odrzucono token eyJhbGciOiJIUzI1NiJ9.eyJhIjoxfQ.zzz","errors":[],"traceId":"t"}"#.utf8)

                let error = KsefHTTP.makeError(status: 400, headers: response, data: body)
                let description = error.errorDescription ?? ""
                T.expect(!description.contains("eyJhbGciOiJIUzI1NiJ9"), "JWT nie może trafić do komunikatu błędu")
            }
        }

        T.suite("Uwierzytelnianie na zamockowanym HTTP") {
            T.test("wykonuje przebieg challenge → auth → status → redeem → refresh") {
                MockURLProtocol.reset()
                guard let server = FakeKsefServer() else {
                    T.fail("nie udało się przygotować serwera testowego")
                    return
                }
                server.install()
                defer { MockURLProtocol.reset() }

                let auth = KsefAuth(http: MockURLProtocol.makeHTTP())
                let tokens = try T.runAsync {
                    await auth.configure(nip: "5260250274", token: server.ksefToken)
                    return try await auth.performFullAuthentication()
                }

                T.equal(tokens.accessToken.token, server.accessToken, "wydany access token")
                T.equal(tokens.refreshToken.token, server.refreshToken, "wydany refresh token")

                // Treść zaszyfrowana kluczem publicznym musi mieć postać „token|timestampMs".
                T.equal(server.decryptedAuthPayload,
                        "\(server.ksefToken)|\(server.challengeTimestampMs)",
                        "zaszyfrowany ładunek żądania uwierzytelnienia")

                // Kolejność i komplet wywołań.
                T.expect(!MockURLProtocol.requests(matching: "/security/public-key-certificates").isEmpty,
                         "pobranie klucza publicznego")
                T.expect(!MockURLProtocol.requests(matching: "/auth/challenge").isEmpty, "pobranie challenge")
                T.expect(!MockURLProtocol.requests(matching: "/auth/ksef-token").isEmpty, "żądanie uwierzytelnienia")

                // Status był odpytywany do skutku (serwer raz zwrócił „w toku").
                let statusCalls = MockURLProtocol.requests(matching: server.referenceNumber)
                T.expect(statusCalls.count >= 2, "odpytywanie statusu musi trwać do stanu końcowego (było \(statusCalls.count))")

                // Wykup tokenów został ponowiony po przejściowym błędzie 21301.
                let redeemCalls = MockURLProtocol.requests(matching: "/auth/token/redeem")
                T.expect(redeemCalls.count == 2, "wykup tokenów po błędzie 21301 musi zostać ponowiony (było \(redeemCalls.count))")
                T.equal(redeemCalls.first?.headers["Authorization"], "Bearer \(server.operationToken)",
                        "wykup tokenów używa tokena operacji uwierzytelnienia")

                // Odświeżenie tokena dostępowego refresh tokenem.
                let refreshed = try T.runAsync {
                    await auth.invalidateAccessToken()
                    return try await auth.validAccessToken()
                }
                T.equal(refreshed, server.refreshedAccessToken, "token po odświeżeniu")
                let refreshCalls = MockURLProtocol.requests(matching: "/auth/token/refresh")
                T.equal(refreshCalls.first?.headers["Authorization"], "Bearer \(server.refreshToken)",
                        "odświeżenie używa refresh tokena")
            }

            T.test("zgłasza niepowodzenie uwierzytelnienia ze statusem końcowym") {
                MockURLProtocol.reset()
                defer { MockURLProtocol.reset() }
                guard let server = FakeKsefServer() else { return }
                server.pendingStatusPolls = 0
                MockURLProtocol.handler = { request in
                    if request.method == "GET", request.path.contains("/auth/\(server.referenceNumber)") {
                        let body = try! JSONSerialization.data(withJSONObject: [
                            "startDate": "2026-07-15T10:00:00Z",
                            "authenticationMethod": "Token",
                            "authenticationMethodInfo": ["category": "Token", "code": "Token", "displayName": "Token"],
                            "status": ["code": 450, "description": "Uwierzytelnianie zakończone niepowodzeniem",
                                       "details": ["Nieprawidłowy token"]],
                        ])
                        return (200, ["Content-Type": "application/json"], body)
                    }
                    return try server.handle(request)
                }

                let auth = KsefAuth(http: MockURLProtocol.makeHTTP())
                do {
                    _ = try T.runAsync {
                        await auth.configure(nip: "5260250274", token: server.ksefToken)
                        return try await auth.performFullAuthentication()
                    }
                    T.fail("oczekiwano błędu uwierzytelnienia")
                } catch let error as KsefError {
                    let description = error.errorDescription ?? ""
                    T.expect(description.contains("450"), "komunikat musi zawierać kod statusu")
                    T.expect(description.contains("Nieprawidłowy token"), "komunikat musi zawierać szczegóły z API")
                }
            }
        }

        T.suite("Zapytania o metadane") {
            T.test("pobiera wszystkie strony i deduplikuje po numerze KSeF") {
                MockURLProtocol.reset()
                defer { MockURLProtocol.reset() }
                guard let server = FakeKsefServer() else { return }

                // Druga strona powtarza dwie pozycje z pierwszej — nie mogą trafić do wyniku dwa razy.
                let first = (1 ... 250).map { metadata($0) }
                let second = [metadata(249), metadata(250)] + (251 ... 300).map { metadata($0) }
                server.metadataPages = [(first, true), (second, false)]
                server.install()

                let http = MockURLProtocol.makeHTTP()
                let auth = KsefAuth(http: http)
                let client = KsefClient(http: http, auth: auth, stateDirectory: nil)

                let invoices = try T.runAsync {
                    await auth.configure(nip: "5260250274", token: server.ksefToken)
                    return try await client.fetchAllMetadata(
                        period: MonthPeriod(year: 2026, month: 7),
                        subjectType: .subject1,
                        dateType: .issue
                    )
                }

                T.equal(invoices.count, 300, "łączna liczba faktur po deduplikacji")
                T.equal(Set(invoices.map(\.ksefNumber)).count, 300, "numery KSeF muszą być unikalne")

                let queries = MockURLProtocol.requests(matching: "/invoices/query/metadata")
                T.equal(queries.count, 2, "liczba pobranych stron")
                T.expect(queries[0].query?.contains("pageOffset=0") == true, "pierwsza strona")
                T.expect(queries[1].query?.contains("pageOffset=1") == true, "druga strona")
                T.expect(queries[0].query?.contains("pageSize=250") == true, "maksymalny rozmiar strony")
                T.expect(queries[0].query?.contains("sortOrder=Asc") == true, "sortowanie rosnące")

                // Zakres dat musi obejmować cały miesiąc w strefie warszawskiej.
                if let body = try? JSONSerialization.jsonObject(with: queries[0].body) as? [String: Any],
                   let range = body["dateRange"] as? [String: Any] {
                    T.equal(range["from"] as? String, "2026-07-01T00:00:00.000+02:00", "początek zakresu")
                    T.equal(range["to"] as? String, "2026-07-31T23:59:59.999+02:00", "koniec zakresu")
                    T.equal(range["dateType"] as? String, "Issue", "typ daty")
                    T.equal(body["subjectType"] as? String, "Subject1", "typ podmiotu")
                } else {
                    T.fail("nie udało się odczytać treści zapytania")
                }
            }

            T.test("wznawia pobieranie po odpowiedzi 429") {
                MockURLProtocol.reset()
                defer { MockURLProtocol.reset() }
                guard let server = FakeKsefServer() else { return }

                server.rateLimitResponses = 1
                server.metadataPages = [((1 ... 3).map { metadata($0) }, false)]
                server.install()

                let http = MockURLProtocol.makeHTTP()
                let auth = KsefAuth(http: http)
                let client = KsefClient(http: http, auth: auth, stateDirectory: nil)

                let invoices = try T.runAsync {
                    await auth.configure(nip: "5260250274", token: server.ksefToken)
                    return try await client.fetchAllMetadata(
                        period: MonthPeriod(year: 2026, month: 7),
                        subjectType: .subject2,
                        dateType: .issue
                    )
                }

                // Dane nie mogą zostać utracone — po odczekaniu żądanie jest powtarzane.
                T.equal(invoices.count, 3, "faktury pobrane po wznowieniu")
                T.expect(MockURLProtocol.requests(matching: "/invoices/query/metadata").count >= 2,
                         "żądanie musi zostać powtórzone po 429")
            }
        }

        T.suite("Limity żądań") {
            T.test("wstrzymuje żądania po osiągnięciu progu na sekundę") {
                let limiter = RateLimiter(limits: .init(perSecond: 2, perMinute: 100, perHour: 100),
                                          storageURL: nil)
                let elapsed = try T.runAsync { () -> TimeInterval in
                    let start = Date()
                    for _ in 0 ..< 3 { try await limiter.acquire() }
                    return Date().timeIntervalSince(start)
                }
                T.expect(elapsed >= 1.0,
                         "trzecie żądanie musi poczekać na zwolnienie okna sekundowego (minęło \(String(format: "%.2f", elapsed)) s)")
            }

            T.test("szacuje czas pobierania długiej kolejki") {
                let limiter = RateLimiter(limits: .invoiceDownload, storageURL: nil)
                let estimate = try T.runAsync { await limiter.estimatedDuration(for: 100) }
                // 100 faktur przekracza limit 64/h, więc kolejka musi rozciągnąć się w czasie.
                T.expect(estimate > 1800,
                         "szacowany czas dla 100 faktur powinien przekraczać pół godziny (otrzymano \(Int(estimate)) s)")

                let short = try T.runAsync { await limiter.estimatedDuration(for: 3) }
                T.expect(short < 5, "krótka kolejka nie powinna wymagać oczekiwania (otrzymano \(short) s)")
            }

            T.test("utrwala licznik godzinowy między uruchomieniami") {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ksef-tests-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let storage = directory.appendingPathComponent("limit.json")

                try T.runAsync {
                    let first = RateLimiter(limits: .invoiceDownload, storageURL: storage)
                    for _ in 0 ..< 5 { try await first.acquire() }
                    let used = await first.usedInLastHour
                    T.equal(used, 5, "licznik w bieżącej instancji")
                }

                try T.runAsync {
                    // Nowa instancja odczytuje stan z dysku — restart aplikacji nie zeruje limitu.
                    let second = RateLimiter(limits: .invoiceDownload, storageURL: storage)
                    let used = await second.usedInLastHour
                    T.equal(used, 5, "licznik odtworzony po restarcie")
                    let remaining = await second.remainingInHour
                    T.equal(remaining, 59, "pozostały limit godzinowy (64 − 5)")
                }
            }

            T.test("wybiera eksport paczki, gdy pobieranie pojedyncze nie zmieści się w limicie") {
                let http = MockURLProtocol.makeHTTP()
                let client = KsefClient(http: http, auth: KsefAuth(http: http), stateDirectory: nil)

                let small = try T.runAsync { await client.chooseStrategy(invoiceCount: 20) }
                T.equal(small, .single, "20 faktur mieści się w limicie godzinowym")

                let large = try T.runAsync { await client.chooseStrategy(invoiceCount: 200) }
                T.equal(large, .export, "200 faktur wymaga eksportu paczki")
            }
        }

        T.suite("Archiwum ZIP") {
            T.test("odczytuje archiwum zapisane bez kompresji") {
                let files = [
                    (name: "5260250274-20260715-01ABCDEF-01.xml", data: Data(Fixtures.fa3Standard.utf8)),
                    (name: "_metadata.json", data: Data(#"{"invoices":[]}"#.utf8)),
                ]
                let archive = ZipArchive.makeStoredArchive(files: files)
                let entries = try ZipArchive.entries(in: archive)

                T.equal(entries.count, 2, "liczba plików w archiwum")
                T.equal(entries.first { $0.name.hasSuffix(".xml") }?.data,
                        Data(Fixtures.fa3Standard.utf8), "zawartość pliku XML")
                T.equal(entries.first { $0.name == "_metadata.json" }?.data,
                        Data(#"{"invoices":[]}"#.utf8), "zawartość pliku metadanych")
            }

            T.test("odrzuca dane, które nie są archiwum") {
                T.throwsError("przypadkowe bajty") {
                    _ = try ZipArchive.entries(in: Data(repeating: 0x41, count: 200))
                }
            }

            T.test("liczy CRC-32 zgodnie ze standardem") {
                // Wektor kontrolny: CRC-32 ciągu „123456789".
                T.equal(ZipArchive.crc32(Data("123456789".utf8)), 0xCBF4_3926, "CRC-32 wektora kontrolnego")
            }
        }
    }
}
