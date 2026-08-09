import Foundation

/// Limiter żądań w modelu przesuwającego się okna, zgodny z zasadami opisanymi
/// w dokumentacji KSeF (progi req/s, req/min i req/h obowiązują równolegle).
///
/// Znaczniki czasu są utrwalane na dysku, więc limit godzinowy przeżywa restart aplikacji —
/// bez tego ponowne uruchomienie natychmiast po pobraniu paczki faktur wpadłoby w 429.
actor RateLimiter {
    struct Limits: Sendable {
        let perSecond: Int
        let perMinute: Int
        let perHour: Int

        /// Limity endpointu `GET /invoices/ksef/{ksefNumber}` według OpenAPI KSeF.
        static let invoiceDownload = Limits(perSecond: 8, perMinute: 16, perHour: 64)

        /// Limity endpointów `POST /invoices/query/metadata` i `POST /invoices/exports`.
        static let invoiceQuery = Limits(perSecond: 8, perMinute: 16, perHour: 20)
    }

    private let limits: Limits
    private let storageURL: URL?
    private var timestamps: [Date] = []

    /// Margines bezpieczeństwa: limity są naliczane po stronie serwera, więc odczekujemy
    /// odrobinę dłużej niż wynika z okna, żeby nie trafić w granicę.
    private let safetyMargin: TimeInterval = 0.35

    init(limits: Limits, storageURL: URL?) {
        self.limits = limits
        self.storageURL = storageURL
        timestamps = RateLimiter.load(from: storageURL)
    }

    /// Liczba żądań wykonanych w ostatniej godzinie.
    var usedInLastHour: Int {
        let cutoff = Date().addingTimeInterval(-3600)
        return timestamps.filter { $0 > cutoff }.count
    }

    /// Ile żądań pozostało w oknie godzinnym.
    var remainingInHour: Int {
        max(0, limits.perHour - usedInLastHour)
    }

    /// Szacowany czas oczekiwania na wykonanie `count` kolejnych żądań.
    /// Używane do komunikatu o przewidywanym czasie, gdy kolejka jest długa.
    func estimatedDuration(for count: Int) -> TimeInterval {
        guard count > 0 else { return 0 }
        var simulated = timestamps
        var now = Date()
        var total: TimeInterval = 0

        for _ in 0 ..< count {
            let wait = Self.delay(for: simulated, at: now, limits: limits, margin: safetyMargin)
            now = now.addingTimeInterval(wait)
            total += wait
            simulated.append(now)
            simulated = Self.prune(simulated, now: now)
        }
        return total
    }

    /// Czeka, aż wykonanie kolejnego żądania zmieści się w limitach, po czym rezerwuje slot.
    /// Rzuca `KsefError.cancelled`, gdy zadanie zostało anulowane w trakcie oczekiwania.
    func acquire() async throws {
        while true {
            let now = Date()
            timestamps = Self.prune(timestamps, now: now)
            let wait = Self.delay(for: timestamps, at: now, limits: limits, margin: safetyMargin)
            if wait <= 0 {
                timestamps.append(now)
                persist()
                return
            }
            try await sleep(wait)
        }
    }

    /// Rejestruje odrzucenie 429: blokuje kolejkę na czas wskazany przez `Retry-After`.
    func penalize(retryAfter: TimeInterval) async throws {
        guard retryAfter > 0 else { return }
        logWarn("Wstrzymanie kolejki na \(Int(retryAfter)) s po odpowiedzi 429.")
        try await sleep(retryAfter)
    }

    private func sleep(_ seconds: TimeInterval) async throws {
        do {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        } catch {
            throw KsefError.cancelled
        }
    }

    // MARK: - Obliczenia okna

    private static func prune(_ timestamps: [Date], now: Date) -> [Date] {
        let cutoff = now.addingTimeInterval(-3600)
        return timestamps.filter { $0 > cutoff }
    }

    /// Zwraca czas, jaki trzeba odczekać, żeby żądanie zmieściło się we wszystkich progach.
    private static func delay(for timestamps: [Date], at now: Date, limits: Limits, margin: TimeInterval) -> TimeInterval {
        var wait: TimeInterval = 0

        func check(window: TimeInterval, limit: Int) {
            guard limit > 0 else { return }
            let inWindow = timestamps.filter { $0 > now.addingTimeInterval(-window) }.sorted()
            guard inWindow.count >= limit else { return }
            // Slot zwolni się, gdy najstarsze żądanie w oknie z niego wypadnie.
            let oldest = inWindow[inWindow.count - limit]
            let freeAt = oldest.addingTimeInterval(window + margin)
            wait = max(wait, freeAt.timeIntervalSince(now))
        }

        check(window: 1, limit: limits.perSecond)
        check(window: 60, limit: limits.perMinute)
        check(window: 3600, limit: limits.perHour)
        return max(0, wait)
    }

    // MARK: - Trwałość

    private func persist() {
        guard let storageURL else { return }
        let payload = timestamps.map(\.timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: storageURL, options: .atomic)
    }

    private static func load(from url: URL?) -> [Date] {
        guard let url,
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode([TimeInterval].self, from: data)
        else { return [] }
        let cutoff = Date().addingTimeInterval(-3600)
        return payload.map(Date.init(timeIntervalSince1970:)).filter { $0 > cutoff }
    }
}
