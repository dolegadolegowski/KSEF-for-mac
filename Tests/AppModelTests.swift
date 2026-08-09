import Foundation

/// Testy pełnego przepływu aplikacji: od zapytania o metadane, przez pobranie treści faktur
/// i ich parsowanie, po wygenerowanie plików PDF i struktury katalogu wyników.
enum AppModelTests {
    private static let testNip = "5260250274"

    /// Metadane odpowiadające fakturom z fixtur.
    private static func metadata(ksefNumber: String, invoiceNumber: String) -> InvoiceMetadata {
        InvoiceMetadata(
            ksefNumber: ksefNumber, invoiceNumber: invoiceNumber, issueDate: "2026-07-15",
            invoicingDate: nil, acquisitionDate: nil, permanentStorageDate: nil,
            seller: InvoiceMetadataSeller(nip: testNip, name: "Przykładowa Spółka z o.o."),
            buyer: InvoiceMetadataBuyer(
                identifier: InvoiceMetadataBuyerIdentifier(type: "Nip", value: "7010001453"),
                name: "Nabywca Ćwiczebny S.A."
            ),
            netAmount: 1500, grossAmount: 1770, vatAmount: 270, currency: "PLN",
            invoicingMode: "Online", invoiceType: "Vat",
            formCode: FormCode(systemCode: "FA (3)", schemaVersion: "1-0E", value: "FA"),
            isSelfInvoicing: false, hasAttachment: false,
            invoiceHash: nil, hashOfCorrectedInvoice: nil
        )
    }

    /// Czeka, aż model zakończy pracę w tle.
    private static func waitUntilIdle(_ model: AppModel, timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let busy = await MainActor.run { model.isBusy }
            if !busy { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw KsefError.network("Model nie zakończył pracy w wyznaczonym czasie.")
    }

    static func run() {
        T.suite("Przepływ aplikacji") {
            T.test("pobiera, parsuje i renderuje faktury obu kierunków") {
                MockURLProtocol.reset()
                defer {
                    MockURLProtocol.reset()
                    Storage.clearCache(forNip: testNip)
                }
                guard let server = FakeKsefServer() else {
                    T.fail("nie udało się przygotować serwera testowego")
                    return
                }
                // Pierwsze zapytanie dotyczy faktur wystawionych, drugie otrzymanych.
                server.metadataPages = [
                    ([metadata(ksefNumber: "5260250274-20260715-01ABCDEF-01",
                               invoiceNumber: "FV/123/2026")], false),
                    ([metadata(ksefNumber: "5260250274-20260715-02ABCDEF-01",
                               invoiceNumber: "FV/999/2026")], false),
                ]
                server.install()
                Storage.clearCache(forNip: testNip)

                let suiteName = "pl.ksef.faktury.testy-\(UUID().uuidString)"
                let model = try T.runAsync { () -> AppModel in
                    await MainActor.run {
                        let settings = AppSettings(defaults: UserDefaults(suiteName: suiteName)!)
                        settings.nip = testNip
                        let model = AppModel(settings: settings,
                                             http: MockURLProtocol.makeHTTP(),
                                             tokenProvider: { _ in server.ksefToken })
                        model.period = MonthPeriod(year: 2026, month: 7)
                        return model
                    }
                }

                try T.runAsync {
                    await MainActor.run {
                        T.expect(model.hasUsableConfiguration, "konfiguracja powinna być kompletna")
                        model.fetch(forceRefresh: true)
                    }
                    try await waitUntilIdle(model)
                }

                try T.runAsync {
                    await MainActor.run {
                        if let error = model.errorMessage {
                            T.fail("pobieranie zakończyło się błędem: \(error) \(model.errorDetails ?? "")")
                        }
                        T.equal(model.step, .results, "krok po zakończeniu pobierania")

                        guard let set = model.invoiceSet else {
                            T.fail("brak zestawu faktur")
                            return
                        }
                        T.equal(set.issued.count, 1, "liczba faktur wystawionych")
                        T.equal(set.received.count, 1, "liczba faktur otrzymanych")
                        T.equal(set.strategy, .single, "wybrana ścieżka pobierania")
                        T.equal(set.issued.first?.direction, .issued, "kierunek faktury wystawionej")
                        T.equal(set.received.first?.direction, .received, "kierunek faktury otrzymanej")

                        // Kwoty pochodzą z parsowania XML, a nie z przybliżonych metadanych.
                        T.equal(set.issued.first?.totalNet, Decimal(string: "1500.00"), "netto z dokumentu XML")
                        T.equal(set.issued.first?.totalGross, Decimal(string: "1770.00"), "brutto z dokumentu XML")

                        T.equal(model.pdfs.count, 2, "liczba wygenerowanych plików PDF")
                        for (ksefNumber, data) in model.pdfs {
                            T.expect(data.count > 1000, "PDF dla \(ksefNumber) musi mieć sensowny rozmiar")
                            T.expect(data.starts(with: Data("%PDF".utf8)), "plik musi być dokumentem PDF")
                        }
                    }
                }
            }

            T.test("zapisuje strukturę katalogu wyników") {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ksef-wyniki-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }

                let period = MonthPeriod(year: 2026, month: 7)
                var set = InvoiceSet(period: period, nip: testNip)
                let issued = try InvoiceParser.parse(xml: Data(Fixtures.fa3Standard.utf8),
                                                     ksefNumber: "5260250274-20260715-01ABCDEF-01",
                                                     direction: .issued)
                let received = try InvoiceParser.parse(xml: Data(Fixtures.fa2Standard.utf8),
                                                       ksefNumber: "7010001453-20240311-0ARCH-01",
                                                       direction: .received)
                set.issued = [issued]
                set.received = [received]

                let suiteName = "pl.ksef.faktury.testy-\(UUID().uuidString)"
                let layout = try T.runAsync { () -> Storage.OutputLayout in
                    try await MainActor.run {
                        let settings = AppSettings(defaults: UserDefaults(suiteName: suiteName)!)
                        settings.nip = testNip
                        let model = AppModel(settings: settings,
                                             http: MockURLProtocol.makeHTTP(),
                                             tokenProvider: { _ in "token" })
                        model.invoiceSet = set
                        model.pdfs = [
                            issued.ksefNumber: PdfRenderer.render(issued),
                            received.ksefNumber: PdfRenderer.render(received),
                        ]
                        return try model.writeOutput(set: set, to: directory)
                    }
                }

                let fm = FileManager.default
                T.expect(layout.root.lastPathComponent == "KSeF_2026-07",
                         "katalog główny musi nazywać się KSeF_2026-07 (jest \(layout.root.lastPathComponent))")

                let issuedFiles = (try? fm.contentsOfDirectory(atPath: layout.issued.path)) ?? []
                let receivedFiles = (try? fm.contentsOfDirectory(atPath: layout.received.path)) ?? []
                let xmlFiles = (try? fm.contentsOfDirectory(atPath: layout.xml.path)) ?? []

                T.equal(issuedFiles.filter { $0.hasSuffix(".pdf") }.count, 1, "PDF w katalogu wystawione/")
                T.equal(receivedFiles.filter { $0.hasSuffix(".pdf") }.count, 1, "PDF w katalogu otrzymane/")
                T.equal(xmlFiles.filter { $0.hasSuffix(".xml") }.count, 2, "oryginalne dokumenty XML")
                T.expect(fm.fileExists(atPath: layout.summaryHTML.path), "podsumowanie.html")

                // Oryginalny XML musi być zapisany bez żadnych zmian.
                let savedXML = try Data(contentsOf: layout.xml
                    .appendingPathComponent(Storage.xmlFileName(for: issued)))
                T.equal(savedXML, Data(Fixtures.fa3Standard.utf8), "zapisany XML musi być identyczny z pobranym")

                T.expect(issuedFiles.contains { $0.hasPrefix("WYSTAWIONE_2026-07_") },
                         "nazwa pliku faktury wystawionej (jest \(issuedFiles))")
                T.expect(receivedFiles.contains { $0.hasPrefix("OTRZYMANE_2026-07_") },
                         "nazwa pliku faktury otrzymanej (jest \(receivedFiles))")
            }

            T.test("odtwarza dane z lokalnej kopii bez łączenia się z KSeF") {
                defer { Storage.clearCache(forNip: testNip) }
                Storage.clearCache(forNip: testNip)

                let period = MonthPeriod(year: 2026, month: 6)
                var set = InvoiceSet(period: period, nip: testNip)
                let invoice = try InvoiceParser.parse(xml: Data(Fixtures.fa3Standard.utf8),
                                                      ksefNumber: "5260250274-20260615-0CACHE-01",
                                                      direction: .issued)
                set.issued = [invoice]
                let pdf = PdfRenderer.render(invoice)

                InvoiceCache.save(set: set, pdfs: [invoice.ksefNumber: pdf])
                T.expect(InvoiceCache.hasCache(nip: testNip, period: period), "cache powinien istnieć")

                guard let restored = InvoiceCache.load(nip: testNip, period: period) else {
                    T.fail("nie udało się odczytać lokalnej kopii")
                    return
                }
                T.equal(restored.set.issued.count, 1, "liczba faktur z lokalnej kopii")
                T.equal(restored.set.issued.first?.invoiceNumber, "FV/123/2026", "numer faktury z lokalnej kopii")
                T.equal(restored.set.issued.first?.rawXML, invoice.rawXML, "zachowany dokument źródłowy")
                T.equal(restored.pdfs[invoice.ksefNumber]?.count, pdf.count, "zachowany plik PDF")
            }

            T.test("zapis atomowy zostawia kopię zapasową i odtwarza dane") {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ksef-atomic-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }

                let file = directory.appendingPathComponent("dane.json")
                try Storage.writeAtomically(Data("pierwsza wersja".utf8), to: file)
                try Storage.writeAtomically(Data("druga wersja".utf8), to: file)

                T.equal(Storage.readWithFallback(file), Data("druga wersja".utf8), "aktualna zawartość")
                T.expect(FileManager.default.fileExists(atPath: file.appendingPathExtension("bak").path),
                         "kopia zapasowa musi powstać przy nadpisaniu")

                // Uszkodzony plik główny — odczyt musi sięgnąć po kopię zapasową.
                try Data().write(to: file)
                T.equal(Storage.readWithFallback(file), Data("pierwsza wersja".utf8),
                        "odczyt z kopii zapasowej po uszkodzeniu pliku")
            }
        }
    }
}
