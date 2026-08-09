import Foundation

/// Wersja schematu, według której zapisano fakturę.
enum InvoiceSchema: String, Codable {
    case fa3 = "FA(3)"
    case fa2 = "FA(2)"
    case faRR = "FA_RR"
    case pef = "PEF"
    case unknown = "nieznany"

    /// Przestrzenie nazw wzorów dokumentów opublikowane przez Ministerstwo Finansów.
    static func detect(namespaceURI: String?, rootName: String) -> InvoiceSchema {
        guard let ns = namespaceURI else {
            return rootName == "Invoice" || rootName == "CreditNote" ? .pef : .unknown
        }
        if ns.contains("/wzor/2025/06/25/13775") { return .fa3 }
        if ns.contains("/wzor/2023/06/29/12648") { return .fa2 }
        if ns.contains("urn:oasis:names:specification:ubl") { return .pef }
        if ns.lowercased().contains("fa_rr") { return .faRR }
        // Nowsze wzory FA rozpoznajemy po strukturze, nie po dacie w adresie.
        if rootName == "Faktura" { return .fa3 }
        return .unknown
    }
}

/// Rodzaj dokumentu według pola `RodzajFaktury`.
enum InvoiceKind: String, Codable {
    case vat = "VAT"
    case korekta = "KOR"
    case zaliczkowa = "ZAL"
    case rozliczeniowa = "ROZ"
    case uproszczona = "UPR"
    case korektaZaliczkowej = "KOR_ZAL"
    case korektaRozliczeniowej = "KOR_ROZ"
    case inny = "INNY"

    var displayName: String {
        switch self {
        case .vat: return "Faktura VAT"
        case .korekta: return "Faktura korygująca"
        case .zaliczkowa: return "Faktura zaliczkowa"
        case .rozliczeniowa: return "Faktura rozliczeniowa"
        case .uproszczona: return "Faktura uproszczona"
        case .korektaZaliczkowej: return "Korekta faktury zaliczkowej"
        case .korektaRozliczeniowej: return "Korekta faktury rozliczeniowej"
        case .inny: return "Faktura"
        }
    }

    var isCorrection: Bool {
        self == .korekta || self == .korektaZaliczkowej || self == .korektaRozliczeniowej
    }

    static func from(_ raw: String?) -> InvoiceKind {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() else { return .vat }
        return InvoiceKind(rawValue: raw) ?? .inny
    }
}

/// Kierunek faktury z perspektywy kontekstu, w którym działa aplikacja.
enum InvoiceDirection: String, Codable {
    case issued
    case received

    var displayName: String {
        self == .issued ? "Wystawiona" : "Otrzymana"
    }

    var folderName: String {
        self == .issued ? "wystawione" : "otrzymane"
    }

    var filePrefix: String {
        self == .issued ? "WYSTAWIONE" : "OTRZYMANE"
    }
}

struct Address: Codable, Hashable {
    var countryCode: String?
    var province: String?
    var district: String?
    var commune: String?
    var street: String?
    var buildingNumber: String?
    var unitNumber: String?
    var city: String?
    var postalCode: String?
    var postOffice: String?
    /// Adres zapisany jednym ciągiem, gdy schemat nie rozbija go na pola (np. PEF).
    var freeform: String?

    /// Pierwszy wiersz adresu: ulica z numerem domu i lokalu.
    var line1: String? {
        if let freeform, !freeform.isEmpty, street == nil { return freeform }
        var parts: [String] = []
        if let street, !street.isEmpty { parts.append(street) }
        var number = buildingNumber ?? ""
        if let unitNumber, !unitNumber.isEmpty {
            number = number.isEmpty ? "lok. \(unitNumber)" : "\(number)/\(unitNumber)"
        }
        if !number.isEmpty { parts.append(number) }
        let joined = parts.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    /// Drugi wiersz adresu: kod pocztowy, miejscowość i ewentualny kod kraju.
    var line2: String? {
        var parts: [String] = []
        if let postalCode, !postalCode.isEmpty { parts.append(postalCode) }
        if let city, !city.isEmpty { parts.append(city) }
        var joined = parts.joined(separator: " ")
        if let countryCode, !countryCode.isEmpty, countryCode.uppercased() != "PL" {
            joined = joined.isEmpty ? countryCode : "\(joined) (\(countryCode))"
        }
        return joined.isEmpty ? nil : joined
    }

    var isEmpty: Bool { line1 == nil && line2 == nil }
}

struct Party: Codable, Hashable {
    var name: String?
    var nip: String?
    var vatUE: String?
    var otherIdentifier: String?
    var regon: String?
    var address = Address()
    var email: String?
    var phone: String?

    /// Etykieta identyfikatora do wydruku: „NIP 1234567890" albo „VAT UE …".
    var identifierLabel: String? {
        if let nip, !nip.isEmpty { return "NIP \(Nip.formatted(nip))" }
        if let vatUE, !vatUE.isEmpty { return "VAT UE \(vatUE)" }
        if let otherIdentifier, !otherIdentifier.isEmpty { return "Identyfikator \(otherIdentifier)" }
        return nil
    }

    var displayName: String {
        name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? name!
            : (nip.map { "NIP \(Nip.formatted($0))" } ?? "—")
    }
}

struct InvoiceLine: Codable, Hashable, Identifiable {
    var index: Int
    var name: String?
    var quantity: Decimal?
    var unit: String?
    var unitNetPrice: Decimal?
    var unitGrossPrice: Decimal?
    var discount: Decimal?
    var vatRate: String?
    var net: Decimal?
    var vat: Decimal?
    var gross: Decimal?
    var gtu: [String] = []
    var procedures: [String] = []
    var indeks: String?
    var pkwiu: String?
    var cn: String?
    var gtin: String?
    var exciseAmount: Decimal?

    /// Pola wyliczone przez aplikację, bo wystawca ich nie podał. Oznaczane gwiazdką w PDF.
    var computed: Set<ComputedField> = []

    var id: Int { index }

    enum ComputedField: String, Codable, Hashable {
        case net, vat, gross, unitNetPrice
    }
}

/// Wiersz podsumowania w rozbiciu na stawki VAT.
struct VatSummaryRow: Codable, Hashable, Identifiable {
    /// Klucz porządkujący, zgodny z kolejnością pól P_13_* w schemacie.
    var order: Int
    var rateLabel: String
    var net: Decimal
    var vat: Decimal
    /// Kwota VAT przeliczona na złote — pole P_14_*W dla faktur w walucie obcej.
    var vatInPLN: Decimal?
    var isVatComputed: Bool = false

    var gross: Decimal { net + vat }
    var id: Int { order }
}

struct BankAccount: Codable, Hashable {
    var number: String?
    var bankName: String?
    var description: String?
    /// Rachunek faktora — oznaczany osobno, bo płatność trafia do innego podmiotu.
    var isFactor: Bool = false
}

struct Annotations: Codable, Hashable {
    var cashMethod = false               // P_16 — metoda kasowa
    var selfInvoicing = false            // P_17 — samofakturowanie
    var reverseCharge = false            // P_18 — odwrotne obciążenie
    var splitPayment = false             // P_18A — mechanizm podzielonej płatności
    var exemption = false                // P_19 — zwolnienie z VAT
    var exemptionLegalBasis: String?     // P_19A / P_19B / P_19C
    var newTransportMeans = false        // P_22
    var marginProcedure = false          // P_PMarzy
    var marginProcedureKind: String?
    var taxiFlatRate = false             // ryczałt dla taksówek (P_13_4)
    var intraCommunityTriangular = false
    var additionalDescriptions: [(key: String, value: String)] = []

    /// Lista adnotacji do wydruku na fakturze.
    var printable: [String] {
        var out: [String] = []
        if splitPayment { out.append("mechanizm podzielonej płatności") }
        if cashMethod { out.append("metoda kasowa") }
        if selfInvoicing { out.append("samofakturowanie") }
        if reverseCharge { out.append("odwrotne obciążenie") }
        if exemption {
            let basis = exemptionLegalBasis.map { " — podstawa prawna: \($0)" } ?? ""
            out.append("zwolnienie z VAT\(basis)")
        }
        if marginProcedure {
            let kind = marginProcedureKind.map { " (\($0))" } ?? ""
            out.append("procedura marży\(kind)")
        }
        if newTransportMeans { out.append("nowe środki transportu") }
        if taxiFlatRate { out.append("ryczałt dla taksówek osobowych") }
        return out
    }

    // Ręczna zgodność z Codable/Hashable — krotki nie są syntezowane automatycznie.
    enum CodingKeys: String, CodingKey {
        case cashMethod, selfInvoicing, reverseCharge, splitPayment
        case exemption, exemptionLegalBasis, newTransportMeans
        case marginProcedure, marginProcedureKind, taxiFlatRate, intraCommunityTriangular
    }

    static func == (lhs: Annotations, rhs: Annotations) -> Bool {
        lhs.cashMethod == rhs.cashMethod
            && lhs.selfInvoicing == rhs.selfInvoicing
            && lhs.reverseCharge == rhs.reverseCharge
            && lhs.splitPayment == rhs.splitPayment
            && lhs.exemption == rhs.exemption
            && lhs.exemptionLegalBasis == rhs.exemptionLegalBasis
            && lhs.newTransportMeans == rhs.newTransportMeans
            && lhs.marginProcedure == rhs.marginProcedure
            && lhs.taxiFlatRate == rhs.taxiFlatRate
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(cashMethod)
        hasher.combine(selfInvoicing)
        hasher.combine(reverseCharge)
        hasher.combine(splitPayment)
        hasher.combine(exemption)
        hasher.combine(marginProcedure)
    }
}

struct CorrectionInfo: Codable, Hashable {
    var reason: String?                  // PrzyczynaKorekty
    var correctionType: String?          // TypKorekty
    var correctedInvoiceNumber: String?  // NrFaKorygowanej
    var correctedIssueDate: Date?        // DataWystFaKorygowanej
    var correctedKsefNumber: String?     // NrKSeFFaKorygowanej
    var correctedPeriod: String?         // OkresFaKorygowanej
    /// Czy korygowana faktura była wystawiona poza KSeF.
    var correctedOutsideKsef = false

    var correctionTypeDescription: String? {
        switch correctionType {
        case "1": return "korekta w okresie ujęcia faktury pierwotnej"
        case "2": return "korekta w okresie wystawienia faktury korygującej"
        case "3": return "korekta w okresie innym niż powyższe"
        default: return correctionType
        }
    }
}

/// Kompletna faktura odczytana z dokumentu źródłowego KSeF.
///
/// Kwoty pochodzą wprost z XML. Wartości, których wystawca nie podał, a które aplikacja
/// wyliczyła, są odnotowane w `computed` odpowiedniego wiersza i oznaczane gwiazdką.
struct Invoice: Identifiable, Hashable {
    var ksefNumber: String
    var invoiceNumber: String
    var kind: InvoiceKind = .vat
    var schema: InvoiceSchema = .unknown
    var direction: InvoiceDirection = .issued

    var issueDate: Date?
    var issuePlace: String?
    var saleDate: Date?
    var acquisitionDate: Date?
    var permanentStorageDate: Date?

    var seller = Party()
    var buyer = Party()

    var lines: [InvoiceLine] = []
    var vatSummary: [VatSummaryRow] = []

    var totalNet: Decimal = 0
    var totalVat: Decimal = 0
    var totalGross: Decimal = 0
    var amountDue: Decimal?
    var alreadyPaid: Decimal?

    var currency: String = "PLN"
    var exchangeRate: Decimal?
    var exchangeRateDate: Date?

    var paymentForm: String?
    var paymentDueDate: Date?
    var paymentDueDescription: String?
    var bankAccounts: [BankAccount] = []
    var isPaid = false
    var paymentDate: Date?

    var annotations = Annotations()
    var correction: CorrectionInfo?

    var additionalDescription: [String] = []
    var hasAttachment = false

    /// Oryginalny dokument źródłowy. PDF jest wyłącznie jego wizualizacją.
    var rawXML: Data = Data()
    /// Skrót SHA-256 faktury w Base64 — z metadanych KSeF, gdy dostępny.
    var invoiceHashBase64: String?

    /// Czy któraś z prezentowanych kwot została wyliczona przez aplikację.
    var hasComputedAmounts: Bool {
        lines.contains { !$0.computed.isEmpty } || vatSummary.contains(where: \.isVatComputed)
    }

    var id: String { ksefNumber }

    var isCorrection: Bool { kind.isCorrection }

    /// Druga strona transakcji z punktu widzenia kontekstu — pokazywana w tabelach.
    var counterparty: Party {
        direction == .issued ? buyer : seller
    }

    static func == (lhs: Invoice, rhs: Invoice) -> Bool {
        lhs.ksefNumber == rhs.ksefNumber && lhs.direction == rhs.direction
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ksefNumber)
        hasher.combine(direction)
    }
}
