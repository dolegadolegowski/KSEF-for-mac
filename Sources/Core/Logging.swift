import Foundation

/// Dziennik diagnostyczny z centralną redakcją sekretów.
///
/// Każdy tekst trafiający do dziennika — a także każdy komunikat błędu pokazywany w UI —
/// przechodzi przez `redact(_:)`. Sekrety znane w czasie działania (token KSeF, access token,
/// refresh token) są dodatkowo rejestrowane przez `registerSecret(_:)`, dzięki czemu ich
/// dosłowne wystąpienia znikają nawet wtedy, gdy nie pasują do żadnego wzorca.
final class Log: @unchecked Sendable {
    static let shared = Log()

    /// Łączny limit dziennika: bieżący plik + jedna rotacja.
    private static let maxFileBytes = 1_000_000

    private let queue = DispatchQueue(label: "pl.ksef.faktury.log")
    private var secrets: Set<String> = []
    private var fileURL: URL?

    enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warn = "OSTRZ"
        case error = "BŁĄD"
    }

    private init() {
        fileURL = Log.prepareLogDirectory()
    }

    private static func prepareLogDirectory() -> URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil,
                                     create: true) else { return nil }
        let dir = base.appendingPathComponent("KSeF Faktury/Logs", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ksef-faktury.log")
    }

    // MARK: - Rejestr sekretów

    /// Rejestruje wartość, która nigdy nie może pojawić się w dzienniku ani w UI.
    /// Krótkie wartości są ignorowane, żeby nie zamazywać przypadkowych fragmentów tekstu.
    func registerSecret(_ secret: String?) {
        guard let secret, secret.count >= 8 else { return }
        queue.sync { _ = secrets.insert(secret) }
    }

    func clearSecrets() {
        queue.sync { secrets.removeAll() }
    }

    // MARK: - Redakcja

    /// `NSRegularExpression` jest z założenia niezmienny i bezpieczny wątkowo,
    /// więc wzorce mogą być współdzielone bez synchronizacji.
    private static let patterns: [(NSRegularExpression, String)] = {
        func rx(_ p: String) -> NSRegularExpression? {
            try? NSRegularExpression(pattern: p, options: [.caseInsensitive])
        }
        var out: [(NSRegularExpression, String)] = []
        // Nagłówek Authorization w każdej postaci.
        if let r = rx(#"(Authorization\s*:\s*)(Bearer\s+)?[A-Za-z0-9._\-+/=]+"#) {
            out.append((r, "$1Bearer ***ZREDAGOWANO***"))
        }
        // Samodzielny token typu Bearer.
        if let r = rx(#"Bearer\s+[A-Za-z0-9._\-+/=]{8,}"#) {
            out.append((r, "Bearer ***ZREDAGOWANO***"))
        }
        // JWT — trzy segmenty Base64URL zaczynające się od nagłówka „eyJ”.
        if let r = rx(#"eyJ[A-Za-z0-9_\-]{6,}\.[A-Za-z0-9_\-]{6,}\.[A-Za-z0-9_\-]*"#) {
            out.append((r, "***JWT-ZREDAGOWANO***"))
        }
        // Pola JSON przenoszące materiał kryptograficzny.
        if let r = rx(#"("(?:encryptedToken|encryptedSymmetricKey|token|refreshToken|accessToken|ksefToken)"\s*:\s*")[^"]{8,}(")"#) {
            out.append((r, "$1***ZREDAGOWANO***$2"))
        }
        // Bloki PEM z kluczem prywatnym.
        if let r = rx(#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#) {
            out.append((r, "***KLUCZ-PRYWATNY-ZREDAGOWANO***"))
        }
        return out
    }()

    /// Usuwa z tekstu wszystkie znane sekrety i wzorce sekretów.
    func redact(_ text: String) -> String {
        var out = text
        let known = queue.sync { secrets }
        // Najpierw dosłowne wartości — działa nawet dla tokenów o nietypowym kształcie.
        for secret in known.sorted(by: { $0.count > $1.count }) {
            out = out.replacingOccurrences(of: secret, with: "***ZREDAGOWANO***")
        }
        for (regex, template) in Log.patterns {
            out = regex.stringByReplacingMatches(
                in: out,
                options: [],
                range: NSRange(out.startIndex..., in: out),
                withTemplate: template
            )
        }
        return out
    }

    /// Statyczny skrót — używany też przez warstwę UI przed pokazaniem szczegółów technicznych.
    static func redact(_ text: String) -> String { shared.redact(text) }

    // MARK: - Zapis

    func write(_ level: Level, _ message: String) {
        let safe = redact(message)
        let line = "[\(Fmt.dateTime(Date()))] [\(level.rawValue)] \(safe)\n"
        queue.async { [weak self] in
            guard let self, let url = self.fileURL else { return }
            self.rotateIfNeeded(url)
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: url.path),
                   let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                } else {
                    try? data.write(to: url, options: .atomic)
                }
            }
        }
        #if DEBUG
        print(line, terminator: "")
        #endif
    }

    private func rotateIfNeeded(_ url: URL) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > Log.maxFileBytes else { return }
        let rotated = url.deletingPathExtension().appendingPathExtension("1.log")
        try? fm.removeItem(at: rotated)
        try? fm.moveItem(at: url, to: rotated)
    }

    /// Ścieżka dziennika — pokazywana w UI, żeby użytkownik mógł go otworzyć.
    var logFileURL: URL? { fileURL }
}

func logDebug(_ m: @autoclosure () -> String) { Log.shared.write(.debug, m()) }
func logInfo(_ m: @autoclosure () -> String) { Log.shared.write(.info, m()) }
func logWarn(_ m: @autoclosure () -> String) { Log.shared.write(.warn, m()) }
func logError(_ m: @autoclosure () -> String) { Log.shared.write(.error, m()) }
