import Foundation

/// Wydanie aplikacji opublikowane w serwisie GitHub.
struct AppRelease: Equatable, Sendable {
    let version: String
    let title: String
    let notes: String
    let pageURL: URL
    /// Adres pliku `.zip` z pakietem aplikacji, o ile wydanie go zawiera.
    let downloadURL: URL?
    let publishedAt: Date?

    var displayTitle: String {
        title.isEmpty ? "Wersja \(version)" : title
    }
}

/// Sprawdza, czy w repozytorium opublikowano nowsze wydanie aplikacji.
///
/// Moduł wyłącznie *informuje* o aktualizacji i prowadzi do pliku — nie podmienia
/// pakietu samodzielnie. Aplikacja działa w piaskownicy, więc nie ma prawa zapisu
/// do `/Applications`; instalację wykonuje użytkownik, przeciągając nowy pakiet.
actor UpdateChecker {
    /// Publiczne repozytorium z wydaniami.
    static let defaultRepository = "dolegadolegowski/KSEF-for-mac"

    private let session: URLSession
    private let repository: String

    init(repository: String = UpdateChecker.defaultRepository, session: URLSession? = nil) {
        self.repository = repository
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.httpAdditionalHeaders = ["User-Agent": AppInfo.userAgent]
            self.session = URLSession(configuration: configuration)
        }
    }

    enum UpdateError: LocalizedError {
        case network(String)
        case noReleases
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case let .network(detail):
                return "Nie udało się sprawdzić aktualizacji: \(detail)"
            case .noReleases:
                return "W repozytorium nie opublikowano jeszcze żadnego wydania."
            case let .decoding(detail):
                return "Nieoczekiwana odpowiedź serwisu GitHub: \(detail)"
            }
        }
    }

    // MARK: - Odpowiedź API GitHuba

    private struct ReleaseResponse: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: String

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: String
        let draft: Bool
        let prerelease: Bool
        let publishedAt: String?
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name, body, draft, prerelease, assets
            case htmlURL = "html_url"
            case publishedAt = "published_at"
        }
    }

    /// Pobiera najnowsze wydanie i zwraca je tylko wtedy, gdy jest nowsze od bieżącej wersji.
    func checkForUpdate(currentVersion: String = AppInfo.version) async throws -> AppRelease? {
        let release = try await fetchLatestRelease()
        guard Version.isNewer(release.version, than: currentVersion) else { return nil }
        return release
    }

    /// Pobiera najnowsze wydanie niezależnie od numeru bieżącej wersji.
    func fetchLatestRelease() async throws -> AppRelease {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw UpdateError.network("nieprawidłowy adres repozytorium")
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.network("odpowiedź bez nagłówka HTTP")
        }
        // Brak wydań albo repozytorium jeszcze puste.
        if http.statusCode == 404 { throw UpdateError.noReleases }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw UpdateError.network("serwis GitHub odpowiedział kodem \(http.statusCode)")
        }

        let decoded: ReleaseResponse
        do {
            decoded = try JSONDecoder().decode(ReleaseResponse.self, from: data)
        } catch {
            throw UpdateError.decoding(String(describing: error))
        }

        guard !decoded.draft else { throw UpdateError.noReleases }
        guard let pageURL = URL(string: decoded.htmlURL) else {
            throw UpdateError.decoding("brak adresu strony wydania")
        }

        // Interesuje nas archiwum z pakietem aplikacji.
        let asset = decoded.assets.first { $0.name.lowercased().hasSuffix(".zip") }

        return AppRelease(
            version: Version.normalize(decoded.tagName),
            title: decoded.name ?? "",
            notes: (decoded.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            pageURL: pageURL,
            downloadURL: asset.flatMap { URL(string: $0.browserDownloadURL) },
            publishedAt: decoded.publishedAt.flatMap { KsefHTTP.parseDate($0) }
        )
    }

    /// Pobiera plik wydania do pamięci, żeby aplikacja mogła zapisać go w miejscu
    /// wskazanym przez użytkownika.
    func downloadPackage(from url: URL) async throws -> Data {
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200 ..< 300).contains(http.statusCode) else {
                throw UpdateError.network("nie udało się pobrać pliku wydania")
            }
            return data
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }
    }
}

/// Porównywanie numerów wersji w zapisie semantycznym.
enum Version {
    /// Usuwa przedrostek „v" i białe znaki: „v1.2.3" → „1.2.3".
    static func normalize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("v") { value.removeFirst() }
        return value
    }

    /// Rozbija wersję na człony liczbowe i ewentualny przedrostek wydania wstępnego.
    /// „1.2.3-rc1" → ([1, 2, 3], "rc1")
    static func parse(_ raw: String) -> (numbers: [Int], preRelease: String?) {
        let normalized = normalize(raw)
        let parts = normalized.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numeric = parts[0].split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        let preRelease = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil
        return (numeric, preRelease)
    }

    /// Czy `candidate` jest nowsza niż `current`.
    ///
    /// Wydanie wstępne (np. `1.1.0-rc1`) jest starsze od wydania końcowego o tym samym
    /// numerze, ale nowsze od poprzedniej wersji końcowej.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = parse(candidate)
        let right = parse(current)

        let count = max(left.numbers.count, right.numbers.count)
        for index in 0 ..< count {
            let a = index < left.numbers.count ? left.numbers[index] : 0
            let b = index < right.numbers.count ? right.numbers[index] : 0
            if a != b { return a > b }
        }

        switch (left.preRelease, right.preRelease) {
        case (nil, nil): return false
        case (nil, _?): return true      // wydanie końcowe jest nowsze niż jego wersja wstępna
        case (_?, nil): return false
        case let (a?, b?): return a.compare(b, options: .numeric) == .orderedDescending
        }
    }
}
