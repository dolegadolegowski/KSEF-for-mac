import Foundation

/// Buduje podsumowanie miesiąca w HTML — używane zarówno jako `podsumowanie.html`
/// w katalogu wyników, jak i jako treść wiadomości e-mail.
///
/// Style są wpisane bezpośrednio w znaczniki, żeby treść zachowała wygląd także
/// po skopiowaniu do edytora tekstu.
enum HtmlReport {
    private enum Style {
        static let table = "border-collapse:collapse;width:100%;font-family:-apple-system,Segoe UI,Arial,sans-serif;font-size:12px;margin:8px 0 18px 0;"
        static let th = "border:1px solid #c8c8c8;background:#f0f0f0;padding:6px 8px;text-align:left;font-weight:600;"
        static let thRight = "border:1px solid #c8c8c8;background:#f0f0f0;padding:6px 8px;text-align:right;font-weight:600;"
        static let td = "border:1px solid #d8d8d8;padding:5px 8px;text-align:left;"
        static let tdRight = "border:1px solid #d8d8d8;padding:5px 8px;text-align:right;white-space:nowrap;"
        static let tdSum = "border:1px solid #c8c8c8;background:#f7f7f7;padding:6px 8px;text-align:right;font-weight:700;white-space:nowrap;"
        static let tdSumLabel = "border:1px solid #c8c8c8;background:#f7f7f7;padding:6px 8px;text-align:left;font-weight:700;"
        static let body = "font-family:-apple-system,Segoe UI,Arial,sans-serif;font-size:13px;color:#1a1a1a;line-height:1.5;"
        static let heading = "font-size:15px;font-weight:700;margin:20px 0 4px 0;"
        static let muted = "color:#666;font-size:11px;line-height:1.45;"
    }

    /// Zamienia znaki o znaczeniu składniowym w HTML na encje.
    static func escape(_ text: String) -> String {
        var out = text
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&#39;")
        return out
    }

    /// Kwota w treści HTML — spacja nierozdzielająca zapisana jako encja,
    /// żeby przetrwała kopiowanie i konwersję kodowania.
    private static func money(_ value: Decimal, currency: String) -> String {
        escape(Fmt.money(value, currency: currency))
            .replacingOccurrences(of: "\u{00A0}", with: "&nbsp;")
    }

    // MARK: - Dokument

    /// Pełny dokument HTML zapisywany jako `podsumowanie.html`.
    static func document(for set: InvoiceSet, companyName: String) -> String {
        """
        <!doctype html>
        <html lang="pl">
        <head>
        <meta charset="utf-8">
        <title>Faktury KSeF — \(escape(set.period.displayName))</title>
        </head>
        <body style="\(Style.body)">
        \(body(for: set, companyName: companyName))
        </body>
        </html>
        """
    }

    /// Fragment `<body>` — wstawiany bezpośrednio jako treść wiadomości e-mail.
    static func body(for set: InvoiceSet, companyName: String) -> String {
        var html = ""

        let company = companyName.isEmpty ? "—" : companyName
        html += "<p style=\"\(Style.body)\">"
        html += "Zestawienie faktur z Krajowego Systemu e-Faktur za <strong>\(escape(set.period.displayName))</strong>.<br>"
        html += "Podmiot: <strong>\(escape(company))</strong>, NIP \(escape(Nip.formatted(set.nip))).<br>"
        html += "Liczba faktur: <strong>\(set.issued.count + set.received.count)</strong> "
        html += "(wystawione: \(set.issued.count), otrzymane: \(set.received.count)).<br>"
        html += "Zestawienie wygenerowano \(escape(Fmt.dateTime(set.fetchedAt))).</p>"

        html += "<div style=\"\(Style.heading)\">Faktury wystawione</div>"
        html += table(
            invoices: set.issued,
            counterpartyHeader: "Odbiorca",
            counterpartyFirst: false,
            emptyMessage: "Brak faktur wystawionych w tym miesiącu."
        )

        html += "<div style=\"\(Style.heading)\">Faktury otrzymane</div>"
        html += table(
            invoices: set.received,
            counterpartyHeader: "Wystawiający",
            counterpartyFirst: true,
            emptyMessage: "Brak faktur otrzymanych w tym miesiącu."
        )

        html += summarySection(for: set)

        html += "<p style=\"\(Style.muted)\">"
        html += "Załączone pliki PDF są wizualizacjami faktur ustrukturyzowanych zapisanych w KSeF. "
        html += "Dokumentem źródłowym każdej faktury pozostaje jej plik XML w Krajowym Systemie e-Faktur.<br>"
        html += "Wygenerowano programem \(escape(AppInfo.displayVersion))."
        if !set.warnings.isEmpty {
            html += "<br>Uwagi: " + set.warnings.map { escape($0) }.joined(separator: " ")
        }
        html += "</p>"

        return html
    }

    // MARK: - Tabele

    /// Buduje tabelę faktur wraz z wierszami sum dla każdej waluty.
    ///
    /// Kolejność kolumn różni się dla faktur otrzymanych — kontrahent występuje przed numerem,
    /// zgodnie z układem uzgodnionym dla treści wiadomości.
    private static func table(invoices: [Invoice],
                              counterpartyHeader: String,
                              counterpartyFirst: Bool,
                              emptyMessage: String) -> String {
        guard !invoices.isEmpty else {
            return "<p style=\"\(Style.muted)\">\(escape(emptyMessage))</p>"
        }

        var html = "<table style=\"\(Style.table)\" cellspacing=\"0\"><thead><tr>"
        html += "<th style=\"\(Style.th)\">Data</th>"
        if counterpartyFirst {
            html += "<th style=\"\(Style.th)\">\(escape(counterpartyHeader))</th>"
            html += "<th style=\"\(Style.th)\">Numer</th>"
        } else {
            html += "<th style=\"\(Style.th)\">Numer</th>"
            html += "<th style=\"\(Style.th)\">\(escape(counterpartyHeader))</th>"
        }
        html += "<th style=\"\(Style.thRight)\">Netto</th>"
        html += "<th style=\"\(Style.thRight)\">Brutto</th>"
        html += "</tr></thead><tbody>"

        let sorted = invoices.sorted {
            ($0.issueDate ?? .distantPast, $0.invoiceNumber) < ($1.issueDate ?? .distantPast, $1.invoiceNumber)
        }

        for invoice in sorted {
            let date = invoice.issueDate.map { Fmt.isoDate($0) } ?? "—"
            var number = escape(invoice.invoiceNumber)
            if invoice.isCorrection {
                number += " <span style=\"color:#b00;font-weight:600;\">(korekta)</span>"
            }
            let counterparty = escape(invoice.counterparty.displayName)

            html += "<tr>"
            html += "<td style=\"\(Style.td)\">\(escape(date))</td>"
            if counterpartyFirst {
                html += "<td style=\"\(Style.td)\">\(counterparty)</td><td style=\"\(Style.td)\">\(number)</td>"
            } else {
                html += "<td style=\"\(Style.td)\">\(number)</td><td style=\"\(Style.td)\">\(counterparty)</td>"
            }
            html += "<td style=\"\(Style.tdRight)\">\(money(invoice.totalNet, currency: invoice.currency))</td>"
            html += "<td style=\"\(Style.tdRight)\">\(money(invoice.totalGross, currency: invoice.currency))</td>"
            html += "</tr>"
        }

        for total in Totals.byCurrency(invoices) {
            html += "<tr>"
            html += "<td style=\"\(Style.tdSumLabel)\" colspan=\"3\">Razem (\(escape(total.currency))) — \(total.count) fakt.</td>"
            html += "<td style=\"\(Style.tdSum)\">\(money(total.net, currency: total.currency))</td>"
            html += "<td style=\"\(Style.tdSum)\">\(money(total.gross, currency: total.currency))</td>"
            html += "</tr>"
        }

        html += "</tbody></table>"
        return html
    }

    /// Podsumowanie zbiorcze: sprzedaż, zakupy i różnica — osobny blok dla każdej waluty.
    private static func summarySection(for set: InvoiceSet) -> String {
        let currencies = Set(Totals.byCurrency(set.issued).map(\.currency))
            .union(Totals.byCurrency(set.received).map(\.currency))
            .sorted { a, b in
                if a == "PLN" { return true }
                if b == "PLN" { return false }
                return a < b
            }
        guard !currencies.isEmpty else { return "" }

        var html = "<div style=\"\(Style.heading)\">Podsumowanie zbiorcze</div>"

        for currency in currencies {
            let sales = Totals.byCurrency(set.issued).first { $0.currency == currency }
                ?? CurrencyTotals(currency: currency)
            let purchases = Totals.byCurrency(set.received).first { $0.currency == currency }
                ?? CurrencyTotals(currency: currency)

            html += "<table style=\"\(Style.table)\" cellspacing=\"0\"><thead><tr>"
            html += "<th style=\"\(Style.th)\">Waluta \(escape(currency))</th>"
            html += "<th style=\"\(Style.thRight)\">Netto</th>"
            html += "<th style=\"\(Style.thRight)\">VAT</th>"
            html += "<th style=\"\(Style.thRight)\">Brutto</th>"
            html += "</tr></thead><tbody>"

            func row(_ label: String, _ totals: CurrencyTotals, emphasised: Bool) -> String {
                let labelStyle = emphasised ? Style.tdSumLabel : Style.td
                let valueStyle = emphasised ? Style.tdSum : Style.tdRight
                var out = "<tr><td style=\"\(labelStyle)\">\(escape(label))</td>"
                out += "<td style=\"\(valueStyle)\">\(money(totals.net, currency: currency))</td>"
                out += "<td style=\"\(valueStyle)\">\(money(totals.vat, currency: currency))</td>"
                out += "<td style=\"\(valueStyle)\">\(money(totals.gross, currency: currency))</td></tr>"
                return out
            }

            html += row("Sprzedaż (faktury wystawione)", sales, emphasised: false)
            html += row("Zakupy (faktury otrzymane)", purchases, emphasised: false)

            var difference = CurrencyTotals(currency: currency)
            difference.net = sales.net - purchases.net
            difference.vat = sales.vat - purchases.vat
            difference.gross = sales.gross - purchases.gross
            html += row("Różnica (sprzedaż − zakupy)", difference, emphasised: true)

            html += "</tbody></table>"
        }
        return html
    }

    // MARK: - Wersja tekstowa

    /// Alternatywna treść `text/plain` dla klientów, które nie wyświetlają HTML.
    static func plainText(for set: InvoiceSet, companyName: String) -> String {
        var out = "Zestawienie faktur KSeF za \(set.period.displayName)\n"
        out += "Podmiot: \(companyName.isEmpty ? "—" : companyName), NIP \(Nip.formatted(set.nip))\n"
        out += "Liczba faktur: \(set.issued.count + set.received.count) "
        out += "(wystawione: \(set.issued.count), otrzymane: \(set.received.count))\n"
        out += "Wygenerowano: \(Fmt.dateTime(set.fetchedAt))\n"

        func section(_ title: String, _ invoices: [Invoice]) -> String {
            var text = "\n\(title)\n" + String(repeating: "-", count: title.count) + "\n"
            if invoices.isEmpty {
                text += "Brak faktur.\n"
                return text
            }
            let sorted = invoices.sorted {
                ($0.issueDate ?? .distantPast, $0.invoiceNumber) < ($1.issueDate ?? .distantPast, $1.invoiceNumber)
            }
            for invoice in sorted {
                let date = invoice.issueDate.map { Fmt.isoDate($0) } ?? "—"
                let marker = invoice.isCorrection ? " (korekta)" : ""
                text += "\(date)  \(invoice.invoiceNumber)\(marker)  \(invoice.counterparty.displayName)  "
                text += "netto \(Fmt.money(invoice.totalNet, currency: invoice.currency)), "
                text += "brutto \(Fmt.money(invoice.totalGross, currency: invoice.currency))\n"
            }
            for total in Totals.byCurrency(invoices) {
                text += "Razem (\(total.currency)): netto \(total.netFormatted), "
                text += "VAT \(total.vatFormatted), brutto \(total.grossFormatted)\n"
            }
            return text
        }

        out += section("Faktury wystawione", set.issued)
        out += section("Faktury otrzymane", set.received)

        out += "\nPodsumowanie zbiorcze\n---------------------\n"
        for total in Totals.balance(issued: set.issued, received: set.received) {
            out += "Różnica (sprzedaż − zakupy) \(total.currency): netto \(total.netFormatted), "
            out += "VAT \(total.vatFormatted), brutto \(total.grossFormatted)\n"
        }

        out += "\nZałączone pliki PDF są wizualizacjami faktur ustrukturyzowanych z KSeF. "
        out += "Dokumentem źródłowym pozostaje plik XML w KSeF.\n"
        out += "Wygenerowano programem \(AppInfo.displayVersion).\n"
        return out
    }
}
