import Foundation
import PDFKit

enum PdfTests {
    private static func parse(_ xml: String, ksefNumber: String = "5260250274-20260715-01ABCDEF-01") throws -> Invoice {
        try InvoiceParser.parse(xml: Data(xml.utf8), ksefNumber: ksefNumber,
                                direction: .issued, metadata: Fixtures.metadata())
    }

    private static func textOf(_ document: PDFDocument) -> String {
        (0 ..< document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
    }

    static func run() {
        T.suite("Generowanie PDF") {
            T.test("zawiera elementy wymagane art. 106e ustawy o VAT") {
                let invoice = try parse(Fixtures.fa3Standard)
                guard let document = PDFDocument(data: PdfRenderer.render(invoice)) else {
                    T.fail("nie udało się otworzyć wygenerowanego dokumentu PDF")
                    return
                }
                let text = textOf(document)

                let required: [(String, String)] = [
                    ("data wystawienia", "2026-07-15"),
                    ("numer faktury", "FV/123/2026"),
                    ("nazwa sprzedawcy", "Przykładowa Spółka z o.o."),
                    ("NIP sprzedawcy", "526-025-02-74"),
                    ("adres sprzedawcy", "Świętokrzyska 12/34"),
                    ("nazwa nabywcy", "Nabywca Ćwiczebny S.A."),
                    ("NIP nabywcy", "701-000-14-53"),
                    ("data sprzedaży", "2026-07-14"),
                    ("nazwa towaru lub usługi", "Usługa doradcza"),
                    ("jednostka miary", "godz."),
                    ("stawka podatku", "23%"),
                    ("wartość sprzedaży netto", "1 500,00"),
                    ("kwota podatku", "270,00"),
                    ("kwota należności ogółem", "1 770,00"),
                    ("oznaczenie sprzedawcy", "SPRZEDAWCA"),
                    ("oznaczenie nabywcy", "NABYWCA"),
                ]
                for (label, value) in required {
                    T.expect(text.contains(value), "PDF musi zawierać \(label) („\(value)")
                }
            }

            T.test("poprawnie renderuje polskie znaki diakrytyczne") {
                let invoice = try parse(Fixtures.fa3Standard)
                guard let document = PDFDocument(data: PdfRenderer.render(invoice)) else { return }
                let text = textOf(document)

                for fragment in ["Świętokrzyska", "Ćwiczebny", "Usługa", "Materiały szkoleniowe (książki)",
                                 "Żurawia", "Płatność", "Adnotacje", "wizualizację"] {
                    T.expect(text.contains(fragment), "PDF musi poprawnie renderować „\(fragment)")
                }
                // Znak zastępczy pojawia się, gdy czcionka nie ma potrzebnego glifu.
                T.expect(!text.contains("\u{FFFD}"), "PDF nie może zawierać znaków zastępczych")
            }

            T.test("oznacza numer KSeF i charakter dokumentu") {
                let invoice = try parse(Fixtures.fa3Standard)
                guard let document = PDFDocument(data: PdfRenderer.render(invoice)) else { return }
                let text = textOf(document)

                T.expect(text.contains("5260250274-20260715-01ABCDEF-01"), "PDF musi zawierać numer KSeF")
                T.expect(text.contains("wizualizację") && text.contains("nie jest oryginałem"),
                         "PDF musi informować, że stanowi wizualizację, a nie oryginał faktury")
                T.expect(text.contains("Krajowym Systemie e-Faktur"),
                         "PDF musi wskazywać dokument źródłowy w KSeF")
            }

            T.test("oznacza gwiazdką kwoty wyliczone przez aplikację") {
                let invoice = try parse(Fixtures.fa3Standard)
                guard let document = PDFDocument(data: PdfRenderer.render(invoice)) else { return }
                let text = textOf(document)

                T.expect(text.contains("40,00*"), "wyliczona kwota VAT musi być oznaczona gwiazdką")
                T.expect(text.contains("Wartość wyliczona przez aplikację"),
                         "PDF musi wyjaśniać znaczenie gwiazdki")
            }

            T.test("dzieli długą fakturę na strony bez gubienia pozycji") {
                let lineCount = 60
                let invoice = try parse(Fixtures.fa3WithManyLines(lineCount))
                T.equal(invoice.lines.count, lineCount, "liczba pozycji odczytanych z XML")

                guard let document = PDFDocument(data: PdfRenderer.render(invoice)) else {
                    T.fail("nie udało się otworzyć dokumentu")
                    return
                }
                T.expect(document.pageCount > 1, "60 pozycji nie mieści się na jednej stronie A4")

                let text = textOf(document)
                // Każda pozycja musi znaleźć się w dokumencie dokładnie raz.
                for index in 1 ... lineCount {
                    let marker = "Pozycja testowa numer \(index) "
                    let occurrences = text.components(separatedBy: marker).count - 1
                    T.equal(occurrences, 1, "pozycja \(index) musi wystąpić dokładnie raz")
                }

                // Kolejność pozycji nie może się zmienić przy podziale na strony.
                var lastLocation: String.Index?
                var orderPreserved = true
                for index in 1 ... lineCount {
                    guard let range = text.range(of: "Pozycja testowa numer \(index) ") else {
                        orderPreserved = false
                        break
                    }
                    if let lastLocation, range.lowerBound < lastLocation { orderPreserved = false; break }
                    lastLocation = range.lowerBound
                }
                T.expect(orderPreserved, "kolejność pozycji musi zostać zachowana między stronami")
            }

            T.test("powtarza nagłówek tabeli i numeruje strony") {
                let invoice = try parse(Fixtures.fa3WithManyLines(60))
                guard let document = PDFDocument(data: PdfRenderer.render(invoice)) else { return }
                let pages = document.pageCount

                for index in 0 ..< pages {
                    guard let page = document.page(at: index)?.string else { continue }
                    T.expect(page.contains("Strona \(index + 1) z \(pages)"),
                             "strona \(index + 1) musi mieć numerację „Strona \(index + 1) z \(pages)")
                }

                // Nagłówek tabeli powtarza się na każdej stronie z pozycjami.
                let headerOccurrences = textOf(document)
                    .components(separatedBy: "Nazwa towaru lub usługi").count - 1
                T.expect(headerOccurrences >= pages - 1,
                         "nagłówek tabeli musi się powtarzać na kolejnych stronach (znaleziono \(headerOccurrences))")

                // Kontynuacja jest oznaczona, żeby strony nie wyglądały na osobne dokumenty.
                if pages > 1, let second = document.page(at: 1)?.string {
                    T.expect(second.contains("ciąg dalszy"), "kolejne strony muszą być oznaczone jako kontynuacja")
                }
            }

            T.test("zapisuje metadane dokumentu") {
                let invoice = try parse(Fixtures.fa3Standard)
                guard let document = PDFDocument(data: PdfRenderer.render(invoice)) else { return }
                let attributes = document.documentAttributes ?? [:]

                T.equal(attributes[PDFDocumentAttribute.titleAttribute] as? String, "FV/123/2026",
                        "tytuł dokumentu to numer faktury")
                T.equal(attributes[PDFDocumentAttribute.subjectAttribute] as? String,
                        "5260250274-20260715-01ABCDEF-01", "temat dokumentu to numer KSeF")
                T.equal(attributes[PDFDocumentAttribute.authorAttribute] as? String,
                        "Przykładowa Spółka z o.o.", "autor dokumentu to wystawca")
            }

            T.test("prezentuje korektę wraz z danymi faktury korygowanej") {
                let invoice = try InvoiceParser.parse(xml: Data(Fixtures.fa3Correction.utf8),
                                                      ksefNumber: "5260250274-20260728-0BADC0DE-01",
                                                      direction: .issued)
                guard let document = PDFDocument(data: PdfRenderer.render(invoice)) else { return }
                let text = textOf(document)

                T.expect(text.contains("Faktura korygująca"), "PDF musi nazywać dokument fakturą korygującą")
                T.expect(text.contains("Zwrot części towaru"), "PDF musi podawać przyczynę korekty")
                T.expect(text.contains("FV/123/2026"), "PDF musi wskazywać fakturę korygowaną")
                T.expect(text.contains("-246,00"), "PDF musi pokazywać kwotę ujemną korekty")
            }

            T.test("pokazuje walutę obcą wraz z kursem") {
                let invoice = try parse(Fixtures.fa3ForeignCurrency)
                guard let document = PDFDocument(data: PdfRenderer.render(invoice)) else { return }
                let text = textOf(document)

                T.expect(text.contains("EUR"), "PDF musi podawać walutę faktury")
                T.expect(text.contains("4,3"), "PDF musi podawać kurs przeliczeniowy")
                T.expect(text.contains("989,00"), "PDF musi podawać kwotę VAT w złotych")
            }

            T.test("zachowuje format A4 pionowo") {
                let invoice = try parse(Fixtures.fa3Standard)
                guard let document = PDFDocument(data: PdfRenderer.render(invoice)),
                      let page = document.page(at: 0) else { return }
                let bounds = page.bounds(for: .mediaBox)

                T.expect(abs(bounds.width - 595.276) < 1, "szerokość strony A4 (otrzymano \(bounds.width))")
                T.expect(abs(bounds.height - 841.89) < 1, "wysokość strony A4 (otrzymano \(bounds.height))")
                T.expect(bounds.height > bounds.width, "orientacja pionowa")
            }
        }

        T.suite("Nazwy plików") {
            T.test("buduje deterministyczną nazwę pliku PDF") {
                let invoice = try parse(Fixtures.fa3Standard)
                let period = MonthPeriod(year: 2026, month: 7)
                let name = Storage.pdfFileName(for: invoice, period: period)

                T.equal(name, "WYSTAWIONE_2026-07_FV-123-2026_NABYWCA-CWICZEBNY-S-A_1770PLN.pdf",
                        "nazwa pliku faktury wystawionej")
                T.expect(!name.contains("/"), "nazwa nie może zawierać ukośników")
                T.expect(name.allSatisfy(\.isASCII), "nazwa musi składać się ze znaków ASCII")

                // Ta sama faktura zawsze daje tę samą nazwę.
                T.equal(Storage.pdfFileName(for: invoice, period: period), name, "nazwa musi być powtarzalna")
            }

            T.test("zamienia polskie znaki na odpowiedniki ASCII") {
                T.equal(Storage.transliterate("Zażółć gęślą jaźń"), "Zazolc gesla jazn", "transliteracja")
                T.equal(Storage.slug("Przykładowa Spółka z o.o.", uppercase: true),
                        "PRZYKLADOWA-SPOLKA-Z-O-O", "fragment nazwy pliku")
                T.equal(Storage.slug("FV/123/2026"), "FV-123-2026", "numer faktury w nazwie pliku")
            }
        }
    }
}
