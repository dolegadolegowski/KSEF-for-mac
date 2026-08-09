import Foundation

/// Suma kwot w jednej walucie. Waluty nigdy nie są mieszane — każda ma własny wiersz.
struct CurrencyTotals: Identifiable, Hashable {
    let currency: String
    var net: Decimal = 0
    var vat: Decimal = 0
    var gross: Decimal = 0
    var count: Int = 0

    var id: String { currency }

    var netFormatted: String { Fmt.money(net, currency: currency) }
    var vatFormatted: String { Fmt.money(vat, currency: currency) }
    var grossFormatted: String { Fmt.money(gross, currency: currency) }
}

enum Totals {
    /// Sumuje faktury w rozbiciu na waluty. Korekty z kwotami ujemnymi pomniejszają sumy,
    /// bo ich wartości są ujemne już w dokumencie źródłowym.
    static func byCurrency(_ invoices: [Invoice]) -> [CurrencyTotals] {
        var buckets: [String: CurrencyTotals] = [:]
        for invoice in invoices {
            let currency = invoice.currency.uppercased()
            var bucket = buckets[currency] ?? CurrencyTotals(currency: currency)
            bucket.net += invoice.totalNet
            bucket.vat += invoice.totalVat
            bucket.gross += invoice.totalGross
            bucket.count += 1
            buckets[currency] = bucket
        }
        // PLN na początku, pozostałe alfabetycznie — stabilna kolejność w UI, PDF i e-mailu.
        return buckets.values.sorted {
            if $0.currency == "PLN" { return true }
            if $1.currency == "PLN" { return false }
            return $0.currency < $1.currency
        }
    }

    /// Saldo: wystawione minus otrzymane, osobno dla każdej waluty.
    static func balance(issued: [Invoice], received: [Invoice]) -> [CurrencyTotals] {
        let issuedTotals = byCurrency(issued)
        let receivedTotals = byCurrency(received)

        var buckets: [String: CurrencyTotals] = [:]
        for total in issuedTotals {
            var bucket = buckets[total.currency] ?? CurrencyTotals(currency: total.currency)
            bucket.net += total.net
            bucket.vat += total.vat
            bucket.gross += total.gross
            bucket.count += total.count
            buckets[total.currency] = bucket
        }
        for total in receivedTotals {
            var bucket = buckets[total.currency] ?? CurrencyTotals(currency: total.currency)
            bucket.net -= total.net
            bucket.vat -= total.vat
            bucket.gross -= total.gross
            bucket.count += total.count
            buckets[total.currency] = bucket
        }
        return buckets.values.sorted {
            if $0.currency == "PLN" { return true }
            if $1.currency == "PLN" { return false }
            return $0.currency < $1.currency
        }
    }
}
