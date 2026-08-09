import Foundation

/// Miesiąc rozliczeniowy wraz z granicami zakresu w strefie Europe/Warsaw.
///
/// Granice liczone są kalendarzowo w strefie warszawskiej, więc zmiana czasu letniego
/// (ostatnia niedziela marca i października) nie przesuwa początku ani końca miesiąca.
struct MonthPeriod: Equatable, Hashable, Codable {
    let year: Int
    let month: Int

    init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = Fmt.warsaw
        c.locale = Fmt.locale
        return c
    }()

    /// Miesiąc bieżący — okres pokazywany po uruchomieniu aplikacji.
    static func current(from date: Date = Date()) -> MonthPeriod {
        let comps = calendar.dateComponents([.year, .month], from: date)
        return MonthPeriod(year: comps.year!, month: comps.month!)
    }

    /// Miesiąc poprzedzający bieżący.
    static func previousMonth(from date: Date = Date()) -> MonthPeriod {
        let cal = calendar
        let startOfThisMonth = cal.date(from: cal.dateComponents([.year, .month], from: date))!
        let previous = cal.date(byAdding: .month, value: -1, to: startOfThisMonth)!
        let comps = cal.dateComponents([.year, .month], from: previous)
        return MonthPeriod(year: comps.year!, month: comps.month!)
    }

    /// Pierwszy dzień miesiąca o 00:00:00 czasu warszawskiego.
    var start: Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = 1
        comps.hour = 0
        comps.minute = 0
        comps.second = 0
        comps.timeZone = Fmt.warsaw
        return MonthPeriod.calendar.date(from: comps)!
    }

    /// Pierwsza chwila kolejnego miesiąca — używana jako granica wyłączna przy obliczeniach.
    var startOfNextMonth: Date {
        MonthPeriod.calendar.date(byAdding: .month, value: 1, to: start)!
    }

    /// Ostatnia chwila miesiąca: 23:59:59.999 czasu warszawskiego.
    var end: Date {
        startOfNextMonth.addingTimeInterval(-0.001)
    }

    var tag: String { Fmt.monthTag(month: month, year: year) }
    var displayName: String { Fmt.monthName(month: month, year: year) }
    var displayNameGenitive: String { Fmt.monthNameGenitive(month: month, year: year) }

    /// Liczba dni w miesiącu — używana w testach granic zakresu.
    var dayCount: Int {
        MonthPeriod.calendar.range(of: .day, in: .month, for: start)?.count ?? 0
    }

    // MARK: - Format ISO-8601 dla API

    /// Formatter tworzony na żądanie — zapytania o zakres dat wykonujemy rzadko,
    /// więc nie ma powodu współdzielić obiektu, który nie jest `Sendable`.
    private static func makeISOFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = Fmt.warsaw
        return f
    }

    /// „2026-07-01T00:00:00.000+02:00” — jawny offset, zgodnie z wymaganiem API.
    var isoFrom: String { MonthPeriod.makeISOFormatter().string(from: start) }

    /// „2026-07-31T23:59:59.999+02:00”.
    var isoTo: String { MonthPeriod.makeISOFormatter().string(from: end) }

    /// Zakres miesięcy do wyboru w UI: bieżący i 35 wstecz.
    static func selectableRange(from date: Date = Date(), count: Int = 36) -> [MonthPeriod] {
        let cal = calendar
        let startOfThisMonth = cal.date(from: cal.dateComponents([.year, .month], from: date))!
        return (0 ..< count).compactMap { offset in
            guard let d = cal.date(byAdding: .month, value: -offset, to: startOfThisMonth) else { return nil }
            let comps = cal.dateComponents([.year, .month], from: d)
            return MonthPeriod(year: comps.year!, month: comps.month!)
        }
    }
}
