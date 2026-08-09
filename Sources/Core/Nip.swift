import Foundation

/// Walidacja i normalizacja numeru NIP.
enum Nip {
    private static let weights = [6, 5, 7, 2, 3, 4, 5, 6, 7]

    /// Usuwa spacje, myślniki i prefiks "PL".
    static func normalize(_ raw: String) -> String {
        var s = raw.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        if s.hasPrefix("PL") { s.removeFirst(2) }
        return s
    }

    /// Sprawdza długość, cyfry i sumę kontrolną (mod 11).
    static func isValid(_ raw: String) -> Bool {
        let s = normalize(raw)
        guard s.count == 10 else { return false }
        let digits = s.compactMap { $0.wholeNumberValue }
        guard digits.count == 10 else { return false }

        let sum = zip(weights, digits.prefix(9)).reduce(0) { $0 + $1.0 * $1.1 }
        let checksum = sum % 11
        // Reszta 10 nie jest poprawną cyfrą kontrolną — taki NIP nie istnieje.
        guard checksum != 10 else { return false }
        return checksum == digits[9]
    }

    /// Formatuje do postaci 123-456-78-90 na potrzeby prezentacji.
    static func formatted(_ raw: String) -> String {
        let s = normalize(raw)
        guard s.count == 10 else { return raw }
        let c = Array(s)
        return "\(c[0])\(c[1])\(c[2])-\(c[3])\(c[4])\(c[5])-\(c[6])\(c[7])-\(c[8])\(c[9])"
    }
}
