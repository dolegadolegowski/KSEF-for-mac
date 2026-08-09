import Foundation

/// Lokalny cache pobranych faktur, izolowany per NIP i miesiąc.
///
/// Oryginalne pliki XML zapisywane są bez zmian — to one są dokumentem źródłowym.
/// PDF-y trzymamy obok, żeby ponowne otwarcie miesiąca nie wymagało ponownego renderowania.
enum InvoiceCache {
    /// Wpis katalogu miesiąca: metadane faktury i jej kierunek.
    struct Record: Codable {
        let ksefNumber: String
        let direction: InvoiceDirection
        let metadata: InvoiceMetadata?
    }

    struct Manifest: Codable {
        var nip: String
        var year: Int
        var month: Int
        var fetchedAt: Date
        var strategy: String
        var records: [Record]
        var warnings: [String]
    }

    private static func manifestURL(nip: String, period: MonthPeriod) -> URL? {
        Storage.cacheDirectory(forNip: nip, period: period)?.appendingPathComponent("manifest.json")
    }

    private static func xmlURL(nip: String, period: MonthPeriod, ksefNumber: String) -> URL? {
        Storage.cacheDirectory(forNip: nip, period: period)?
            .appendingPathComponent("xml", isDirectory: true)
            .appendingPathComponent("\(Storage.slug(ksefNumber, maxLength: 60)).xml")
    }

    private static func pdfURL(nip: String, period: MonthPeriod, ksefNumber: String) -> URL? {
        Storage.cacheDirectory(forNip: nip, period: period)?
            .appendingPathComponent("pdf", isDirectory: true)
            .appendingPathComponent("\(Storage.slug(ksefNumber, maxLength: 60)).pdf")
    }

    /// Czy dla danego miesiąca istnieje kompletny zapis w magazynie aplikacji.
    static func hasCache(nip: String, period: MonthPeriod) -> Bool {
        guard let url = manifestURL(nip: nip, period: period) else { return false }
        return Storage.readWithFallback(url) != nil
    }

    /// Miesiące zapisane w magazynie dla danego kontekstu, od najnowszego.
    /// Pozwala przywrócić ostatnio oglądany okres bez łączenia się z KSeF.
    static func availablePeriods(forNip nip: String) -> [MonthPeriod] {
        guard let base = Storage.cacheDirectory(forNip: nip),
              let entries = try? FileManager.default.contentsOfDirectory(atPath: base.path)
        else { return [] }

        return entries.compactMap { entry -> MonthPeriod? in
            // Katalogi miesięcy nazywają się „RRRR-MM".
            let parts = entry.split(separator: "-")
            guard parts.count == 2,
                  let year = Int(parts[0]), let month = Int(parts[1]),
                  (1 ... 12).contains(month) else { return nil }
            let period = MonthPeriod(year: year, month: month)
            return hasCache(nip: nip, period: period) ? period : nil
        }
        .sorted { ($0.year, $0.month) > ($1.year, $1.month) }
    }

    // MARK: - Zapis

    static func save(set: InvoiceSet, pdfs: [String: Data]) {
        guard let manifestURL = manifestURL(nip: set.nip, period: set.period) else { return }

        var records: [Record] = []
        for invoice in set.all {
            records.append(Record(ksefNumber: invoice.ksefNumber,
                                  direction: invoice.direction,
                                  metadata: nil))

            if let xmlURL = xmlURL(nip: set.nip, period: set.period, ksefNumber: invoice.ksefNumber) {
                try? Storage.writeAtomically(invoice.rawXML, to: xmlURL)
            }
            if let data = pdfs[invoice.ksefNumber],
               let pdfURL = pdfURL(nip: set.nip, period: set.period, ksefNumber: invoice.ksefNumber) {
                try? Storage.writeAtomically(data, to: pdfURL)
            }
        }

        let manifest = Manifest(
            nip: set.nip,
            year: set.period.year,
            month: set.period.month,
            fetchedAt: set.fetchedAt,
            strategy: set.strategy.rawValue,
            records: records,
            warnings: set.warnings
        )
        try? Storage.writeJSON(manifest, to: manifestURL)
        logInfo("Zapisano w cache \(records.count) faktur za \(set.period.tag).")
    }

    // MARK: - Odczyt

    /// Odtwarza zestaw faktur z cache. Zwraca `nil`, gdy zapisu nie ma lub jest niekompletny.
    static func load(nip: String, period: MonthPeriod) -> (set: InvoiceSet, pdfs: [String: Data])? {
        guard let manifestURL = manifestURL(nip: nip, period: period),
              let manifest = Storage.readJSON(Manifest.self, from: manifestURL) else { return nil }

        var set = InvoiceSet(period: period, nip: nip)
        set.fetchedAt = manifest.fetchedAt
        set.strategy = DownloadStrategy(rawValue: manifest.strategy) ?? .single
        set.warnings = manifest.warnings
        var pdfs: [String: Data] = [:]

        for record in manifest.records {
            guard let xmlURL = xmlURL(nip: nip, period: period, ksefNumber: record.ksefNumber),
                  let xml = Storage.readWithFallback(xmlURL) else {
                logWarn("Brak pliku XML w cache dla faktury \(record.ksefNumber).")
                continue
            }
            guard let invoice = try? InvoiceParser.parse(xml: xml,
                                                         ksefNumber: record.ksefNumber,
                                                         direction: record.direction,
                                                         metadata: record.metadata) else {
                logWarn("Nie udało się odczytać faktury \(record.ksefNumber) z cache.")
                continue
            }
            if record.direction == .issued { set.issued.append(invoice) } else { set.received.append(invoice) }

            if let pdfURL = pdfURL(nip: nip, period: period, ksefNumber: record.ksefNumber),
               let data = Storage.readWithFallback(pdfURL) {
                pdfs[record.ksefNumber] = data
            }
        }

        guard !set.isEmpty || manifest.records.isEmpty else { return nil }
        logInfo("Wczytano z cache \(set.all.count) faktur za \(period.tag).")
        return (set, pdfs)
    }
}
