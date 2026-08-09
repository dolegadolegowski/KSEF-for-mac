import Foundation

enum CoreTests {
    static func run() {
        T.suite("Walidacja NIP") {
            T.test("przyjmuje poprawne numery, także z separatorami i prefiksem PL") {
                T.expect(Nip.isValid("5260250274"), "5260250274 jest poprawny")
                T.expect(Nip.isValid("526-025-02-74"), "zapis z myślnikami")
                T.expect(Nip.isValid("PL5260250274"), "zapis z prefiksem PL")
                T.expect(Nip.isValid(" 526 025 02 74 "), "zapis ze spacjami")
                T.expect(Nip.isValid("7010001453"), "7010001453 jest poprawny")
            }

            T.test("odrzuca numery o błędnej sumie kontrolnej i długości") {
                T.expect(!Nip.isValid("5260250275"), "błędna cyfra kontrolna")
                T.expect(!Nip.isValid("1234567890"), "błędna suma kontrolna")
                T.expect(!Nip.isValid("526025027"), "za krótki")
                T.expect(!Nip.isValid("52602502741"), "za długi")
                T.expect(!Nip.isValid("52602502AB"), "zawiera litery")
                T.expect(!Nip.isValid(""), "pusty ciąg")
            }

            T.test("odrzuca numer, dla którego reszta z dzielenia wynosi 10") {
                // Suma ważona ≡ 10 (mod 11) nie daje poprawnej cyfry kontrolnej,
                // więc żaden wariant ostatniej cyfry nie może przejść walidacji.
                let candidate = "8888888888"
                let weights = [6, 5, 7, 2, 3, 4, 5, 6, 7]
                let digits = candidate.compactMap(\.wholeNumberValue)
                let checksum = zip(weights, digits.prefix(9)).reduce(0) { $0 + $1.0 * $1.1 } % 11
                if checksum == 10 {
                    for last in 0 ... 9 {
                        let probe = String(candidate.prefix(9)) + String(last)
                        T.expect(!Nip.isValid(probe), "\(probe) nie może być poprawny")
                    }
                }
            }

            T.test("formatuje numer do postaci czytelnej") {
                T.equal(Nip.formatted("5260250274"), "526-025-02-74", "format NIP")
                T.equal(Nip.normalize("PL 526-025-02-74"), "5260250274", "normalizacja")
            }
        }

        T.suite("Formatowanie kwot i dat") {
            T.test("formatuje kwoty po polsku ze spacją nierozdzielającą") {
                T.equal(Fmt.money(Decimal(string: "1234.56")!, currency: "PLN"),
                        "1\u{00A0}234,56\u{00A0}zł", "kwota w złotych")
                T.equal(Fmt.money(Decimal(string: "1234.56")!, currency: "EUR"),
                        "1\u{00A0}234,56\u{00A0}EUR", "kwota w euro")
                T.equal(Fmt.amount(Decimal(string: "0.5")!), "0,50", "zaokrąglenie do dwóch miejsc")
                T.equal(Fmt.amount(Decimal(string: "-246")!), "-246,00", "kwota ujemna")
                T.equal(Fmt.amount(Decimal(string: "1234567.891")!),
                        "1\u{00A0}234\u{00A0}567,89", "separator tysięcy")
            }

            T.test("parsuje kwoty z XML z kropką i przecinkiem") {
                T.equal(Decimal(ksefString: "1234.56"), Decimal(string: "1234.56"), "kropka dziesiętna")
                T.equal(Decimal(ksefString: "1234,56"), Decimal(string: "1234.56"), "przecinek dziesiętny")
                T.equal(Decimal(ksefString: "-246.00"), Decimal(string: "-246"), "wartość ujemna")
                T.isNil(Decimal(ksefString: ""), "pusty ciąg")
                T.isNil(Decimal(ksefString: "abc"), "tekst nieliczbowy")
            }

            T.test("sumuje kwoty bez błędu zmiennoprzecinkowego") {
                // Ten sam rachunek na Double daje 0.30000000000000004.
                let sum = [Decimal(string: "0.1")!, Decimal(string: "0.2")!].reduce(0, +)
                T.equal(sum, Decimal(string: "0.3")!, "0,1 + 0,2 musi dać dokładnie 0,3")

                let cents = (1 ... 100).map { _ in Decimal(string: "0.01")! }.reduce(0, +)
                T.equal(cents, Decimal(1), "sto groszy musi dać dokładnie 1,00")
            }

            T.test("formatuje daty i nazwy miesięcy") {
                let date = InvoiceParser.parseDate("2026-07-15")!
                T.equal(Fmt.isoDate(date), "2026-07-15", "data ISO")
                T.equal(Fmt.qrDate(date), "15-07-2026", "data w formacie kodu QR")
                T.equal(Fmt.monthName(month: 7, year: 2026), "lipiec 2026", "nazwa miesiąca")
                T.equal(Fmt.monthNameGenitive(month: 7, year: 2026), "lipca 2026", "nazwa miesiąca w dopełniaczu")
                T.equal(Fmt.monthTag(month: 7, year: 2026), "2026-07", "znacznik miesiąca")
            }
        }

        T.suite("Granice miesiąca rozliczeniowego") {
            T.test("wyznacza pełny zakres miesiąca w czasie letnim") {
                let july = MonthPeriod(year: 2026, month: 7)
                T.equal(july.isoFrom, "2026-07-01T00:00:00.000+02:00", "początek lipca")
                T.equal(july.isoTo, "2026-07-31T23:59:59.999+02:00", "koniec lipca")
                T.equal(july.dayCount, 31, "liczba dni w lipcu")
            }

            T.test("wyznacza zakres miesiąca w czasie zimowym") {
                let january = MonthPeriod(year: 2026, month: 1)
                T.equal(january.isoFrom, "2026-01-01T00:00:00.000+01:00", "początek stycznia")
                T.equal(january.isoTo, "2026-01-31T23:59:59.999+01:00", "koniec stycznia")
            }

            T.test("obejmuje pełny miesiąc mimo zmiany czasu") {
                // W marcu doba zmiany czasu ma 23 godziny, w październiku 25.
                // Granice miesiąca liczone kalendarzowo muszą pozostać o północy.
                let march = MonthPeriod(year: 2026, month: 3)
                T.equal(march.isoFrom, "2026-03-01T00:00:00.000+01:00", "początek marca w czasie zimowym")
                T.equal(march.isoTo, "2026-03-31T23:59:59.999+02:00", "koniec marca w czasie letnim")

                let october = MonthPeriod(year: 2026, month: 10)
                T.equal(october.isoFrom, "2026-10-01T00:00:00.000+02:00", "początek października w czasie letnim")
                T.equal(october.isoTo, "2026-10-31T23:59:59.999+01:00", "koniec października w czasie zimowym")

                // Marzec 2026 ma 31 dni, ale z powodu zmiany czasu trwa o godzinę krócej.
                let duration = march.startOfNextMonth.timeIntervalSince(march.start)
                T.equal(duration, 31 * 86400 - 3600, "czas trwania marca uwzględnia zmianę czasu")
            }

            T.test("luty roku przestępnego ma 29 dni") {
                let february = MonthPeriod(year: 2028, month: 2)
                T.equal(february.dayCount, 29, "liczba dni w lutym 2028")
                T.equal(february.isoTo, "2028-02-29T23:59:59.999+01:00", "koniec lutego 2028")
            }

            T.test("domyślnie wskazuje miesiąc poprzedni") {
                let cal = MonthPeriod.calendar
                let reference = cal.date(from: DateComponents(timeZone: Fmt.warsaw, year: 2026, month: 1, day: 15))!
                let previous = MonthPeriod.previousMonth(from: reference)
                T.equal(previous.year, 2025, "rok miesiąca poprzedniego na przełomie roku")
                T.equal(previous.month, 12, "miesiąc poprzedni na przełomie roku")
            }
        }

        T.suite("Redakcja sekretów w dzienniku") {
            T.test("usuwa nagłówek Authorization i tokeny JWT") {
                let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcDEF123"
                let text = "Authorization: Bearer \(jwt) — żądanie wysłane"
                let redacted = Log.redact(text)

                T.expect(!redacted.contains(jwt), "token JWT nie może pozostać w dzienniku")
                T.expect(!redacted.contains("eyJ"), "żaden fragment JWT nie może pozostać")
                T.expect(redacted.contains("ZREDAGOWANO"), "wpis powinien być oznaczony jako zredagowany")
            }

            T.test("usuwa zarejestrowany token KSeF w dowolnym miejscu tekstu") {
                let token = "AbCdEf1234567890TokenKSeF"
                Log.shared.registerSecret(token)
                defer { Log.shared.clearSecrets() }

                let redacted = Log.redact("Zapisano token \(token) dla kontekstu")
                T.expect(!redacted.contains(token), "zarejestrowany token nie może pozostać w tekście")
            }

            T.test("usuwa pola JSON z materiałem kryptograficznym") {
                let json = #"{"encryptedToken":"c2VrcmV0bnlDaXBoZXJUZXh0","publicKeyId":"abc"}"#
                let redacted = Log.redact(json)

                T.expect(!redacted.contains("c2VrcmV0bnlDaXBoZXJUZXh0"), "szyfrogram tokena musi zniknąć")
                T.expect(redacted.contains("publicKeyId"), "identyfikator klucza publicznego nie jest sekretem")
            }

            T.test("usuwa klucz prywatny w formacie PEM") {
                let pem = """
                -----BEGIN PRIVATE KEY-----
                MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQ
                -----END PRIVATE KEY-----
                """
                let redacted = Log.redact("Wczytano klucz:\n\(pem)")
                T.expect(!redacted.contains("MIIEvQIBADANBgkqhkiG9w0"), "materiał klucza prywatnego musi zniknąć")
            }
        }
    }
}
