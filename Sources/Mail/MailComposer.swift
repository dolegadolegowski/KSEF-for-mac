import AppKit
import Foundation

/// Tworzy gotową do wysłania wiadomość z podsumowaniem miesiąca i fakturami w załącznikach.
///
/// Wiadomość nigdy nie jest wysyłana automatycznie — aplikacja jedynie przygotowuje ją
/// w kliencie pocztowym, a decyzję o wysyłce podejmuje użytkownik.
enum MailComposer {
    /// Próg, powyżej którego pytamy użytkownika o sposób dołączenia plików.
    static let attachmentSizeWarningThreshold = 20 * 1024 * 1024

    struct Attachment {
        let fileName: String
        let mimeType: String
        let data: Data
    }

    /// Sposób dołączenia załączników wybrany przez użytkownika.
    enum AttachmentMode {
        /// Wszystkie pliki PDF osobno, mimo przekroczenia progu rozmiaru.
        case individual
        /// Jedno archiwum ZIP ze wszystkimi plikami.
        case archive
        /// Bez załączników — z odnośnikiem do katalogu z plikami.
        case none
    }

    // MARK: - Temat i treść

    /// „Faktury KSeF — lipiec 2026 — Przykładowa Spółka (526-025-02-74)”
    static func subject(for set: InvoiceSet, companyName: String) -> String {
        let company = companyName.isEmpty ? "brak nazwy" : companyName
        return "Faktury KSeF — \(set.period.displayName) — \(company) (\(Nip.formatted(set.nip)))"
    }

    /// Zbiera pliki PDF wskazanych faktur jako załączniki.
    static func attachments(for set: InvoiceSet, pdfProvider: (Invoice) -> Data?) -> [Attachment] {
        var result: [Attachment] = []
        var usedNames = Set<String>()

        for invoice in set.issued + set.received {
            guard let data = pdfProvider(invoice) else { continue }
            var name = Storage.pdfFileName(for: invoice, period: set.period)
            // Nazwy muszą być unikalne w obrębie wiadomości, nawet gdyby dwie faktury
            // dały ten sam wzorzec nazwy.
            var suffix = 2
            while usedNames.contains(name) {
                let base = name.replacingOccurrences(of: ".pdf", with: "")
                name = "\(base)_\(suffix).pdf"
                suffix += 1
            }
            usedNames.insert(name)
            result.append(Attachment(fileName: name, mimeType: "application/pdf", data: data))
        }
        return result
    }

    /// Łączny rozmiar załączników po zakodowaniu Base64 (narzut około jednej trzeciej).
    static func encodedSize(of attachments: [Attachment]) -> Int {
        attachments.reduce(0) { $0 + ($1.data.count + 2) / 3 * 4 }
    }

    static func rawSize(of attachments: [Attachment]) -> Int {
        attachments.reduce(0) { $0 + $1.data.count }
    }

    // MARK: - Budowa pliku .eml

    /// Buduje wiadomość zgodną z RFC 5322: `multipart/mixed` z częścią `multipart/alternative`
    /// (`text/plain` + `text/html`) oraz załącznikami zakodowanymi Base64.
    ///
    /// Gdy w ustawieniach podano adres odbiorcy, trafia on do nagłówka `To` — wtedy gotową
    /// wiadomość wystarczy otworzyć i wysłać. Bez adresu nagłówek pozostaje pusty.
    static func makeEML(subject: String,
                        html: String,
                        plainText: String,
                        attachments: [Attachment],
                        recipient: String = "",
                        date: Date = Date()) -> Data {
        let mixedBoundary = "ksef-mixed-\(UUID().uuidString)"
        let alternativeBoundary = "ksef-alt-\(UUID().uuidString)"

        var message = ""
        message += "MIME-Version: 1.0\r\n"
        message += "Date: \(rfc5322Date(date))\r\n"
        message += "Subject: \(encodeHeader(subject))\r\n"
        message += "To: \(recipient.trimmingCharacters(in: .whitespacesAndNewlines))\r\n"
        // Nagłówek honorowany przez część klientów — otwiera wiadomość jako roboczą.
        message += "X-Unsent: 1\r\n"
        message += "X-Mailer: \(AppInfo.displayVersion)\r\n"
        message += "Content-Type: multipart/mixed; boundary=\"\(mixedBoundary)\"\r\n"
        message += "\r\n"
        message += "Ta wiadomość ma format MIME.\r\n"

        message += "--\(mixedBoundary)\r\n"
        message += "Content-Type: multipart/alternative; boundary=\"\(alternativeBoundary)\"\r\n\r\n"

        message += "--\(alternativeBoundary)\r\n"
        message += "Content-Type: text/plain; charset=UTF-8\r\n"
        message += "Content-Transfer-Encoding: base64\r\n\r\n"
        message += base64Block(Data(plainText.utf8))

        message += "--\(alternativeBoundary)\r\n"
        message += "Content-Type: text/html; charset=UTF-8\r\n"
        message += "Content-Transfer-Encoding: base64\r\n\r\n"
        message += base64Block(Data(html.utf8))

        message += "--\(alternativeBoundary)--\r\n"

        for attachment in attachments {
            message += "--\(mixedBoundary)\r\n"
            message += "Content-Type: \(attachment.mimeType); name=\"\(encodeHeader(attachment.fileName))\"\r\n"
            message += "Content-Transfer-Encoding: base64\r\n"
            message += "Content-Disposition: attachment; filename=\"\(encodeHeader(attachment.fileName))\"\r\n\r\n"
            message += base64Block(attachment.data)
        }

        message += "--\(mixedBoundary)--\r\n"
        return Data(message.utf8)
    }

    /// Koduje Base64 i łamie wiersze co 76 znaków, jak wymaga RFC 2045.
    private static func base64Block(_ data: Data) -> String {
        let encoded = data.base64EncodedString(options: [
            .lineLength76Characters,
            .endLineWithCarriageReturn,
            .endLineWithLineFeed,
        ])
        return encoded + "\r\n\r\n"
    }

    /// Koduje nagłówek zgodnie z RFC 2047, gdy zawiera znaki spoza ASCII.
    static func encodeHeader(_ text: String) -> String {
        if text.allSatisfy({ $0.isASCII }) { return text }
        let encoded = Data(text.utf8).base64EncodedString()
        return "=?UTF-8?B?\(encoded)?="
    }

    /// Data w formacie wymaganym przez RFC 5322, np. „Sun, 09 Aug 2026 20:26:00 +0200”.
    static func rfc5322Date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Fmt.warsaw
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    // MARK: - Przekazanie do klienta pocztowego

    /// Zapisuje wiadomość na dysk i otwiera ją w domyślnym kliencie pocztowym.
    @MainActor
    static func openInDefaultClient(emlURL: URL) {
        NSWorkspace.shared.open(emlURL)
        logInfo("Otwarto przygotowaną wiadomość w domyślnym kliencie pocztowym.")
    }

    /// Tworzy wiadomość roboczą w Mail.app przez AppleScript.
    ///
    /// Wariant alternatywny wobec pliku `.eml`: część klientów otwiera `.eml` w trybie
    /// podglądu zamiast edycji, a ta ścieżka od razu daje wiadomość gotową do uzupełnienia.
    /// Wiadomość jest jedynie wyświetlana — wysyłkę wykonuje użytkownik.
    @discardableResult
    static func createMailAppDraft(subject: String,
                                   htmlBody: String,
                                   attachmentURLs: [URL],
                                   recipient: String = "") -> Result<Void, Error> {
        let attachmentCommands = attachmentURLs.map { url in
            """
                    make new attachment with properties {file name:(POSIX file "\(escapeAppleScript(url.path))")} \
            at after the last paragraph
            """
        }.joined(separator: "\n")

        // Adresat trafia do wiadomości od razu, żeby wystarczyło kliknąć „Wyślij".
        let address = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        let recipientCommand = address.isEmpty ? "" : """
                make new to recipient at end of to recipients with properties \
        {address:"\(escapeAppleScript(address))"}
        """

        let script = """
        tell application "Mail"
            set newMessage to make new outgoing message with properties \
        {subject:"\(escapeAppleScript(subject))", content:"\(escapeAppleScript(plainIntro(htmlBody)))", visible:true}
            tell newMessage
        \(recipientCommand)
        \(attachmentCommands)
            end tell
            activate
        end tell
        """

        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            return .failure(KsefError.network("Nie udało się przygotować skryptu dla Mail.app."))
        }
        appleScript.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "nieznany błąd"
            logWarn("AppleScript dla Mail.app zakończył się błędem: \(message)")
            return .failure(KsefError.network("Mail.app zgłosił błąd: \(message)"))
        }
        logInfo("Utworzono wiadomość roboczą w Mail.app.")
        return .success(())
    }

    /// Treść przekazywana do Mail.app jako tekst — AppleScript nie przyjmuje HTML w polu `content`.
    private static func plainIntro(_ html: String) -> String {
        html
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "</p>", with: "\n\n")
            .replacingOccurrences(of: "</div>", with: "\n")
            .replacingOccurrences(of: "</tr>", with: "\n")
            .replacingOccurrences(of: "</td>", with: "\t")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: "\u{00A0}")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    private static func escapeAppleScript(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
