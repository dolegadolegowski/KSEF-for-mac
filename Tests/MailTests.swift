import Foundation

enum MailTests {
    private static func makeSet() throws -> InvoiceSet {
        var set = InvoiceSet(period: MonthPeriod(year: 2026, month: 7), nip: "5260250274")
        set.issued = [
            try InvoiceParser.parse(xml: Data(Fixtures.fa3Standard.utf8),
                                    ksefNumber: "5260250274-20260715-01ABCDEF-01", direction: .issued),
            try InvoiceParser.parse(xml: Data(Fixtures.fa3Correction.utf8),
                                    ksefNumber: "5260250274-20260728-0BADC0DE-01", direction: .issued),
            try InvoiceParser.parse(xml: Data(Fixtures.fa3ForeignCurrency.utf8),
                                    ksefNumber: "5260250274-20260720-0EUR0001-01", direction: .issued),
        ]
        set.received = [
            try InvoiceParser.parse(xml: Data(Fixtures.fa2Standard.utf8),
                                    ksefNumber: "7010001453-20240311-0ARCH0001-01", direction: .received),
        ]
        return set
    }

    static func run() {
        T.suite("Podsumowania kwot") {
            T.test("sumuje osobno każdą walutę") {
                let set = try makeSet()
                let totals = Totals.byCurrency(set.issued)

                T.equal(totals.count, 2, "liczba walut wśród faktur wystawionych")
                T.equal(totals[0].currency, "PLN", "PLN musi być pierwsza")

                // 1500,00 (faktura) + (−200,00) (korekta) = 1300,00
                T.equal(totals[0].net, Decimal(string: "1300.00"), "netto w PLN z uwzględnieniem korekty")
                T.equal(totals[0].vat, Decimal(string: "224.00"), "VAT w PLN (270 − 46)")
                T.equal(totals[0].gross, Decimal(string: "1524.00"), "brutto w PLN (1770 − 246)")
                T.equal(totals[0].count, 2, "liczba faktur w PLN")

                T.equal(totals[1].currency, "EUR", "druga waluta")
                T.equal(totals[1].gross, Decimal(string: "1230.00"), "brutto w EUR nie może mieszać się z PLN")
            }

            T.test("liczy saldo sprzedaży i zakupów per waluta") {
                let set = try makeSet()
                let balance = Totals.balance(issued: set.issued, received: set.received)

                let pln = balance.first { $0.currency == "PLN" }
                T.notNil(pln, "saldo w PLN")
                // Sprzedaż 1300,00 netto minus zakupy 2000,00 netto = −700,00
                T.equal(pln?.net, Decimal(string: "-700.00"), "saldo netto w PLN")
                T.equal(pln?.gross, Decimal(string: "-936.00"), "saldo brutto w PLN (1524 − 2460)")

                let eur = balance.first { $0.currency == "EUR" }
                T.equal(eur?.gross, Decimal(string: "1230.00"), "saldo brutto w EUR")
            }
        }

        T.suite("Raport HTML") {
            T.test("zawiera obie tabele, sumy i podsumowanie zbiorcze") {
                let set = try makeSet()
                let html = HtmlReport.body(for: set, companyName: "Przykładowa Spółka z o.o.")

                for fragment in ["Faktury wystawione", "Faktury otrzymane", "Podsumowanie zbiorcze",
                                 "Odbiorca", "Wystawiający", "Netto", "Brutto",
                                 "Sprzedaż (faktury wystawione)", "Zakupy (faktury otrzymane)",
                                 "Różnica (sprzedaż − zakupy)"] {
                    T.expect(html.contains(fragment), "raport musi zawierać „\(fragment)")
                }

                T.expect(html.contains("526-025-02-74"), "raport musi zawierać NIP podmiotu")
                T.expect(html.contains("lipiec 2026"), "raport musi nazywać okres")
                T.expect(html.contains("(korekta)"), "korekty muszą być wyraźnie oznaczone")
                T.expect(html.contains("wizualizacjami faktur ustrukturyzowanych"),
                         "stopka musi wyjaśniać charakter załączników")
                T.expect(html.contains(AppInfo.version), "stopka musi podawać wersję aplikacji")

                // Kwoty w formacie „1 234,56 zł" — spacja nierozdzielająca jako encja HTML.
                T.expect(html.contains("1&nbsp;770,00&nbsp;zł"), "kwota w formacie polskim")
                T.expect(html.contains("EUR"), "waluta obca prezentowana osobno")
            }

            T.test("zabezpiecza znaki o znaczeniu składniowym") {
                T.equal(HtmlReport.escape("Firma <A> & \"B\""),
                        "Firma &lt;A&gt; &amp; &quot;B&quot;", "znaki specjalne zamienione na encje")

                var set = try makeSet()
                set.issued[0].buyer.name = "Nabywca <script>alert(1)</script>"
                let html = HtmlReport.body(for: set, companyName: "Firma & Syn")
                T.expect(!html.contains("<script>"), "treść z danych nie może trafić do HTML jako znaczniki")
                T.expect(html.contains("Firma &amp; Syn"), "nazwa firmy musi być zabezpieczona")
            }

            T.test("buduje wersję tekstową wiadomości") {
                let set = try makeSet()
                let text = HtmlReport.plainText(for: set, companyName: "Przykładowa Spółka z o.o.")

                T.expect(text.contains("Faktury wystawione"), "wersja tekstowa musi mieć tabelę wystawionych")
                T.expect(text.contains("Faktury otrzymane"), "wersja tekstowa musi mieć tabelę otrzymanych")
                T.expect(text.contains("FV/123/2026"), "wersja tekstowa musi wymieniać faktury")
                T.expect(!text.contains("<"), "wersja tekstowa nie może zawierać znaczników HTML")
            }
        }

        T.suite("Wiadomość .eml") {
            T.test("buduje poprawną strukturę MIME") {
                let set = try makeSet()
                let subject = MailComposer.subject(for: set, companyName: "Przykładowa Spółka z o.o.")
                let attachments = [
                    MailComposer.Attachment(fileName: "WYSTAWIONE_2026-07_FV-123-2026.pdf",
                                            mimeType: "application/pdf",
                                            data: Data("PDF-UDAJEMY-1".utf8)),
                    MailComposer.Attachment(fileName: "OTRZYMANE_2026-07_FA-2024.pdf",
                                            mimeType: "application/pdf",
                                            data: Data("PDF-UDAJEMY-2".utf8)),
                ]

                let eml = MailComposer.makeEML(
                    subject: subject,
                    html: HtmlReport.body(for: set, companyName: "Przykładowa Spółka z o.o."),
                    plainText: HtmlReport.plainText(for: set, companyName: "Przykładowa Spółka z o.o."),
                    attachments: attachments
                )
                guard let message = String(data: eml, encoding: .utf8) else {
                    T.fail("wiadomość nie jest poprawnym tekstem UTF-8")
                    return
                }

                T.expect(message.hasPrefix("MIME-Version: 1.0\r\n"), "wiadomość musi zaczynać się nagłówkiem MIME")
                T.expect(message.contains("Content-Type: multipart/mixed;"), "koperta multipart/mixed")
                T.expect(message.contains("Content-Type: multipart/alternative;"), "część alternatywna")
                T.expect(message.contains("Content-Type: text/plain; charset=UTF-8"), "część tekstowa")
                T.expect(message.contains("Content-Type: text/html; charset=UTF-8"), "część HTML")
                T.expect(message.contains("Content-Disposition: attachment; filename=\"WYSTAWIONE_2026-07_FV-123-2026.pdf\""),
                         "załącznik z nazwą pliku")
                T.expect(message.contains("Content-Transfer-Encoding: base64"), "kodowanie załączników")
                T.expect(message.contains("Date: "), "nagłówek daty")

                // Nagłówki wierszy muszą być zakończone CRLF zgodnie z RFC 5322.
                let headerSection = message.components(separatedBy: "\r\n\r\n").first ?? ""
                T.expect(headerSection.contains("Subject: "), "nagłówek tematu")
                T.expect(!headerSection.contains("\n\n"), "nagłówki muszą używać CRLF")

                // Granice muszą być domknięte.
                if let boundary = message.range(of: "boundary=\"")
                    .map({ String(message[$0.upperBound...].prefix(while: { $0 != "\"" })) }) {
                    T.expect(message.contains("--\(boundary)--"), "granica multipart musi zostać zamknięta")
                } else {
                    T.fail("nie znaleziono granicy multipart")
                }
            }

            T.test("zachowuje integralność załączników po zakodowaniu Base64") {
                // Dane binarne z pełnym zakresem bajtów — najostrzejszy test kodowania.
                let payload = Data((0 ... 255).map { UInt8($0) } + Array(repeating: UInt8(0xAB), count: 5000))
                let attachment = MailComposer.Attachment(fileName: "faktura.pdf",
                                                         mimeType: "application/pdf",
                                                         data: payload)
                let eml = MailComposer.makeEML(subject: "Test", html: "<p>a</p>", plainText: "a",
                                               attachments: [attachment])
                let message = String(data: eml, encoding: .utf8)!

                // Wyodrębniamy blok Base64 następujący po nagłówkach załącznika.
                guard let dispositionRange = message.range(of: "Content-Disposition: attachment"),
                      let bodyStart = message.range(of: "\r\n\r\n", range: dispositionRange.upperBound ..< message.endIndex)
                else {
                    T.fail("nie znaleziono treści załącznika")
                    return
                }
                let remainder = message[bodyStart.upperBound...]
                let block = remainder.components(separatedBy: "\r\n\r\n").first ?? ""
                let encoded = block.replacingOccurrences(of: "\r\n", with: "")

                guard let decoded = Data(base64Encoded: encoded) else {
                    T.fail("treść załącznika nie jest poprawnym Base64")
                    return
                }
                T.equal(decoded, payload, "odkodowany załącznik musi być identyczny z oryginałem")

                // Wiersze Base64 nie mogą przekraczać 76 znaków (RFC 2045).
                let tooLong = block.components(separatedBy: "\r\n").contains { $0.count > 76 }
                T.expect(!tooLong, "wiersze Base64 nie mogą przekraczać 76 znaków")
            }

            T.test("koduje temat z polskimi znakami zgodnie z RFC 2047") {
                let set = try makeSet()
                let subject = MailComposer.subject(for: set, companyName: "Przykładowa Spółka z o.o.")
                T.equal(subject, "Faktury KSeF — lipiec 2026 — Przykładowa Spółka z o.o. (526-025-02-74)",
                        "temat wiadomości")

                let encoded = MailComposer.encodeHeader(subject)
                T.expect(encoded.hasPrefix("=?UTF-8?B?"), "temat spoza ASCII musi być zakodowany")
                T.expect(encoded.hasSuffix("?="), "zakodowany nagłówek musi być domknięty")

                // Odkodowanie musi odtworzyć oryginalny temat.
                let base64 = encoded
                    .replacingOccurrences(of: "=?UTF-8?B?", with: "")
                    .replacingOccurrences(of: "?=", with: "")
                T.equal(Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf8) },
                        subject, "odkodowany temat")

                T.equal(MailComposer.encodeHeader("Simple ASCII"), "Simple ASCII",
                        "temat ASCII pozostaje bez zmian")
            }

            T.test("formatuje datę zgodnie z RFC 5322") {
                let date = InvoiceParser.parseDate("2026-08-09")!
                let formatted = MailComposer.rfc5322Date(date)
                T.expect(formatted.contains("Aug 2026"), "data musi zawierać miesiąc i rok (otrzymano \(formatted))")
                T.expect(formatted.contains("+0200") || formatted.contains("+0100"),
                         "data musi zawierać przesunięcie strefy (otrzymano \(formatted))")
            }

            T.test("szacuje rozmiar załączników po zakodowaniu") {
                let attachments = [
                    MailComposer.Attachment(fileName: "a.pdf", mimeType: "application/pdf",
                                            data: Data(repeating: 0, count: 3_000_000)),
                    MailComposer.Attachment(fileName: "b.pdf", mimeType: "application/pdf",
                                            data: Data(repeating: 0, count: 3_000_000)),
                ]
                T.equal(MailComposer.rawSize(of: attachments), 6_000_000, "rozmiar surowy")

                // Base64 koduje każde 3 bajty na 4 znaki: 6 000 000 → 8 000 000.
                let encoded = MailComposer.encodedSize(of: attachments)
                T.equal(encoded, 8_000_000, "rozmiar po zakodowaniu Base64")
                T.expect(encoded < MailComposer.attachmentSizeWarningThreshold,
                         "6 MB nie może przekraczać progu ostrzeżenia")
            }

            T.test("nadaje unikalne nazwy załącznikom") {
                var set = InvoiceSet(period: MonthPeriod(year: 2026, month: 7), nip: "5260250274")
                let invoice = try InvoiceParser.parse(xml: Data(Fixtures.fa3Standard.utf8),
                                                      ksefNumber: "A-1", direction: .issued)
                // Dwie faktury o identycznych danych dałyby tę samą nazwę pliku.
                var duplicate = invoice
                duplicate.ksefNumber = "A-2"
                set.issued = [invoice, duplicate]

                let attachments = MailComposer.attachments(for: set) { _ in Data("pdf".utf8) }
                T.equal(attachments.count, 2, "liczba załączników")
                T.expect(attachments[0].fileName != attachments[1].fileName,
                         "nazwy załączników muszą być unikalne")
                T.expect(attachments[1].fileName.contains("_2.pdf"), "powtórzona nazwa dostaje przyrostek")
            }
        }
    }
}
