import Foundation

/// Typ daty, według której filtrowane są faktury w zapytaniu o metadane.
///
/// Wybór ma bezpośredni skutek księgowy: `issue` daje miesiąc według daty wystawienia,
/// `permanentStorage` — według daty trwałego zapisu w KSeF (kryterium przyrostowego pobierania).
enum InvoiceDateType: String, Codable, CaseIterable, Identifiable {
    case issue = "Issue"
    case invoicing = "Invoicing"
    case permanentStorage = "PermanentStorage"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .issue: return "Data wystawienia"
        case .invoicing: return "Data przyjęcia w KSeF"
        case .permanentStorage: return "Data trwałego zapisu w KSeF"
        }
    }

    var explanation: String {
        switch self {
        case .issue:
            return "Faktura trafia do miesiąca zgodnie z datą wystawienia (pole P_1). "
                + "To najczęstsze kryterium księgowe."
        case .invoicing:
            return "Faktura trafia do miesiąca zgodnie z datą przyjęcia dokumentu przez KSeF "
                + "do dalszego przetwarzania."
        case .permanentStorage:
            return "Faktura trafia do miesiąca zgodnie z datą trwałego zapisu w repozytorium KSeF. "
                + "Ten tryb gwarantuje kompletność przy pobieraniu przyrostowym, ale faktura "
                + "wystawiona pod koniec miesiąca może trafić do miesiąca następnego."
        }
    }
}

/// Sposób przekazania gotowej wiadomości do klienta pocztowego.
enum MailDeliveryMethod: String, Codable, CaseIterable, Identifiable {
    case emlFile = "eml"
    case appleScriptMail = "mailapp"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .emlFile: return "Plik .eml (domyślny klient pocztowy)"
        case .appleScriptMail: return "Wiadomość robocza w Mail.app (AppleScript)"
        }
    }
}

/// Ustawienia aplikacji. Token KSeF celowo nie występuje w tym typie — mieszka wyłącznie w Keychain.
///
/// Typ żyje na głównym aktorze, bo jest źródłem prawdy dla widoków SwiftUI.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        static let nip = "ksef.nip"
        static let dateType = "ksef.dateType"
        static let mailMethod = "ksef.mailMethod"
        static let companyName = "ksef.companyName"
        static let recipientEmail = "ksef.recipientEmail"
        static let lastUpdateCheck = "ksef.lastUpdateCheck"
        static let automaticUpdateCheck = "ksef.automaticUpdateCheck"
    }

    private let defaults: UserDefaults

    @Published var nip: String {
        didSet { defaults.set(nip, forKey: Key.nip) }
    }

    @Published var dateType: InvoiceDateType {
        didSet { defaults.set(dateType.rawValue, forKey: Key.dateType) }
    }

    @Published var mailMethod: MailDeliveryMethod {
        didSet { defaults.set(mailMethod.rawValue, forKey: Key.mailMethod) }
    }

    /// Nazwa firmy używana w temacie e-maila; uzupełniana automatycznie z pierwszej faktury wystawionej.
    @Published var companyName: String {
        didSet { defaults.set(companyName, forKey: Key.companyName) }
    }

    /// Stały adresat zestawienia — zwykle biuro rachunkowe. Trafia do nagłówka `To`,
    /// dzięki czemu gotową wiadomość wystarczy otworzyć i wysłać.
    @Published var recipientEmail: String {
        didSet { defaults.set(recipientEmail, forKey: Key.recipientEmail) }
    }

    @Published var automaticUpdateCheck: Bool {
        didSet { defaults.set(automaticUpdateCheck, forKey: Key.automaticUpdateCheck) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        nip = defaults.string(forKey: Key.nip) ?? ""
        dateType = InvoiceDateType(rawValue: defaults.string(forKey: Key.dateType) ?? "") ?? .issue
        mailMethod = MailDeliveryMethod(rawValue: defaults.string(forKey: Key.mailMethod) ?? "") ?? .emlFile
        companyName = defaults.string(forKey: Key.companyName) ?? ""
        recipientEmail = defaults.string(forKey: Key.recipientEmail) ?? ""
        automaticUpdateCheck = defaults.object(forKey: Key.automaticUpdateCheck) as? Bool ?? true
    }

    /// Prosta weryfikacja adresu — sprawdza kształt, nie istnienie skrzynki.
    var isRecipientEmailValid: Bool {
        AppSettings.isValidEmail(recipientEmail)
    }

    /// Funkcja czysta — nie dotyka stanu ustawień, więc może być wywoływana z dowolnego wątku.
    nonisolated static func isValidEmail(_ address: String) -> Bool {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return false }
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = parts[1]
        guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix(".") else { return false }
        return true
    }

    // MARK: - Sprawdzanie aktualizacji

    /// Aktualizacje sprawdzamy automatycznie najwyżej raz na dobę, żeby nie zaczepiać
    /// serwisu GitHub przy każdym uruchomieniu.
    var shouldCheckForUpdates: Bool {
        guard automaticUpdateCheck else { return false }
        guard let last = defaults.object(forKey: Key.lastUpdateCheck) as? Date else { return true }
        return Date().timeIntervalSince(last) > 24 * 3600
    }

    func recordUpdateCheck(at date: Date = Date()) {
        defaults.set(date, forKey: Key.lastUpdateCheck)
    }

    var isNipValid: Bool { Nip.isValid(nip) }

    var normalizedNip: String { Nip.normalize(nip) }

}
