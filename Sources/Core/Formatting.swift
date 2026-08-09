import Foundation

/// Wspólne ustawienia lokalizacji: wszystkie kwoty i daty w aplikacji przechodzą przez ten typ,
/// żeby prezentacja w UI, PDF i e-mailu była identyczna.
enum Fmt {
    static let locale = Locale(identifier: "pl_PL")
    static let warsaw = TimeZone(identifier: "Europe/Warsaw") ?? .current

    /// Spacja nierozdzielająca — separator tysięcy zgodny z polską typografią.
    static let nbsp = "\u{00A0}"

    /// Wstawia separator tysięcy co trzy cyfry, licząc od prawej.
    private static func groupThousands(_ digits: String) -> String {
        guard digits.count > 3 else { return digits }
        var out: [Character] = []
        for (offset, character) in digits.reversed().enumerated() {
            if offset > 0, offset.isMultiple(of: 3) { out.append(Character(nbsp)) }
            out.append(character)
        }
        return String(out.reversed())
    }

    /// „1 234,56” — bez symbolu waluty.
    ///
    /// Formatowanie jest wykonywane ręcznie, a nie przez `NumberFormatter`, ponieważ polska
    /// lokalizacja CLDR ma `minimumGroupingDigits = 2` i pomija separator dla liczb
    /// czterocyfrowych — dawałaby „1234,56” zamiast wymaganego „1 234,56”.
    static func amount(_ value: Decimal) -> String {
        let rounded = value.roundedToCents()
        let isNegative = rounded < 0
        let magnitude = isNegative ? -rounded : rounded

        // Przenosimy grosze na pozycje całkowite, żeby pracować na samych cyfrach.
        var scaled = magnitude * 100
        var asInteger = Decimal()
        NSDecimalRound(&asInteger, &scaled, 0, .plain)

        var digits = NSDecimalNumber(decimal: asInteger).stringValue
        while digits.count < 3 { digits = "0" + digits }

        let cents = String(digits.suffix(2))
        let whole = groupThousands(String(digits.dropLast(2)))
        let sign = (isNegative && asInteger != 0) ? "-" : ""
        return "\(sign)\(whole),\(cents)"
    }

    /// „1 234,56 zł” dla PLN, „1 234,56 EUR” dla pozostałych walut.
    static func money(_ value: Decimal, currency: String) -> String {
        let n = amount(value)
        let code = currency.uppercased()
        return code == "PLN" ? "\(n)\(nbsp)zł" : "\(n)\(nbsp)\(code)"
    }

    /// Liczba o zmiennej precyzji — używana dla ilości, cen jednostkowych i kursów walut.
    /// Zbędne zera na końcu części ułamkowej są usuwane („4,3000” → „4,3”).
    static func quantity(_ value: Decimal) -> String {
        var input = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 6, .plain)

        let isNegative = rounded < 0
        let magnitude = isNegative ? -rounded : rounded
        let plain = NSDecimalNumber(decimal: magnitude).stringValue

        let parts = plain.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let whole = groupThousands(String(parts[0]))
        var fraction = parts.count > 1 ? String(parts[1]) : ""
        while fraction.hasSuffix("0") { fraction.removeLast() }

        let sign = (isNegative && rounded != 0) ? "-" : ""
        return fraction.isEmpty ? "\(sign)\(whole)" : "\(sign)\(whole),\(fraction)"
    }

    /// Zapis liczby niezależny od lokalizacji, z kropką dziesiętną — używany tam,
    /// gdzie wartość trafia do dokumentu XML, a nie do prezentacji.
    static func plainNumber(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    /// Data w formacie RRRR-MM-DD (wymaganym w treści e-maila i nazwach plików).
    static func isoDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = warsaw
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Data i godzina lokalna, np. „2026-07-31 14:05”.
    static func dateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = warsaw
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    /// Data w formacie DD-MM-RRRR wymaganym w linku weryfikacyjnym kodu QR (KOD I).
    static func qrDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = warsaw
        f.dateFormat = "dd-MM-yyyy"
        return f.string(from: date)
    }

    private static let polishMonths = [
        "styczeń", "luty", "marzec", "kwiecień", "maj", "czerwiec",
        "lipiec", "sierpień", "wrzesień", "październik", "listopad", "grudzień",
    ]

    private static let polishMonthsGenitive = [
        "stycznia", "lutego", "marca", "kwietnia", "maja", "czerwca",
        "lipca", "sierpnia", "września", "października", "listopada", "grudnia",
    ]

    /// „lipiec 2026” — mianownik, do tytułu e-maila i nagłówków.
    static func monthName(month: Int, year: Int) -> String {
        guard (1 ... 12).contains(month) else { return "\(month)/\(year)" }
        return "\(polishMonths[month - 1]) \(year)"
    }

    /// „lipca 2026” — dopełniacz, do zdań typu „za miesiąc …”.
    static func monthNameGenitive(month: Int, year: Int) -> String {
        guard (1 ... 12).contains(month) else { return "\(month)/\(year)" }
        return "\(polishMonthsGenitive[month - 1]) \(year)"
    }

    /// „2026-07” — do nazw katalogów i plików.
    static func monthTag(month: Int, year: Int) -> String {
        String(format: "%04d-%02d", year, month)
    }
}

extension Decimal {
    /// Zaokrąglenie do groszy metodą „pół w górę”, używane wyłącznie do wartości wyliczanych,
    /// nigdy do kwot odczytanych wprost z XML.
    func roundedToCents() -> Decimal {
        var input = self
        var output = Decimal()
        NSDecimalRound(&output, &input, 2, .plain)
        return output
    }

    /// Parsuje wartość z XML. KSeF zapisuje kwoty z kropką dziesiętną, ale akceptujemy też przecinek.
    init?(ksefString: String) {
        let cleaned = ksefString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: Fmt.nbsp, with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty,
              let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
        else { return nil }
        self = value
    }
}
