import Foundation

enum UpdateTests {
    static func run() {
        T.suite("Porównywanie wersji") {
            T.test("rozpoznaje nowszą wersję") {
                T.expect(Version.isNewer("1.0.1", than: "1.0.0"), "wyższa wersja poprawkowa")
                T.expect(Version.isNewer("1.1.0", than: "1.0.9"), "wyższa wersja pomocnicza")
                T.expect(Version.isNewer("2.0.0", than: "1.9.9"), "wyższa wersja główna")
                T.expect(Version.isNewer("1.0.10", than: "1.0.9"), "porównanie liczbowe, nie tekstowe")
                T.expect(Version.isNewer("1.1", than: "1.0.9"), "krótszy zapis wersji")
            }

            T.test("nie zgłasza aktualizacji dla wersji tej samej lub starszej") {
                T.expect(!Version.isNewer("1.0.0", than: "1.0.0"), "identyczna wersja")
                T.expect(!Version.isNewer("1.0.0", than: "1.0.1"), "starsza wersja")
                T.expect(!Version.isNewer("1.0.0", than: "2.0.0"), "znacznie starsza wersja")
                T.expect(!Version.isNewer("1.0", than: "1.0.0"), "równoważny zapis skrócony")
            }

            T.test("pomija przedrostek v i traktuje wydania wstępne jako starsze") {
                T.expect(Version.isNewer("v1.1.0", than: "1.0.0"), "przedrostek v nie zmienia porównania")
                T.equal(Version.normalize("v2.3.4"), "2.3.4", "normalizacja numeru wersji")

                // Wydanie końcowe jest nowsze niż jego wersja wstępna…
                T.expect(Version.isNewer("1.1.0", than: "1.1.0-rc1"), "wydanie końcowe nad wstępnym")
                // …ale wersja wstępna nadal wyprzedza poprzednie wydanie końcowe.
                T.expect(Version.isNewer("1.1.0-rc1", than: "1.0.0"), "wersja wstępna nad starszym wydaniem")
                T.expect(!Version.isNewer("1.1.0-rc1", than: "1.1.0"), "wersja wstępna nie zastępuje końcowej")
                T.expect(Version.isNewer("1.1.0-rc2", than: "1.1.0-rc1"), "kolejna wersja wstępna")
            }

            T.test("rozbija numer wersji na człony") {
                let parsed = Version.parse("v1.2.3-rc4")
                T.equal(parsed.numbers, [1, 2, 3], "człony liczbowe")
                T.equal(parsed.preRelease, "rc4", "oznaczenie wydania wstępnego")

                let simple = Version.parse("2.0")
                T.equal(simple.numbers, [2, 0], "wersja bez trzeciego członu")
                T.isNil(simple.preRelease, "brak oznaczenia wydania wstępnego")
            }
        }

        T.suite("Odczyt wydania z GitHuba") {
            T.test("odczytuje wydanie i wskazuje pakiet do pobrania") {
                MockURLProtocol.reset()
                defer { MockURLProtocol.reset() }

                let payload = """
                {
                  "tag_name": "v1.2.0",
                  "name": "Wersja 1.2.0",
                  "body": "Poprawiono wyliczanie kwot netto.",
                  "html_url": "https://github.com/dolegadolegowski/KSEF-for-mac/releases/tag/v1.2.0",
                  "draft": false,
                  "prerelease": false,
                  "published_at": "2026-08-09T10:00:00Z",
                  "assets": [
                    {"name": "notatki.txt", "browser_download_url": "https://example.invalid/notatki.txt"},
                    {"name": "KSeFFaktury.zip", "browser_download_url": "https://example.invalid/KSeFFaktury.zip"}
                  ]
                }
                """
                MockURLProtocol.handler = { request in
                    T.expect(request.path.hasSuffix("/releases/latest"),
                             "moduł musi pytać o najnowsze wydanie (pytał o \(request.path))")
                    return (200, ["Content-Type": "application/json"], Data(payload.utf8))
                }

                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [MockURLProtocol.self]
                let checker = UpdateChecker(repository: "dolegadolegowski/KSEF-for-mac",
                                            session: URLSession(configuration: configuration))

                let release = try T.runAsync { try await checker.checkForUpdate(currentVersion: "1.0.0") }
                guard let release else {
                    T.fail("oczekiwano wykrycia nowszej wersji")
                    return
                }
                T.equal(release.version, "1.2.0", "numer wersji bez przedrostka v")
                T.equal(release.title, "Wersja 1.2.0", "tytuł wydania")
                T.equal(release.notes, "Poprawiono wyliczanie kwot netto.", "opis zmian")
                // Spośród załączników wybieramy archiwum z pakietem aplikacji.
                T.equal(release.downloadURL?.lastPathComponent, "KSeFFaktury.zip", "plik do pobrania")
                T.notNil(release.publishedAt, "data publikacji")
            }

            T.test("milczy, gdy zainstalowana wersja jest aktualna") {
                MockURLProtocol.reset()
                defer { MockURLProtocol.reset() }

                MockURLProtocol.handler = { _ in
                    let payload = #"{"tag_name":"v1.0.0","name":"","body":"","html_url":"https://example.invalid","draft":false,"prerelease":false,"published_at":null,"assets":[]}"#
                    return (200, ["Content-Type": "application/json"], Data(payload.utf8))
                }

                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [MockURLProtocol.self]
                let checker = UpdateChecker(session: URLSession(configuration: configuration))

                let release = try T.runAsync { try await checker.checkForUpdate(currentVersion: "1.0.0") }
                T.isNil(release, "dla aktualnej wersji nie zgłaszamy aktualizacji")
            }

            T.test("zgłasza brak wydań zrozumiałym komunikatem") {
                MockURLProtocol.reset()
                defer { MockURLProtocol.reset() }

                MockURLProtocol.handler = { _ in
                    (404, ["Content-Type": "application/json"], Data(#"{"message":"Not Found"}"#.utf8))
                }

                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [MockURLProtocol.self]
                let checker = UpdateChecker(session: URLSession(configuration: configuration))

                do {
                    _ = try T.runAsync { try await checker.checkForUpdate(currentVersion: "1.0.0") }
                    T.fail("oczekiwano błędu o braku wydań")
                } catch let error as UpdateChecker.UpdateError {
                    T.expect(error.errorDescription?.contains("wydania") == true,
                             "komunikat po polsku o braku wydań")
                }
            }
        }

        T.suite("Adres odbiorcy wiadomości") {
            T.test("sprawdza kształt adresu e-mail") {
                T.expect(AppSettings.isValidEmail("biuro@rachunkowe.pl"), "zwykły adres")
                T.expect(AppSettings.isValidEmail("jan.kowalski+ksef@firma.com.pl"), "adres z kropkami i plusem")
                T.expect(!AppSettings.isValidEmail(""), "pusty adres")
                T.expect(!AppSettings.isValidEmail("bez-małpy.pl"), "brak znaku @")
                T.expect(!AppSettings.isValidEmail("@domena.pl"), "brak części lokalnej")
                T.expect(!AppSettings.isValidEmail("jan@domena"), "domena bez kropki")
                T.expect(!AppSettings.isValidEmail("jan kowalski@firma.pl"), "spacja w adresie")
            }

            T.test("wpisuje odbiorcę do nagłówka To wiadomości") {
                let eml = MailComposer.makeEML(subject: "Faktury KSeF", html: "<p>a</p>",
                                               plainText: "a", attachments: [],
                                               recipient: "biuro@rachunkowe.pl")
                let message = String(data: eml, encoding: .utf8)!
                T.expect(message.contains("To: biuro@rachunkowe.pl\r\n"),
                         "adres odbiorcy musi trafić do nagłówka To")
            }

            T.test("pozostawia pusty nagłówek, gdy adresu nie podano") {
                let eml = MailComposer.makeEML(subject: "Faktury KSeF", html: "<p>a</p>",
                                               plainText: "a", attachments: [])
                let message = String(data: eml, encoding: .utf8)!
                T.expect(message.contains("To: \r\n"), "bez adresu nagłówek pozostaje pusty")
            }
        }
    }
}
