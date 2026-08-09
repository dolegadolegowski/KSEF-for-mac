import Foundation

/// Trwałe przechowywanie danych: cache pobranych faktur oraz zapis wyników
/// do katalogu wskazanego przez użytkownika.
///
/// Cache jest izolowany per NIP — zmiana kontekstu kasuje dane poprzedniego podmiotu.
enum Storage {
    // MARK: - Katalogi aplikacji

    /// `~/Library/Application Support/KSeF Faktury/`
    static func applicationSupportDirectory() -> URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil,
                                     create: true) else { return nil }
        let directory = base.appendingPathComponent("KSeF Faktury", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Katalog cache dla konkretnego kontekstu NIP.
    static func cacheDirectory(forNip nip: String) -> URL? {
        guard let base = applicationSupportDirectory() else { return nil }
        let directory = base
            .appendingPathComponent("konteksty", isDirectory: true)
            .appendingPathComponent(Nip.normalize(nip), isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Katalog cache dla konkretnego miesiąca.
    static func cacheDirectory(forNip nip: String, period: MonthPeriod) -> URL? {
        guard let base = cacheDirectory(forNip: nip) else { return nil }
        let directory = base.appendingPathComponent(period.tag, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Usuwa cache wszystkich kontekstów poza wskazanym.
    /// Wywoływane po zmianie NIP-u, żeby dane poprzedniego podmiotu nie zostały na dysku.
    static func purgeContexts(keeping nip: String) {
        guard let base = applicationSupportDirectory()?
            .appendingPathComponent("konteksty", isDirectory: true) else { return }
        let keep = Nip.normalize(nip)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: base.path) else { return }
        for entry in entries where entry != keep {
            try? fm.removeItem(at: base.appendingPathComponent(entry))
            logInfo("Usunięto cache poprzedniego kontekstu.")
        }
    }

    static func clearCache(forNip nip: String) {
        guard let directory = cacheDirectory(forNip: nip) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Zapis atomowy z kopią zapasową

    /// Zapisuje dane atomowo, zachowując poprzednią wersję w pliku `.bak`.
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        if fm.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("bak")
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: url, to: backup)
        }
        try data.write(to: url, options: .atomic)
    }

    /// Odczytuje dane, sięgając po kopię `.bak`, gdy plik główny jest uszkodzony.
    static func readWithFallback(_ url: URL) -> Data? {
        if let data = try? Data(contentsOf: url), !data.isEmpty { return data }
        let backup = url.appendingPathExtension("bak")
        if let data = try? Data(contentsOf: backup), !data.isEmpty {
            logWarn("Odczytano kopię zapasową pliku \(url.lastPathComponent) — plik główny był uszkodzony.")
            return data
        }
        return nil
    }

    /// Zapisuje obiekt w formacie JSON.
    static func writeJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try writeAtomically(try encoder.encode(value), to: url)
    }

    /// Odczytuje obiekt z formatu JSON, korzystając w razie potrzeby z kopii zapasowej.
    static func readJSON<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard let data = readWithFallback(url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    // MARK: - Nazwy plików

    /// Zamienia polskie znaki diakrytyczne na odpowiedniki ASCII.
    static func transliterate(_ text: String) -> String {
        let mapping: [Character: String] = [
            "ą": "a", "ć": "c", "ę": "e", "ł": "l", "ń": "n",
            "ó": "o", "ś": "s", "ź": "z", "ż": "z",
            "Ą": "A", "Ć": "C", "Ę": "E", "Ł": "L", "Ń": "N",
            "Ó": "O", "Ś": "S", "Ź": "Z", "Ż": "Z",
        ]
        var out = ""
        for character in text {
            if let replacement = mapping[character] {
                out += replacement
            } else if character.isASCII {
                out.append(character)
            } else {
                // Pozostałe znaki spoza ASCII rozkładamy i odrzucamy znaki łączące.
                let folded = String(character).folding(options: [.diacriticInsensitive], locale: Fmt.locale)
                out += folded.filter(\.isASCII)
            }
        }
        return out
    }

    /// Buduje bezpieczny dla systemu plików fragment nazwy: same litery, cyfry i myślniki.
    static func slug(_ text: String, uppercase: Bool = false, maxLength: Int = 40) -> String {
        var out = ""
        var lastWasDash = true
        for character in transliterate(text) {
            if character.isLetter || character.isNumber {
                out.append(character)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > maxLength { out = String(out.prefix(maxLength)) }
        while out.hasSuffix("-") { out.removeLast() }
        return uppercase ? out.uppercased() : out
    }

    /// Deterministyczna nazwa pliku PDF, np.
    /// `WYSTAWIONE_2026-07_FV-123-2026_NABYWCA-SP-Z-O-O_1234.56PLN.pdf`.
    static func pdfFileName(for invoice: Invoice, period: MonthPeriod) -> String {
        let prefix = invoice.direction.filePrefix
        let number = slug(invoice.invoiceNumber, uppercase: false, maxLength: 40)
        let counterparty = slug(invoice.counterparty.displayName, uppercase: true, maxLength: 40)
        // Kwota bez separatorów tysięcy i z kropką dziesiętną — nazwa ma być stabilna
        // i niezależna od ustawień regionalnych.
        let amount = NSDecimalNumber(decimal: invoice.totalGross.roundedToCents()).stringValue
        let currency = invoice.currency.uppercased()

        var components = [prefix, period.tag, number, counterparty]
        components = components.filter { !$0.isEmpty }
        return components.joined(separator: "_") + "_\(amount)\(currency).pdf"
    }

    /// Nazwa pliku z oryginalnym dokumentem XML.
    static func xmlFileName(for invoice: Invoice) -> String {
        let number = slug(invoice.ksefNumber, maxLength: 60)
        return "\(number.isEmpty ? "faktura" : number).xml"
    }

    // MARK: - Katalog wyjściowy

    /// Struktura katalogu wyników dla danego miesiąca.
    struct OutputLayout {
        let root: URL
        let issued: URL
        let received: URL
        let xml: URL

        var summaryHTML: URL { root.appendingPathComponent("podsumowanie.html") }
        var messageEML: URL { root.appendingPathComponent("wiadomosc.eml") }
    }

    /// Tworzy `KSeF_RRRR-MM/` z podkatalogami `wystawione/`, `otrzymane/` i `xml/`.
    static func prepareOutput(in directory: URL, period: MonthPeriod) throws -> OutputLayout {
        let root = directory.appendingPathComponent("KSeF_\(period.tag)", isDirectory: true)
        let layout = OutputLayout(
            root: root,
            issued: root.appendingPathComponent("wystawione", isDirectory: true),
            received: root.appendingPathComponent("otrzymane", isDirectory: true),
            xml: root.appendingPathComponent("xml", isDirectory: true)
        )
        let fm = FileManager.default
        for url in [layout.root, layout.issued, layout.received, layout.xml] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return layout
    }

    static func directory(for direction: InvoiceDirection, in layout: OutputLayout) -> URL {
        direction == .issued ? layout.issued : layout.received
    }
}

/// Zestaw faktur pobranych za dany miesiąc, wraz z informacją o sposobie pobrania.
struct InvoiceSet {
    var period: MonthPeriod
    var nip: String
    var issued: [Invoice] = []
    var received: [Invoice] = []
    var strategy: DownloadStrategy = .single
    var fetchedAt = Date()
    /// Ostrzeżenia napotkane w trakcie pobierania — pokazywane w UI bez przerywania pracy.
    var warnings: [String] = []

    var all: [Invoice] { issued + received }
    var isEmpty: Bool { issued.isEmpty && received.isEmpty }
}
