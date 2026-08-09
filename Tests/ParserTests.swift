import Foundation

enum ParserTests {
    static func run() {
        T.suite("Parser FA(3)") {
            T.test("odczytuje nagłówek, strony i pozycje faktury podstawowej") {
                let invoice = try InvoiceParser.parse(
                    xml: Fixtures.data(Fixtures.fa3Standard),
                    ksefNumber: "5260250274-20260715-01ABCDEF-01",
                    direction: .issued,
                    metadata: Fixtures.metadata()
                )

                T.equal(invoice.schema, .fa3, "wersja schematu")
                T.equal(invoice.invoiceNumber, "FV/123/2026", "numer faktury")
                T.equal(invoice.kind, .vat, "rodzaj dokumentu")
                T.equal(invoice.currency, "PLN", "waluta")
                T.equal(invoice.issuePlace, "Warszawa", "miejsce wystawienia")
                T.equal(Fmt.isoDate(invoice.issueDate!), "2026-07-15", "data wystawienia")
                T.equal(Fmt.isoDate(invoice.saleDate!), "2026-07-14", "data sprzedaży")

                T.equal(invoice.seller.nip, "5260250274", "NIP sprzedawcy")
                T.equal(invoice.seller.name, "Przykładowa Spółka z o.o.", "nazwa sprzedawcy")
                T.equal(invoice.seller.address.line1, "Świętokrzyska 12/34", "adres sprzedawcy — wiersz 1")
                T.equal(invoice.seller.address.line2, "00-916 Warszawa", "adres sprzedawcy — wiersz 2")
                T.equal(invoice.seller.email, "biuro@przyklad.pl", "e-mail sprzedawcy")
                T.equal(invoice.buyer.nip, "7010001453", "NIP nabywcy")
                T.equal(invoice.buyer.name, "Nabywca Ćwiczebny S.A.", "nazwa nabywcy")

                T.equal(invoice.lines.count, 3, "liczba pozycji")
                T.equal(invoice.lines[0].name, "Usługa doradcza — analiza wdrożenia", "nazwa pozycji 1")
                T.equal(invoice.lines[0].quantity, 10, "ilość pozycji 1")
                T.equal(invoice.lines[0].unit, "godz.", "jednostka pozycji 1")
                T.equal(invoice.lines[0].vatRate, "23%", "stawka pozycji 1")
                T.equal(invoice.lines[0].net, Decimal(string: "600.00"), "netto pozycji 1")
                T.equal(invoice.lines[0].gtu, ["GTU_12"], "GTU pozycji 1")
            }

            T.test("nie nadpisuje kwot wystawcy, a wyliczone oznacza") {
                let invoice = try InvoiceParser.parse(
                    xml: Fixtures.data(Fixtures.fa3Standard),
                    ksefNumber: "X", direction: .issued
                )

                // Pozycje 1 i 2 mają P_11Vat zapisane przez wystawcę — muszą zostać nietknięte.
                T.equal(invoice.lines[0].vat, Decimal(string: "138.00"), "VAT pozycji 1 z XML")
                T.expect(!invoice.lines[0].computed.contains(.vat), "VAT pozycji 1 nie może być oznaczony jako wyliczony")

                // Pozycja 3 nie ma P_11Vat ani P_11A — obie wartości wylicza aplikacja.
                T.equal(invoice.lines[2].vat, Decimal(string: "40.00"), "VAT pozycji 3 wyliczony ze stawki 8%")
                T.expect(invoice.lines[2].computed.contains(.vat), "VAT pozycji 3 oznaczony jako wyliczony")
                T.equal(invoice.lines[2].gross, Decimal(string: "540.00"), "brutto pozycji 3 wyliczone")
                T.expect(invoice.lines[2].computed.contains(.gross), "brutto pozycji 3 oznaczone jako wyliczone")
                T.expect(invoice.hasComputedAmounts, "faktura powinna zgłaszać obecność kwot wyliczonych")
            }

            T.test("buduje podsumowanie w rozbiciu na stawki VAT") {
                let invoice = try InvoiceParser.parse(
                    xml: Fixtures.data(Fixtures.fa3Standard), ksefNumber: "X", direction: .issued
                )

                T.equal(invoice.vatSummary.count, 2, "liczba stawek w podsumowaniu")
                T.equal(invoice.vatSummary[0].rateLabel, "23%", "etykieta pierwszej stawki")
                T.equal(invoice.vatSummary[0].net, Decimal(string: "1000.00"), "netto 23%")
                T.equal(invoice.vatSummary[0].vat, Decimal(string: "230.00"), "VAT 23%")
                T.equal(invoice.vatSummary[1].rateLabel, "8%", "etykieta drugiej stawki")
                T.equal(invoice.vatSummary[1].net, Decimal(string: "500.00"), "netto 8%")

                T.equal(invoice.totalNet, Decimal(string: "1500.00"), "razem netto")
                T.equal(invoice.totalVat, Decimal(string: "270.00"), "razem VAT")
                // Brutto pochodzi z P_15 zapisanego przez wystawcę, nie z sumy.
                T.equal(invoice.totalGross, Decimal(string: "1770.00"), "razem brutto z pola P_15")
            }

            T.test("odczytuje adnotacje, płatność i rachunek bankowy") {
                let invoice = try InvoiceParser.parse(
                    xml: Fixtures.data(Fixtures.fa3Standard), ksefNumber: "X", direction: .issued
                )

                T.expect(invoice.annotations.splitPayment, "MPP powinien być rozpoznany (P_18A = 2)")
                T.expect(!invoice.annotations.cashMethod, "metoda kasowa nie występuje (P_16 = 1)")
                T.expect(!invoice.annotations.selfInvoicing, "samofakturowanie nie występuje")
                T.expect(!invoice.annotations.reverseCharge, "odwrotne obciążenie nie występuje")
                T.expect(!invoice.annotations.exemption, "zwolnienie nie występuje (P_19N)")
                T.expect(!invoice.annotations.marginProcedure, "procedura marży nie występuje (P_PMarzyN)")
                T.equal(invoice.annotations.printable, ["mechanizm podzielonej płatności"], "adnotacje do wydruku")

                T.equal(invoice.paymentForm, "przelew", "forma płatności")
                T.equal(Fmt.isoDate(invoice.paymentDueDate!), "2026-07-29", "termin płatności")
                T.expect(invoice.isPaid, "faktura oznaczona jako zapłacona")
                T.equal(invoice.bankAccounts.count, 1, "liczba rachunków")
                T.equal(invoice.bankAccounts[0].number, "61109010140000071219812874", "numer rachunku")
            }

            T.test("obsługuje korektę z kwotami ujemnymi") {
                let invoice = try InvoiceParser.parse(
                    xml: Fixtures.data(Fixtures.fa3Correction), ksefNumber: "Y", direction: .issued
                )

                T.equal(invoice.kind, .korekta, "rodzaj dokumentu")
                T.expect(invoice.isCorrection, "faktura powinna być rozpoznana jako korygująca")
                T.equal(invoice.totalNet, Decimal(string: "-200.00"), "netto korekty")
                T.equal(invoice.totalVat, Decimal(string: "-46.00"), "VAT korekty")
                T.equal(invoice.totalGross, Decimal(string: "-246.00"), "brutto korekty")

                T.notNil(invoice.correction, "dane korekty")
                T.equal(invoice.correction?.reason, "Zwrot części towaru", "przyczyna korekty")
                T.equal(invoice.correction?.correctedInvoiceNumber, "FV/123/2026", "numer faktury korygowanej")
                T.equal(invoice.correction?.correctedKsefNumber,
                        "5260250274-20260715-01ABCDEF-01", "numer KSeF faktury korygowanej")
                T.equal(invoice.correction?.correctionType, "1", "typ korekty")
            }

            T.test("uzupełnia netto i VAT dla faktury w konwencji brutto") {
                // Wystawca podał w pozycjach wyłącznie wartość brutto (P_11A).
                let invoice = try InvoiceParser.parse(
                    xml: Fixtures.data(Fixtures.fa3GrossOnly), ksefNumber: "G", direction: .received
                )

                T.equal(invoice.lines.count, 2, "liczba pozycji")

                // 160,65 / 1,23 = 130,61 → VAT 30,04
                T.equal(invoice.lines[0].gross, Decimal(string: "160.65"), "brutto pozycji 1 z XML")
                T.equal(invoice.lines[0].net, Decimal(string: "130.61"), "netto pozycji 1 wyliczone „w stu”")
                T.equal(invoice.lines[0].vat, Decimal(string: "30.04"), "VAT pozycji 1 jako różnica")
                T.equal(invoice.lines[0].unitNetPrice, Decimal(string: "130.61"), "cena jednostkowa netto")
                T.expect(invoice.lines[0].computed.contains(.net), "netto musi być oznaczone jako wyliczone")
                T.expect(invoice.lines[0].computed.contains(.vat), "VAT musi być oznaczony jako wyliczony")
                T.expect(!invoice.lines[0].computed.contains(.gross),
                         "brutto pochodzi od wystawcy i nie może być oznaczone gwiazdką")

                // 194,65 / 1,23 = 158,25 → VAT 36,40
                T.equal(invoice.lines[1].net, Decimal(string: "158.25"), "netto pozycji 2")
                T.equal(invoice.lines[1].vat, Decimal(string: "36.40"), "VAT pozycji 2")

                // Najmocniejszy sprawdzian: suma wartości wyliczonych musi zgadzać się co do grosza
                // z podsumowaniem stawek zadeklarowanym przez wystawcę.
                let netSum = invoice.lines.compactMap(\.net).reduce(0, +)
                let vatSum = invoice.lines.compactMap(\.vat).reduce(0, +)
                T.equal(netSum, Decimal(string: "288.86"), "suma netto pozycji musi odpowiadać polu P_13_1")
                T.equal(vatSum, Decimal(string: "66.44"), "suma VAT pozycji musi odpowiadać polu P_14_1")

                // Sumy faktury nadal pochodzą z pól wystawcy, nie z pozycji.
                T.equal(invoice.totalNet, Decimal(string: "288.86"), "razem netto z P_13_1")
                T.equal(invoice.totalVat, Decimal(string: "66.44"), "razem VAT z P_14_1")
                T.equal(invoice.totalGross, Decimal(string: "355.30"), "razem brutto z P_15")

                // Netto i VAT każdej pozycji muszą składać się dokładnie na jej brutto.
                for line in invoice.lines {
                    T.equal((line.net ?? 0) + (line.vat ?? 0), line.gross,
                            "netto + VAT pozycji \(line.index) musi dać wartość brutto")
                }
            }

            T.test("odczytuje walutę obcą, kurs i VAT w złotych") {
                let invoice = try InvoiceParser.parse(
                    xml: Fixtures.data(Fixtures.fa3ForeignCurrency), ksefNumber: "Z", direction: .issued
                )

                T.equal(invoice.currency, "EUR", "waluta")
                T.equal(invoice.exchangeRate, Decimal(string: "4.3000"), "kurs przeliczeniowy")
                T.equal(invoice.vatSummary.first?.vatInPLN, Decimal(string: "989.00"), "VAT w złotych (P_14_1W)")
                T.equal(invoice.totalGross, Decimal(string: "1230.00"), "brutto w EUR")
            }
        }

        T.suite("Parser FA(2) i PEF") {
            T.test("odczytuje fakturę w starszym wzorze FA(2)") {
                let invoice = try InvoiceParser.parse(
                    xml: Fixtures.data(Fixtures.fa2Standard), ksefNumber: "A", direction: .received
                )

                T.equal(invoice.schema, .fa2, "wersja schematu")
                T.equal(invoice.invoiceNumber, "FA/2024/03/11", "numer faktury")
                T.equal(invoice.totalNet, Decimal(string: "2000.00"), "razem netto")
                T.equal(invoice.totalGross, Decimal(string: "2460.00"), "razem brutto")
                T.equal(invoice.lines.count, 1, "liczba pozycji")
                T.equal(invoice.direction, .received, "kierunek faktury")
            }

            T.test("odczytuje fakturę PEF w formacie UBL") {
                let invoice = try InvoiceParser.parse(
                    xml: Fixtures.data(Fixtures.pefUBL), ksefNumber: "B", direction: .received
                )

                T.equal(invoice.schema, .pef, "wersja schematu")
                T.equal(invoice.invoiceNumber, "PEF/2026/07/55", "numer faktury")
                T.equal(invoice.seller.name, "Dostawca Publiczny sp. z o.o.", "nazwa sprzedawcy")
                T.equal(invoice.seller.nip, "5260250274", "NIP sprzedawcy z prefiksem PL")
                T.equal(invoice.buyer.name, "Urząd Miasta", "nazwa nabywcy")
                T.equal(invoice.totalNet, Decimal(string: "1000.00"), "razem netto")
                T.equal(invoice.totalVat, Decimal(string: "230.00"), "razem VAT")
                T.equal(invoice.totalGross, Decimal(string: "1230.00"), "razem brutto")
                T.equal(invoice.lines.count, 1, "liczba pozycji")
                T.equal(invoice.lines[0].unit, "H87", "jednostka miary z atrybutu unitCode")
                T.equal(Fmt.isoDate(invoice.paymentDueDate!), "2026-08-05", "termin płatności")
            }

            T.test("odrzuca dokument o nieobsługiwanej strukturze") {
                T.throwsError("nieznany dokument") {
                    _ = try InvoiceParser.parse(
                        xml: Data("<?xml version=\"1.0\"?><CosInnego><A>1</A></CosInnego>".utf8),
                        ksefNumber: "C", direction: .issued
                    )
                }
            }
        }

        T.suite("Parser — dane uzupełniające") {
            T.test("uzupełnia dane z metadanych i liczy skrót faktury") {
                let xml = Fixtures.data(Fixtures.fa3Standard)
                let invoice = try InvoiceParser.parse(
                    xml: xml, ksefNumber: "5260250274-20260715-01ABCDEF-01",
                    direction: .issued, metadata: Fixtures.metadata()
                )

                T.equal(invoice.ksefNumber, "5260250274-20260715-01ABCDEF-01", "numer KSeF")
                T.notNil(invoice.acquisitionDate, "data nadania numeru KSeF z metadanych")
                // Metadane nie niosły skrótu, więc liczymy go z dokumentu źródłowego.
                T.equal(invoice.invoiceHashBase64, Crypto.sha256Base64(xml), "skrót SHA-256 faktury")
                T.equal(invoice.rawXML, xml, "zachowany oryginalny XML")
            }

            T.test("spłaszcza dokument do listy pól dla podglądu") {
                let root = try XmlTreeBuilder.parse(Fixtures.data(Fixtures.fa3Standard))
                let fields = root.flattened()

                T.expect(fields.contains { $0.path.hasSuffix("P_2") && $0.value == "FV/123/2026" },
                         "lista pól powinna zawierać numer faktury")
                // Powtarzające się elementy muszą mieć rozróżnialne ścieżki.
                T.expect(fields.contains { $0.path.contains("FaWiersz [3]") },
                         "trzecia pozycja powinna mieć własną ścieżkę")
            }
        }
    }
}
