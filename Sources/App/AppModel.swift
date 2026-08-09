import AppKit
import Foundation
import SwiftUI

/// Stan połączenia pokazywany w nagłówku okna.
enum ConnectionStatus: Equatable {
    case unknown
    case checking
    case connected(String)
    case failed(String)

    var label: String {
        switch self {
        case .unknown: return "Nie sprawdzono połączenia"
        case .checking: return "Sprawdzanie połączenia…"
        case let .connected(detail): return detail
        case let .failed(detail): return detail
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// Stan okna głównego. Aplikacja startuje od razu na podglądzie miesiąca —
/// wybór okresu odbywa się listą rozwijaną w nagłówku, nie osobnym krokiem.
enum WorkflowStep: Int, Comparable {
    case downloading = 1
    case results = 2

    static func < (lhs: WorkflowStep, rhs: WorkflowStep) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Model aplikacji: łączy ustawienia, klienta KSeF, parser, generator PDF i eksport wyników.
@MainActor
final class AppModel: ObservableObject {
    @Published var step: WorkflowStep = .results
    @Published var period: MonthPeriod = .current()
    /// Miesiące zapisane w pamięci aplikacji — oznaczane na liście rozwijanej.
    @Published var storedPeriods: Set<MonthPeriod> = []
    @Published var connection: ConnectionStatus = .unknown
    @Published var progress: FetchProgress?
    @Published var invoiceSet: InvoiceSet?
    @Published var pdfs: [String: Data] = [:]
    @Published var errorMessage: String?
    @Published var errorDetails: String?
    @Published var infoMessage: String?
    @Published var isBusy = false
    @Published var selectedInvoice: Invoice?
    @Published var lastOutputDirectory: URL?
    @Published var availableUpdate: AppRelease?
    @Published var updateStatus: String?

    let settings: AppSettings

    private let http: KsefHTTP
    private let auth: KsefAuth
    private let client: KsefClient
    private let updateChecker: UpdateChecker
    private var currentTask: Task<Void, Never>?

    /// Źródło tokena KSeF. Domyślnie Keychain; podmieniane w testach, żeby nie sięgać
    /// do pęku kluczy użytkownika.
    private let tokenProvider: (String) -> String?

    init(settings: AppSettings = .shared,
         http: KsefHTTP = KsefHTTP(),
         updateChecker: UpdateChecker = UpdateChecker(),
         tokenProvider: @escaping (String) -> String? = { try? Keychain.loadToken(forNip: $0) }) {
        self.settings = settings
        self.http = http
        self.updateChecker = updateChecker
        self.tokenProvider = tokenProvider
        auth = KsefAuth(http: http)
        client = KsefClient(
            http: http,
            auth: auth,
            stateDirectory: Storage.cacheDirectory(forNip: settings.normalizedNip)
        )
    }

    // MARK: - Konfiguracja

    var hasUsableConfiguration: Bool {
        guard settings.isNipValid else { return false }
        let token = tokenProvider(settings.normalizedNip)
        return !(token ?? "").isEmpty
    }

    var cacheAvailable: Bool {
        settings.isNipValid && InvoiceCache.hasCache(nip: settings.normalizedNip, period: period)
    }

    /// Zapisuje token w Keychain i resetuje sesję, żeby kolejne żądanie użyło nowych danych.
    func saveToken(_ token: String) {
        guard settings.isNipValid else {
            showError("Podany NIP jest nieprawidłowy — sprawdź sumę kontrolną.")
            return
        }
        do {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                try Keychain.deleteToken(forNip: settings.normalizedNip)
            } else {
                try Keychain.saveToken(trimmed, forNip: settings.normalizedNip)
            }
            connection = .unknown
            Task { await auth.reset() }
        } catch {
            showError("Nie udało się zapisać tokena.", details: error.localizedDescription)
        }
    }

    /// Po zmianie kontekstu kasujemy dane poprzedniego podmiotu.
    func handleContextChange() {
        guard settings.isNipValid else { return }
        Storage.purgeContexts(keeping: settings.normalizedNip)
        invoiceSet = nil
        pdfs = [:]
        step = .results
        connection = .unknown
        Task { await auth.reset() }
    }

    // MARK: - Sprawdzenie połączenia

    func checkConnection() {
        guard settings.isNipValid else {
            connection = .failed("Nieprawidłowy NIP — sprawdź sumę kontrolną.")
            return
        }
        guard let token = tokenProvider(settings.normalizedNip), !token.isEmpty else {
            connection = .failed("Brak tokena KSeF dla tego NIP-u. Uzupełnij go w ustawieniach.")
            return
        }

        connection = .checking
        isBusy = true
        currentTask?.cancel()
        currentTask = Task {
            defer { isBusy = false }
            do {
                let result = try await auth.checkConnection(nip: settings.normalizedNip, token: token)
                if result.hasInvoiceRead {
                    var text = "Połączono z KSeF w kontekście NIP \(result.contextNip). "
                    text += "Uprawnienie InvoiceRead potwierdzone. "
                    text += "Token ważny do \(Fmt.dateTime(result.accessTokenValidUntil))."
                    if let note = result.note { text += " \(note)" }
                    connection = .connected(text)
                } else {
                    var text = "Uwierzytelnienie powiodło się, ale token nie ma uprawnienia InvoiceRead."
                    if let note = result.note { text += " \(note)" }
                    connection = .failed(text)
                }
            } catch is CancellationError {
                connection = .unknown
            } catch {
                connection = .failed(describe(error))
            }
        }
    }

    // MARK: - Pobieranie

    func fetch(forceRefresh: Bool = false) {
        guard settings.isNipValid else {
            showError("Podaj poprawny NIP w ustawieniach (⌘,).")
            return
        }
        guard let token = tokenProvider(settings.normalizedNip), !token.isEmpty else {
            showError("Brak tokena KSeF. Uzupełnij go w ustawieniach (⌘,).")
            return
        }

        errorMessage = nil
        errorDetails = nil
        infoMessage = nil

        // Ponowne otwarcie tego samego miesiąca korzysta z cache, o ile użytkownik
        // nie zażądał odświeżenia.
        if !forceRefresh, let cached = InvoiceCache.load(nip: settings.normalizedNip, period: period) {
            invoiceSet = cached.set
            pdfs = cached.pdfs
            step = .results
            infoMessage = "Dane wczytane z pamięci aplikacji (pobrano \(Fmt.dateTime(cached.set.fetchedAt))). "
                + "Użyj „Pobierz ponownie”, aby odświeżyć z KSeF."
            materializeOutputs()
            updateCompanyName()
            return
        }

        step = .downloading
        isBusy = true
        progress = FetchProgress(stage: "Uwierzytelnianie", current: 0, total: 1, detail: nil)

        currentTask?.cancel()
        let nip = settings.normalizedNip
        let dateType = settings.dateType
        let period = period

        currentTask = Task {
            defer { isBusy = false }
            do {
                let result = try await performFetch(nip: nip, token: token, period: period, dateType: dateType)
                invoiceSet = result.set
                pdfs = result.pdfs
                progress = nil
                step = .results
                updateCompanyName()
                // Zapis w magazynie aplikacji: przy kolejnym uruchomieniu faktury są
                // od razu dostępne, bez ponownego pobierania z KSeF.
                InvoiceCache.save(set: result.set, pdfs: result.pdfs)
                materializeOutputs()
                // Miesiąc dołącza do oznaczonych kropką na liście rozwijanej.
                refreshStoredPeriods()
            } catch is CancellationError {
                progress = nil
                step = .results
                infoMessage = "Pobieranie przerwane. Dotychczasowa lokalna kopia pozostała nienaruszona."
            } catch let error as KsefError where error.errorDescription?.contains("przerwana") == true {
                progress = nil
                step = .results
                infoMessage = "Pobieranie przerwane."
            } catch {
                progress = nil
                step = .results
                showError("Pobieranie faktur nie powiodło się.", details: describe(error))
            }
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    /// Właściwy przebieg pobierania: metadane obu kierunków, treści faktur, parsowanie i PDF-y.
    private func performFetch(nip: String, token: String,
                              period: MonthPeriod,
                              dateType: InvoiceDateType) async throws -> (set: InvoiceSet, pdfs: [String: Data]) {
        await auth.configure(nip: nip, token: token)

        let report: @Sendable (FetchProgress) -> Void = { [weak self] value in
            Task { @MainActor in self?.progress = value }
        }

        // Krok 1 i 2: metadane faktur wystawionych i otrzymanych.
        let issuedMetadata = try await client.fetchAllMetadata(
            period: period, subjectType: .subject1, dateType: dateType, onProgress: report
        )
        try Task.checkCancellation()
        let receivedMetadata = try await client.fetchAllMetadata(
            period: period, subjectType: .subject2, dateType: dateType, onProgress: report
        )
        try Task.checkCancellation()

        var set = InvoiceSet(period: period, nip: nip)
        let total = issuedMetadata.count + receivedMetadata.count

        // Krok 3: wybór ścieżki pobierania treści faktur.
        let strategy = await client.chooseStrategy(invoiceCount: total)
        set.strategy = strategy

        if strategy == .single, total > 0 {
            let estimate = await client.estimatedSingleDownloadDuration(invoiceCount: total)
            if estimate > 60 {
                let minutes = Int((estimate / 60).rounded(.up))
                await MainActor.run {
                    self.infoMessage = "Pobieranie \(total) faktur potrwa około \(minutes) min "
                        + "z powodu limitów API KSeF (64 pobrania na godzinę)."
                }
            }
        }

        var xmlByKsefNumber: [String: Data] = [:]

        switch strategy {
        case .export:
            await MainActor.run {
                self.infoMessage = "Liczba faktur przekracza limit pojedynczego pobierania — "
                    + "aplikacja użyła eksportu paczki faktur."
            }
            let issuedExport = try await client.exportInvoices(
                period: period, subjectType: .subject1, dateType: dateType, onProgress: report
            )
            try Task.checkCancellation()
            let receivedExport = try await client.exportInvoices(
                period: period, subjectType: .subject2, dateType: dateType, onProgress: report
            )
            xmlByKsefNumber = issuedExport.merging(receivedExport) { current, _ in current }

        case .single:
            var downloaded = 0
            for metadata in issuedMetadata + receivedMetadata {
                try Task.checkCancellation()
                report(FetchProgress(stage: "Pobieranie faktur",
                                     current: downloaded, total: total,
                                     detail: metadata.invoiceNumber))
                do {
                    xmlByKsefNumber[metadata.ksefNumber] = try await client.downloadInvoiceXML(
                        ksefNumber: metadata.ksefNumber
                    )
                } catch let error as KsefError {
                    // Pojedyncza nieudana faktura nie przerywa całego miesiąca.
                    set.warnings.append("Nie udało się pobrać faktury \(metadata.ksefNumber): "
                        + (error.errorDescription ?? "nieznany błąd"))
                    logWarn("Pominięto fakturę \(metadata.ksefNumber).")
                }
                downloaded += 1
            }
        }

        // Krok 4: parsowanie i generowanie PDF poza wątkiem interfejsu.
        var parsed = 0
        let parsedTotal = xmlByKsefNumber.count
        var pdfs: [String: Data] = [:]

        for (metadata, direction) in issuedMetadata.map({ ($0, InvoiceDirection.issued) })
            + receivedMetadata.map({ ($0, InvoiceDirection.received) }) {
            try Task.checkCancellation()
            guard let xml = xmlByKsefNumber[metadata.ksefNumber] else { continue }

            report(FetchProgress(stage: "Przetwarzanie faktur",
                                 current: parsed, total: parsedTotal,
                                 detail: metadata.invoiceNumber))

            let outcome = await Task.detached(priority: .userInitiated) { () -> (Invoice, Data)? in
                guard let invoice = try? InvoiceParser.parse(xml: xml,
                                                             ksefNumber: metadata.ksefNumber,
                                                             direction: direction,
                                                             metadata: metadata) else { return nil }
                return (invoice, PdfRenderer.render(invoice))
            }.value

            guard let (invoice, pdf) = outcome else {
                set.warnings.append("Nie udało się odczytać faktury \(metadata.ksefNumber) — "
                    + "oryginalny plik XML został zachowany.")
                parsed += 1
                continue
            }

            if direction == .issued { set.issued.append(invoice) } else { set.received.append(invoice) }
            pdfs[invoice.ksefNumber] = pdf
            parsed += 1
        }

        set.fetchedAt = Date()
        logInfo("Zakończono pobieranie: \(set.issued.count) wystawionych, \(set.received.count) otrzymanych.")
        return (set, pdfs)
    }

    /// Nazwa firmy z pierwszej faktury wystawionej — trafia do tematu wiadomości.
    private func updateCompanyName() {
        guard let name = invoiceSet?.issued.first?.seller.name
            ?? invoiceSet?.received.first?.buyer.name, !name.isEmpty else { return }
        settings.companyName = name
    }

    // MARK: - Pliki wyników

    /// Zapisuje komplet plików miesiąca we własnej pamięci aplikacji.
    ///
    /// Użytkownik nie wybiera katalogu — pobrane faktury zostają w magazynie aplikacji
    /// i są dostępne po ponownym uruchomieniu bez łączenia się z KSeF. Katalog można
    /// otworzyć w Finderze, gdyby pliki były potrzebne gdzie indziej.
    @discardableResult
    func materializeOutputs() -> Storage.OutputLayout? {
        guard let set = invoiceSet else { return nil }
        guard let container = Storage.cacheDirectory(forNip: set.nip, period: set.period) else {
            showError("Nie udało się przygotować magazynu aplikacji.")
            return nil
        }
        do {
            let layout = try writeOutput(set: set, to: container)
            lastOutputDirectory = layout.root
            return layout
        } catch {
            showError("Nie udało się zapisać plików w pamięci aplikacji.", details: describe(error))
            return nil
        }
    }

    @discardableResult
    func writeOutput(set: InvoiceSet, to directory: URL) throws -> Storage.OutputLayout {
        let layout = try Storage.prepareOutput(in: directory, period: set.period)

        for invoice in set.all {
            if let pdf = pdfs[invoice.ksefNumber] {
                let target = Storage.directory(for: invoice.direction, in: layout)
                    .appendingPathComponent(Storage.pdfFileName(for: invoice, period: set.period))
                try Storage.writeAtomically(pdf, to: target)
            }
            // Oryginalny XML zapisujemy zawsze — to on jest dokumentem źródłowym.
            let xmlTarget = layout.xml.appendingPathComponent(Storage.xmlFileName(for: invoice))
            try Storage.writeAtomically(invoice.rawXML, to: xmlTarget)
        }

        let html = HtmlReport.document(for: set, companyName: settings.companyName)
        try Storage.writeAtomically(Data(html.utf8), to: layout.summaryHTML)
        return layout
    }

    // MARK: - Wiadomość e-mail

    /// Przygotowuje wiadomość i otwiera ją w kliencie pocztowym. Wysyłka należy do użytkownika.
    func generateEmail(attachmentMode: MailComposer.AttachmentMode = .individual) {
        guard let set = invoiceSet else { return }

        // Pliki muszą istnieć na dysku, żeby dało się je dołączyć także przez Mail.app.
        guard let container = Storage.cacheDirectory(forNip: set.nip, period: set.period) else {
            showError("Nie udało się przygotować magazynu aplikacji.")
            return
        }

        do {
            let layout = try writeOutput(set: set, to: container)
            lastOutputDirectory = layout.root

            let recipient = settings.recipientEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            let subject = MailComposer.subject(for: set, companyName: settings.companyName)
            let html = HtmlReport.body(for: set, companyName: settings.companyName)
            let plain = HtmlReport.plainText(for: set, companyName: settings.companyName)

            var attachments = MailComposer.attachments(for: set) { pdfs[$0.ksefNumber] }
            var body = html

            switch attachmentMode {
            case .individual:
                break
            case .archive:
                let archive = ZipArchive.makeStoredArchive(
                    files: attachments.map { (name: $0.fileName, data: $0.data) }
                )
                let archiveName = "faktury_\(set.period.tag).zip"
                try Storage.writeAtomically(archive, to: layout.root.appendingPathComponent(archiveName))
                attachments = [MailComposer.Attachment(fileName: archiveName,
                                                       mimeType: "application/zip",
                                                       data: archive)]
            case .none:
                attachments = []
                body += "<p>Pliki PDF znajdują się w katalogu: "
                body += "<code>\(HtmlReport.escape(layout.root.path))</code></p>"
            }

            let eml = MailComposer.makeEML(subject: subject, html: body,
                                           plainText: plain, attachments: attachments,
                                           recipient: recipient)
            try Storage.writeAtomically(eml, to: layout.messageEML)

            let addressNote = recipient.isEmpty
                ? "Uzupełnij adresata i wyślij ją samodzielnie."
                : "Adresat: \(recipient) — wystarczy wysłać."

            switch settings.mailMethod {
            case .emlFile:
                MailComposer.openInDefaultClient(emlURL: layout.messageEML)
                infoMessage = "Wiadomość przygotowana (\(attachments.count) zał.). \(addressNote)"
            case .appleScriptMail:
                // Do wiadomości w Mail.app dołączamy pliki z dysku, a nie dane z pamięci.
                let searchPaths = [layout.issued, layout.received, layout.root]
                let urls = attachments.compactMap { attachment -> URL? in
                    searchPaths
                        .map { $0.appendingPathComponent(attachment.fileName) }
                        .first { FileManager.default.fileExists(atPath: $0.path) }
                }
                switch MailComposer.createMailAppDraft(subject: subject, htmlBody: body,
                                                       attachmentURLs: urls.isEmpty ? [layout.messageEML] : urls,
                                                       recipient: recipient) {
                case .success:
                    infoMessage = "Utworzono wiadomość roboczą w Mail.app. \(addressNote)"
                case let .failure(error):
                    showError("Nie udało się utworzyć wiadomości w Mail.app.", details: describe(error))
                }
            }
        } catch {
            showError("Nie udało się przygotować wiadomości.", details: describe(error))
        }
    }

    /// Czy załączniki przekraczają próg, przy którym pytamy o sposób dołączenia.
    func attachmentsExceedThreshold() -> (exceeds: Bool, megabytes: Int) {
        guard let set = invoiceSet else { return (false, 0) }
        let attachments = MailComposer.attachments(for: set) { pdfs[$0.ksefNumber] }
        let size = MailComposer.encodedSize(of: attachments)
        return (size > MailComposer.attachmentSizeWarningThreshold, size / (1024 * 1024))
    }

    // MARK: - Wybór miesiąca

    /// Lista miesięcy do wyboru: bieżący i trzy lata wstecz.
    let selectableMonths = MonthPeriod.selectableRange()

    /// Otwiera bieżący miesiąc zaraz po uruchomieniu aplikacji.
    ///
    /// Gdy miesiąc jest już w pamięci, faktury pojawiają się natychmiast, bez łączenia się
    /// z KSeF. Gdy nie ma go jeszcze w pamięci, widok pozostaje pusty z zachętą do pobrania —
    /// aplikacja nie odpytuje API bez decyzji użytkownika.
    func openInitialMonth() {
        refreshStoredPeriods()
        guard settings.isNipValid else { return }
        selectPeriod(.current())
    }

    /// Przełącza na wskazany miesiąc: wczytuje go z pamięci albo pokazuje pusty widok.
    func selectPeriod(_ period: MonthPeriod) {
        self.period = period
        errorMessage = nil
        errorDetails = nil
        selectedInvoice = nil
        step = .results

        guard settings.isNipValid,
              let cached = InvoiceCache.load(nip: settings.normalizedNip, period: period) else {
            invoiceSet = nil
            pdfs = [:]
            lastOutputDirectory = nil
            infoMessage = nil
            return
        }

        invoiceSet = cached.set
        pdfs = cached.pdfs
        infoMessage = nil
        materializeOutputs()
        updateCompanyName()
        logInfo("Otwarto z pamięci miesiąc \(period.tag) (\(cached.set.all.count) faktur).")
    }

    /// Odświeża zbiór miesięcy oznaczanych na liście jako pobrane.
    func refreshStoredPeriods() {
        guard settings.isNipValid else {
            storedPeriods = []
            return
        }
        storedPeriods = Set(InvoiceCache.availablePeriods(forNip: settings.normalizedNip))
    }

    /// Czy wskazany miesiąc jest już pobrany.
    func isStored(_ period: MonthPeriod) -> Bool {
        storedPeriods.contains(period)
    }

    // MARK: - Aktualizacje aplikacji

    /// Sprawdza, czy w repozytorium jest nowsze wydanie.
    ///
    /// Przy `automatic` zapytanie wykonywane jest najwyżej raz na dobę i nie zgłasza błędów
    /// — brak sieci przy starcie nie powinien niczego zakłócać.
    func checkForUpdates(automatic: Bool = false) {
        if automatic, !settings.shouldCheckForUpdates { return }

        if !automatic { updateStatus = "Sprawdzanie aktualizacji…" }
        Task {
            do {
                let release = try await updateChecker.checkForUpdate(currentVersion: AppInfo.version)
                settings.recordUpdateCheck()
                availableUpdate = release
                if let release {
                    updateStatus = "Dostępna nowa wersja \(release.version)."
                    logInfo("Dostępna aktualizacja: \(release.version).")
                } else if !automatic {
                    updateStatus = "Masz najnowszą wersję (\(AppInfo.version))."
                }
            } catch {
                guard !automatic else { return }
                updateStatus = describe(error)
            }
        }
    }

    /// Otwiera stronę wydania w przeglądarce.
    func openReleasePage() {
        guard let release = availableUpdate else { return }
        NSWorkspace.shared.open(release.pageURL)
    }

    /// Pobiera pakiet nowej wersji i zapisuje go w miejscu wskazanym przez użytkownika.
    ///
    /// Aplikacja nie podmienia się sama — działa w piaskownicy i nie ma prawa zapisu
    /// do `/Applications`. Instalacja polega na rozpakowaniu pobranego pliku
    /// i przeciągnięciu pakietu do katalogu programów.
    func downloadUpdate() {
        guard let release = availableUpdate else { return }
        guard let url = release.downloadURL else {
            openReleasePage()
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.title = "Zapisz aktualizację"
        panel.message = "Wskaż miejsce zapisu pakietu w wersji \(release.version)."
        guard panel.runModal() == .OK, let target = panel.url else { return }

        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let data = try await updateChecker.downloadPackage(from: url)
                try data.write(to: target, options: .atomic)
                updateStatus = "Pobrano wersję \(release.version). Rozpakuj plik i przeciągnij "
                    + "pakiet do katalogu Programy, zastępując poprzednią wersję."
                revealInFinder(target)
            } catch {
                updateStatus = describe(error)
            }
        }
    }

    // MARK: - Pomocnicze

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Zapisuje PDF faktury do pliku tymczasowego i pokazuje go w Finderze.
    func revealInvoicePDF(_ invoice: Invoice) {
        if let directory = lastOutputDirectory {
            let candidate = Storage
                .directory(for: invoice.direction,
                           in: Storage.OutputLayout(root: directory,
                                                    issued: directory.appendingPathComponent("wystawione"),
                                                    received: directory.appendingPathComponent("otrzymane"),
                                                    xml: directory.appendingPathComponent("xml")))
                .appendingPathComponent(Storage.pdfFileName(for: invoice, period: period))
            if FileManager.default.fileExists(atPath: candidate.path) {
                revealInFinder(candidate)
                return
            }
        }
        guard let data = pdfs[invoice.ksefNumber] else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(Storage.pdfFileName(for: invoice, period: period))
        try? data.write(to: url)
        revealInFinder(url)
    }

    func showError(_ message: String, details: String? = nil) {
        errorMessage = message
        errorDetails = details.map { Log.redact($0) }
        logError("\(message) \(details ?? "")")
    }

    /// Zamienia błąd na komunikat po polsku, z zachowaniem kodów KSeF i redakcją sekretów.
    private func describe(_ error: Error) -> String {
        if let ksefError = error as? KsefError {
            return Log.redact(ksefError.errorDescription ?? String(describing: error))
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return Log.redact(description)
        }
        return Log.redact(error.localizedDescription)
    }
}
