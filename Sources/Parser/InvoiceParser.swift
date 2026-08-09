import Foundation

/// Parser faktur ustrukturyzowanych KSeF.
///
/// Obsługuje FA(3) i FA(2) (wraz z korektami, fakturami zaliczkowymi i rozliczeniowymi)
/// oraz — w zakresie danych potrzebnych do rozliczenia — faktury PEF w formacie UBL.
enum InvoiceParser {
    enum ParserError: LocalizedError {
        case unsupportedSchema(String)

        var errorDescription: String? {
            switch self {
            case let .unsupportedSchema(root):
                return "Nieobsługiwany format dokumentu faktury (element główny: \(root))."
            }
        }
    }

    /// Podsumowanie VAT: kolejność, pola źródłowe i etykieta stawki.
    /// Odwzorowuje sekcję `Fa` schematu FA — pole netto, pole podatku i pole podatku w złotych.
    private struct VatBucket {
        let order: Int
        let net: String
        let vat: String?
        let vatPLN: String?
        let label: String
    }

    private static let vatBuckets: [VatBucket] = [
        .init(order: 1, net: "P_13_1", vat: "P_14_1", vatPLN: "P_14_1W", label: "23%"),
        .init(order: 2, net: "P_13_2", vat: "P_14_2", vatPLN: "P_14_2W", label: "8%"),
        .init(order: 3, net: "P_13_3", vat: "P_14_3", vatPLN: "P_14_3W", label: "5%"),
        .init(order: 4, net: "P_13_4", vat: "P_14_4", vatPLN: "P_14_4W", label: "4% (ryczałt — taksówki)"),
        .init(order: 5, net: "P_13_5", vat: "P_14_5", vatPLN: nil, label: "proc. szczególna (dz. XII rozdz. 6a)"),
        .init(order: 6, net: "P_13_6_1", vat: nil, vatPLN: nil, label: "0% (krajowa)"),
        .init(order: 7, net: "P_13_6_2", vat: nil, vatPLN: nil, label: "0% (WDT)"),
        .init(order: 8, net: "P_13_6_3", vat: nil, vatPLN: nil, label: "0% (eksport)"),
        .init(order: 9, net: "P_13_7", vat: nil, vatPLN: nil, label: "zw."),
        .init(order: 10, net: "P_13_8", vat: nil, vatPLN: nil, label: "np. (poza terytorium kraju)"),
        .init(order: 11, net: "P_13_9", vat: nil, vatPLN: nil, label: "np. (art. 100 ust. 1 pkt 4)"),
        .init(order: 12, net: "P_13_10", vat: nil, vatPLN: nil, label: "odwrotne obciążenie"),
        .init(order: 13, net: "P_13_11", vat: nil, vatPLN: nil, label: "procedura marży"),
    ]

    // MARK: - Wejście

    static func parse(
        xml: Data,
        ksefNumber: String,
        direction: InvoiceDirection,
        metadata: InvoiceMetadata? = nil
    ) throws -> Invoice {
        let root = try XmlTreeBuilder.parse(xml)
        let schema = InvoiceSchema.detect(namespaceURI: root.namespaceURI, rootName: root.name)

        var invoice: Invoice
        switch schema {
        case .fa3, .fa2, .faRR:
            invoice = parseFA(root: root, schema: schema)
        case .pef:
            invoice = parseUBL(root: root)
        case .unknown:
            // Nieznana przestrzeń nazw — rozpoznajemy dokument po kształcie drzewa,
            // żeby nowszy wzór FA nadal dał się odczytać.
            if root.child("Fa") != nil {
                invoice = parseFA(root: root, schema: .fa3)
            } else if root.name == "Invoice" || root.name == "CreditNote" {
                invoice = parseUBL(root: root)
            } else {
                throw ParserError.unsupportedSchema(root.name)
            }
        }

        invoice.ksefNumber = ksefNumber
        invoice.direction = direction
        invoice.schema = schema
        invoice.rawXML = xml

        // Metadane KSeF uzupełniają dane, których nie ma w samym dokumencie.
        if let metadata {
            invoice.acquisitionDate = metadata.acquisitionDate
            invoice.permanentStorageDate = metadata.permanentStorageDate
            invoice.invoiceHashBase64 = metadata.invoiceHash
            invoice.hasAttachment = metadata.hasAttachment ?? false
            if invoice.invoiceNumber.isEmpty { invoice.invoiceNumber = metadata.invoiceNumber }
            if invoice.seller.name == nil { invoice.seller.name = metadata.seller?.name }
            if invoice.seller.nip == nil { invoice.seller.nip = metadata.seller?.nip }
            if invoice.buyer.name == nil { invoice.buyer.name = metadata.buyer?.name }
        }
        // Bez skrótu z metadanych liczymy go z dokumentu — jest potrzebny do kodu QR.
        if invoice.invoiceHashBase64 == nil {
            invoice.invoiceHashBase64 = Crypto.sha256Base64(xml)
        }

        return invoice
    }

    // MARK: - FA(2) / FA(3)

    private static func parseFA(root: XmlNode, schema: InvoiceSchema) -> Invoice {
        var invoice = Invoice(ksefNumber: "", invoiceNumber: "")
        let fa = root.child("Fa") ?? root

        invoice.currency = fa.string("KodWaluty") ?? "PLN"
        invoice.invoiceNumber = fa.string("P_2") ?? ""
        invoice.issueDate = parseDate(fa.string("P_1"))
        invoice.issuePlace = fa.string("P_1M")
        invoice.saleDate = parseDate(fa.string("P_6"))
        invoice.kind = InvoiceKind.from(fa.string("RodzajFaktury"))

        // Okres, gdy faktura dokumentuje sprzedaż ciągłą zamiast pojedynczej dostawy.
        if invoice.saleDate == nil, let okres = fa.child("OkresFa") {
            let from = okres.string("P_6_Od")
            let to = okres.string("P_6_Do")
            if let from, let to {
                invoice.additionalDescription.append("Okres, którego dotyczy faktura: \(from) – \(to)")
            }
            invoice.saleDate = parseDate(to ?? from)
        }

        invoice.seller = parseParty(root.child("Podmiot1"))
        invoice.buyer = parseParty(root.child("Podmiot2"))
        if let clientNumber = root.child("Podmiot2")?.string("NrKlienta") {
            invoice.buyer.otherIdentifier = invoice.buyer.otherIdentifier ?? clientNumber
        }

        invoice.vatSummary = parseVatSummary(fa: fa, currency: invoice.currency)
        invoice.lines = parseLines(fa: fa)

        // Sumy: netto i VAT z podsumowania stawek, brutto z pola P_15 zapisanego przez wystawcę.
        invoice.totalNet = invoice.vatSummary.reduce(0) { $0 + $1.net }
        invoice.totalVat = invoice.vatSummary.reduce(0) { $0 + $1.vat }

        if let declaredGross = fa.decimal("P_15") {
            invoice.totalGross = declaredGross
        } else {
            invoice.totalGross = invoice.totalNet + invoice.totalVat
        }

        // Gdy wystawca nie wypełnił podsumowania stawek, sumy odtwarzamy z pozycji.
        if invoice.vatSummary.isEmpty, !invoice.lines.isEmpty {
            let net = invoice.lines.compactMap(\.net).reduce(0, +)
            let vat = invoice.lines.compactMap(\.vat).reduce(0, +)
            invoice.totalNet = net
            invoice.totalVat = vat
            if fa.decimal("P_15") == nil { invoice.totalGross = net + vat }
        }

        invoice.exchangeRate = fa.decimal("KursWalutyZ")
            ?? fa.decimal("KursWalutyZK")
            ?? fa.decimal("KursWalutyZW")

        parseAnnotations(fa: fa, into: &invoice)
        parseCorrection(fa: fa, into: &invoice)
        parsePayment(fa: fa, into: &invoice)

        // Rozliczenie: obciążenia i odliczenia zmieniają kwotę do zapłaty.
        if let rozliczenie = fa.child("Rozliczenie") {
            invoice.amountDue = rozliczenie.decimal("DoZaplaty") ?? invoice.amountDue
            if let sumaObciazen = rozliczenie.decimal("SumaObciazen"), sumaObciazen != 0 {
                invoice.additionalDescription.append(
                    "Suma obciążeń dodatkowych: \(Fmt.money(sumaObciazen, currency: invoice.currency))")
            }
            if let sumaOdliczen = rozliczenie.decimal("SumaOdliczen"), sumaOdliczen != 0 {
                invoice.additionalDescription.append(
                    "Suma odliczeń: \(Fmt.money(sumaOdliczen, currency: invoice.currency))")
            }
        }
        if invoice.amountDue == nil { invoice.amountDue = invoice.totalGross }

        for opis in fa.all("DodatkowyOpis") {
            let key = opis.string("Klucz")
            let value = opis.string("Wartosc")
            if let value {
                invoice.additionalDescription.append(key.map { "\($0): \(value)" } ?? value)
            }
        }

        return invoice
    }

    // MARK: - Strony transakcji

    private static func parseParty(_ node: XmlNode?) -> Party {
        var party = Party()
        guard let node else { return party }

        let identity = node.child("DaneIdentyfikacyjne")
        party.nip = identity?.string("NIP")
        party.name = identity?.string("Nazwa")
            ?? identity?.string("PelnaNazwa")
            ?? identity?.string("NazwaHandlowa")
        party.regon = identity?.string("REGON")

        // Osoba fizyczna zamiast podmiotu — składamy imię i nazwisko.
        if party.name == nil, let identity {
            let first = identity.string("ImiePierwsze")
            let last = identity.string("Nazwisko")
            let joined = [first, last].compactMap { $0 }.joined(separator: " ")
            if !joined.isEmpty { party.name = joined }
        }

        // Identyfikatory nabywcy spoza Polski.
        if let idNabywcy = node.child("IDNabywcy") {
            party.vatUE = idNabywcy.string("NrVatUE") ?? idNabywcy.string("KodUE")
            party.otherIdentifier = idNabywcy.string("NrID") ?? idNabywcy.string("IDWew")
        }
        if party.vatUE == nil {
            party.vatUE = identity?.string("NrVatUE")
        }
        if party.otherIdentifier == nil {
            party.otherIdentifier = identity?.string("NrID") ?? identity?.string("BrakID")
        }

        party.address = parseAddress(node.child("Adres"))
        if let contact = node.child("DaneKontaktowe") {
            party.email = contact.string("Email")
            party.phone = contact.string("Telefon")
        }
        return party
    }

    private static func parseAddress(_ node: XmlNode?) -> Address {
        var address = Address()
        guard let node else { return address }

        // Schemat dopuszcza adres polski albo zagraniczny; oba mają te same nazwy pól.
        let source = node.child("AdresPol") ?? node.child("AdresZagr") ?? node

        address.countryCode = source.string("KodKraju")
        address.province = source.string("Wojewodztwo")
        address.district = source.string("Powiat")
        address.commune = source.string("Gmina")
        address.street = source.string("Ulica")
        address.buildingNumber = source.string("NrDomu")
        address.unitNumber = source.string("NrLokalu")
        address.city = source.string("Miejscowosc")
        address.postalCode = source.string("KodPocztowy")
        address.postOffice = source.string("Poczta")
        address.freeform = source.string("AdresL1")
            .map { line1 in [line1, source.string("AdresL2")].compactMap { $0 }.joined(separator: ", ") }
        return address
    }

    // MARK: - Podsumowanie VAT

    private static func parseVatSummary(fa: XmlNode, currency: String) -> [VatSummaryRow] {
        var rows: [VatSummaryRow] = []

        for bucket in vatBuckets {
            let net = fa.decimal(bucket.net)
            let vat = bucket.vat.flatMap { fa.decimal($0) }
            let vatPLN = bucket.vatPLN.flatMap { fa.decimal($0) }

            // Pomijamy stawki, których wystawca w ogóle nie wykazał.
            guard net != nil || vat != nil else { continue }
            let netValue = net ?? 0
            let vatValue = vat ?? 0
            if netValue == 0, vatValue == 0 { continue }

            rows.append(VatSummaryRow(
                order: bucket.order,
                rateLabel: bucket.label,
                net: netValue,
                vat: vatValue,
                vatInPLN: vatPLN
            ))
        }
        return rows.sorted { $0.order < $1.order }
    }

    // MARK: - Pozycje

    private static func parseLines(fa: XmlNode) -> [InvoiceLine] {
        var lines: [InvoiceLine] = []

        for (offset, node) in fa.all("FaWiersz").enumerated() {
            var line = InvoiceLine(index: Int(node.string("NrWierszaFa") ?? "") ?? (offset + 1))
            line.name = node.string("P_7")
            line.unit = node.string("P_8A")
            line.quantity = node.decimal("P_8B")
            line.unitNetPrice = node.decimal("P_9A")
            line.unitGrossPrice = node.decimal("P_9B")
            line.discount = node.decimal("P_10")
            line.vatRate = normalizeVatRate(node.string("P_12"))
            line.net = node.decimal("P_11")
            line.vat = node.decimal("P_11Vat")
            line.gross = node.decimal("P_11A")
            line.indeks = node.string("Indeks")
            line.pkwiu = node.string("PKWiU")
            line.cn = node.string("CN")
            line.gtin = node.string("GTIN")
            line.exciseAmount = node.decimal("KwotaAkcyzy")
            line.gtu = node.all("GTU").compactMap { $0.trimmedText.isEmpty ? nil : $0.trimmedText }
            line.procedures = node.all("Procedura").compactMap { $0.trimmedText.isEmpty ? nil : $0.trimmedText }

            fillComputedAmounts(&line)
            lines.append(line)
        }

        return lines.sorted { $0.index < $1.index }
    }

    /// Uzupełnia brakujące kwoty pozycji, nigdy nie nadpisując wartości podanych przez wystawcę.
    /// Każde uzupełnienie jest odnotowane, żeby PDF mógł oznaczyć je gwiazdką.
    private static func fillComputedAmounts(_ line: inout InvoiceLine) {
        let rate = numericVatRate(line.vatRate)

        // 1. Wartość brutto z ceny jednostkowej brutto — gdy wystawca podał tylko ją.
        if line.gross == nil, let quantity = line.quantity, let unitGross = line.unitGrossPrice {
            var gross = quantity * unitGross
            if let discount = line.discount { gross -= discount }
            line.gross = gross.roundedToCents()
            line.computed.insert(.gross)
        }

        // 2. Wartość netto: najpierw z ceny jednostkowej netto, w drugiej kolejności z brutto.
        if line.net == nil {
            if let quantity = line.quantity, let price = line.unitNetPrice {
                var net = quantity * price
                if let discount = line.discount { net -= discount }
                line.net = net.roundedToCents()
                line.computed.insert(.net)
            } else if let gross = line.gross, let rate {
                // Faktura w konwencji brutto (art. 106e ust. 7 i 8 ustawy): pozycje niosą wyłącznie
                // wartość brutto, więc netto liczymy metodą „w stu": brutto / (1 + stawka).
                let divisor = 1 + rate / 100
                if divisor != 0 {
                    line.net = (gross / divisor).roundedToCents()
                    line.computed.insert(.net)
                }
            }
        }

        // 3. Kwota podatku. Gdy znamy brutto i netto, liczymy ją jako różnicę — dzięki temu
        // suma netto i VAT zawsze daje dokładnie wartość brutto podaną przez wystawcę.
        if line.vat == nil {
            if let gross = line.gross, let net = line.net {
                line.vat = (gross - net).roundedToCents()
                line.computed.insert(.vat)
            } else if let net = line.net, let rate {
                line.vat = (net * rate / 100).roundedToCents()
                line.computed.insert(.vat)
            }
        }

        // 4. Wartość brutto z netto i podatku, jeśli nadal jej brakuje.
        if line.gross == nil, let net = line.net, let vat = line.vat {
            line.gross = (net + vat).roundedToCents()
            line.computed.insert(.gross)
        }

        // 5. Cena jednostkowa netto — wymagana na wydruku, a wystawca mógł podać same wartości.
        if line.unitNetPrice == nil, let net = line.net,
           let quantity = line.quantity, quantity != 0 {
            line.unitNetPrice = (net / quantity).roundedToCents()
            line.computed.insert(.unitNetPrice)
        }
    }

    /// Normalizuje zapis stawki: „23" → „23%", „zw" → „zw.", „np" → „np.".
    static func normalizeVatRate(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        switch lower {
        case "zw", "zw.": return "zw."
        case "np", "np.": return "np."
        case "oo", "o.o.": return "o.o."
        default: break
        }
        if raw.hasSuffix("%") { return raw }
        if Decimal(ksefString: raw) != nil { return "\(raw)%" }
        return raw
    }

    /// Zwraca stawkę jako liczbę, o ile da się ją odczytać — potrzebne do wyliczeń zastępczych.
    static func numericVatRate(_ label: String?) -> Decimal? {
        guard let label else { return nil }
        let cleaned = label.replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Decimal(ksefString: cleaned)
    }

    // MARK: - Adnotacje

    private static func parseAnnotations(fa: XmlNode, into invoice: inout Invoice) {
        guard let node = fa.child("Adnotacje") else { return }
        var annotations = Annotations()

        // W schemacie „1" oznacza brak adnotacji, „2" — jej wystąpienie.
        func flag(_ name: String) -> Bool {
            guard let raw = node.string(name) else { return false }
            return raw == "2"
        }

        annotations.cashMethod = flag("P_16")
        annotations.selfInvoicing = flag("P_17")
        annotations.reverseCharge = flag("P_18")
        annotations.splitPayment = flag("P_18A")

        if let zwolnienie = node.child("Zwolnienie") {
            let hasExemption = zwolnienie.string("P_19N") == nil
            if hasExemption {
                annotations.exemption = zwolnienie.string("P_19") != nil
                    || zwolnienie.string("P_19A") != nil
                    || zwolnienie.string("P_19B") != nil
                    || zwolnienie.string("P_19C") != nil
                annotations.exemptionLegalBasis = zwolnienie.string("P_19A")
                    ?? zwolnienie.string("P_19B")
                    ?? zwolnienie.string("P_19C")
            }
        }

        if let transport = node.child("NoweSrodkiTransportu") {
            annotations.newTransportMeans = transport.string("P_22N") == nil
                && (transport.string("P_22") != nil || transport.child("NowySrodekTransportu") != nil)
        }

        if let marza = node.child("PMarzy") {
            let notApplicable = marza.string("P_PMarzyN") != nil
            if !notApplicable {
                annotations.marginProcedure = true
                if marza.string("P_PMarzy_3_1") != nil {
                    annotations.marginProcedureKind = "biura podróży, art. 119"
                } else if marza.string("P_PMarzy_3_2") != nil {
                    annotations.marginProcedureKind = "towary używane, art. 120"
                } else if marza.string("P_PMarzy_3_3") != nil {
                    annotations.marginProcedureKind = "dzieła sztuki i antyki, art. 120"
                }
            }
        }

        annotations.taxiFlatRate = fa.decimal("P_13_4") != nil
        invoice.annotations = annotations
    }

    // MARK: - Korekta

    private static func parseCorrection(fa: XmlNode, into invoice: inout Invoice) {
        guard invoice.kind.isCorrection
            || fa.string("PrzyczynaKorekty") != nil
            || fa.child("DaneFaKorygowanej") != nil else { return }

        var correction = CorrectionInfo()
        correction.reason = fa.string("PrzyczynaKorekty")
        correction.correctionType = fa.string("TypKorekty")

        // Schemat dopuszcza wiele korygowanych faktur; wykazujemy pierwszą,
        // a pozostałe trafiają do opisu dodatkowego.
        let corrected = fa.all("DaneFaKorygowanej")
        if let first = corrected.first {
            correction.correctedInvoiceNumber = first.string("NrFaKorygowanej")
            correction.correctedIssueDate = parseDate(first.string("DataWystFaKorygowanej"))
            correction.correctedKsefNumber = first.string("NrKSeF") ?? first.string("NrKSeFFaKorygowanej")
            correction.correctedPeriod = first.string("OkresFaKorygowanej")
            correction.correctedOutsideKsef = first.string("NrKSeFN") != nil
        }
        for extra in corrected.dropFirst() {
            if let number = extra.string("NrFaKorygowanej") {
                invoice.additionalDescription.append("Dodatkowa faktura korygowana: \(number)")
            }
        }
        invoice.correction = correction
    }

    // MARK: - Płatność

    private static func parsePayment(fa: XmlNode, into invoice: inout Invoice) {
        guard let payment = fa.child("Platnosc") else { return }

        invoice.isPaid = payment.string("Zaplacono") == "1"
        invoice.paymentDate = parseDate(payment.string("DataZaplaty"))
        invoice.alreadyPaid = payment.decimal("KwotaZaplatyCzesciowej")

        if let form = payment.string("FormaPlatnosci") {
            invoice.paymentForm = paymentFormName(form)
        } else if payment.string("PlatnoscInna") == "1" {
            invoice.paymentForm = payment.string("OpisPlatnosci") ?? "inna"
        }

        if let terms = payment.child("TerminPlatnosci") {
            invoice.paymentDueDate = parseDate(terms.string("Termin"))
            invoice.paymentDueDescription = terms.string("TerminOpis")
        }

        for account in payment.all("RachunekBankowy") {
            invoice.bankAccounts.append(BankAccount(
                number: account.string("NrRB"),
                bankName: account.string("NazwaBanku"),
                description: account.string("OpisRachunku"),
                isFactor: false
            ))
        }
        for account in payment.all("RachunekBankowyFaktora") {
            invoice.bankAccounts.append(BankAccount(
                number: account.string("NrRB"),
                bankName: account.string("NazwaBanku"),
                description: account.string("OpisRachunku"),
                isFactor: true
            ))
        }

        if let skonto = payment.child("Skonto") {
            let conditions = skonto.string("WarunkiSkonta")
            let amount = skonto.string("WysokoscSkonta")
            let text = [conditions, amount].compactMap { $0 }.joined(separator: " — ")
            if !text.isEmpty { invoice.additionalDescription.append("Skonto: \(text)") }
        }
    }

    /// Słownik form płatności ze schematu FA.
    static func paymentFormName(_ code: String) -> String {
        switch code.trimmingCharacters(in: .whitespaces) {
        case "1": return "gotówka"
        case "2": return "karta"
        case "3": return "bon"
        case "4": return "czek"
        case "5": return "kredyt"
        case "6": return "przelew"
        case "7": return "mobilna"
        default: return code
        }
    }

    // MARK: - PEF / UBL

    private static func parseUBL(root: XmlNode) -> Invoice {
        var invoice = Invoice(ksefNumber: "", invoiceNumber: "")

        invoice.invoiceNumber = root.string("ID") ?? ""
        invoice.issueDate = parseDate(root.string("IssueDate"))
        invoice.currency = root.string("DocumentCurrencyCode") ?? "PLN"
        invoice.kind = root.name == "CreditNote" ? .korekta : .vat

        if let period = root.child("InvoicePeriod") {
            invoice.saleDate = parseDate(period.string("EndDate") ?? period.string("StartDate"))
        }
        invoice.paymentDueDate = parseDate(root.string("DueDate"))

        invoice.seller = parseUBLParty(root.node(path: ["AccountingSupplierParty", "Party"]))
        invoice.buyer = parseUBLParty(root.node(path: ["AccountingCustomerParty", "Party"]))

        // Sumy dokumentu.
        if let totals = root.child("LegalMonetaryTotal") {
            invoice.totalNet = totals.decimal("TaxExclusiveAmount") ?? 0
            invoice.totalGross = totals.decimal("TaxInclusiveAmount") ?? 0
            invoice.amountDue = totals.decimal("PayableAmount") ?? invoice.totalGross
        }
        if let taxTotal = root.child("TaxTotal") {
            invoice.totalVat = taxTotal.decimal("TaxAmount") ?? (invoice.totalGross - invoice.totalNet)

            var order = 1
            for subtotal in taxTotal.all("TaxSubtotal") {
                let net = subtotal.decimal("TaxableAmount") ?? 0
                let vat = subtotal.decimal("TaxAmount") ?? 0
                let percent = subtotal.node(path: ["TaxCategory"])?.decimal("Percent")
                let label = percent.map { "\(Fmt.quantity($0))%" } ?? "—"
                invoice.vatSummary.append(VatSummaryRow(order: order, rateLabel: label, net: net, vat: vat, vatInPLN: nil))
                order += 1
            }
        }

        // Pozycje: w UBL nazwa i ilość są zagnieżdżone w `Item` i `InvoicedQuantity`.
        let lineNodes = root.all("InvoiceLine") + root.all("CreditNoteLine")
        for (offset, node) in lineNodes.enumerated() {
            var line = InvoiceLine(index: Int(node.string("ID") ?? "") ?? (offset + 1))
            line.name = node.node(path: ["Item"])?.string("Name")
            line.quantity = node.decimal("InvoicedQuantity") ?? node.decimal("CreditedQuantity")
            line.unit = node.child("InvoicedQuantity")?.attributes["unitCode"]
            line.net = node.decimal("LineExtensionAmount")
            line.unitNetPrice = node.node(path: ["Price"])?.decimal("PriceAmount")
            if let percent = node.node(path: ["Item", "ClassifiedTaxCategory"])?.decimal("Percent") {
                line.vatRate = "\(Fmt.quantity(percent))%"
            }
            fillComputedAmounts(&line)
            invoice.lines.append(line)
        }

        if let paymentMeans = root.child("PaymentMeans") {
            invoice.paymentForm = paymentMeans.string("PaymentMeansCode")
            if let account = paymentMeans.node(path: ["PayeeFinancialAccount"]) {
                invoice.bankAccounts.append(BankAccount(
                    number: account.string("ID"),
                    bankName: account.string("Name"),
                    description: nil
                ))
            }
        }

        return invoice
    }

    private static func parseUBLParty(_ node: XmlNode?) -> Party {
        var party = Party()
        guard let node else { return party }

        party.name = node.node(path: ["PartyLegalEntity"])?.string("RegistrationName")
            ?? node.node(path: ["PartyName"])?.string("Name")

        // Identyfikator podatkowy: „PL1234567890" — odcinamy prefiks kraju.
        if let company = node.node(path: ["PartyTaxScheme"])?.string("CompanyID") {
            let normalized = Nip.normalize(company)
            if Nip.isValid(normalized) { party.nip = normalized } else { party.vatUE = company }
        }
        if party.nip == nil, let legalId = node.node(path: ["PartyLegalEntity"])?.string("CompanyID") {
            let normalized = Nip.normalize(legalId)
            if Nip.isValid(normalized) { party.nip = normalized }
        }

        if let address = node.node(path: ["PostalAddress"]) {
            party.address.street = address.string("StreetName")
            party.address.buildingNumber = address.string("BuildingNumber")
            party.address.city = address.string("CityName")
            party.address.postalCode = address.string("PostalZone")
            party.address.countryCode = address.node(path: ["Country"])?.string("IdentificationCode")
        }
        if let contact = node.node(path: ["Contact"]) {
            party.email = contact.string("ElectronicMail")
            party.phone = contact.string("Telephone")
        }
        return party
    }

    // MARK: - Daty

    /// Parsuje datę zapisaną w XML faktury. Dopuszcza samą datę i datę z czasem.
    static func parseDate(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }

        // Sama data — interpretowana w strefie warszawskiej, żeby nie przesuwać dnia.
        if raw.count == 10 {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = Fmt.warsaw
            f.dateFormat = "yyyy-MM-dd"
            if let date = f.date(from: raw) { return date }
        }
        return KsefHTTP.parseDate(raw)
    }
}
