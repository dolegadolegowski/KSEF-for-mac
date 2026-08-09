import Foundation

// MARK: - Certyfikaty klucza publicznego

struct PublicKeyCertificate: Decodable {
    let certificate: String
    let certificateId: String
    let publicKeyId: String
    let validFrom: Date
    let validTo: Date
    let usage: [String]

    static let usageTokenEncryption = "KsefTokenEncryption"
    static let usageSymmetricKeyEncryption = "SymmetricKeyEncryption"

    var derData: Data? { Data(base64Encoded: certificate) }

    func isValid(at date: Date = Date()) -> Bool {
        validFrom <= date && date <= validTo
    }
}

// MARK: - Uwierzytelnianie

struct AuthChallengeResponse: Decodable {
    let challenge: String
    let timestamp: Date
    let timestampMs: Int64
    let clientIp: String?
}

struct AuthContextIdentifier: Encodable {
    let type: String
    let value: String

    static func nip(_ value: String) -> AuthContextIdentifier {
        AuthContextIdentifier(type: "Nip", value: value)
    }
}

struct InitTokenAuthenticationRequest: Encodable {
    let challenge: String
    let contextIdentifier: AuthContextIdentifier
    let encryptedToken: String
    let publicKeyId: String?
}

struct TokenInfo: Decodable {
    let token: String
    let validUntil: Date
}

struct AuthenticationInitResponse: Decodable {
    let referenceNumber: String
    let authenticationToken: TokenInfo
}

struct StatusInfo: Decodable {
    let code: Int
    let description: String
    let details: [String]?

    /// Statusy końcowe procesu uwierzytelniania: 200 = sukces, wszystko ≥ 400 = błąd.
    var isTerminal: Bool { code >= 200 }
    var isSuccess: Bool { code == 200 }

    var fullDescription: String {
        let extra = (details ?? []).joined(separator: " ")
        return extra.isEmpty ? description : "\(description) \(extra)"
    }
}

struct AuthenticationStatusResponse: Decodable {
    let startDate: Date
    let status: StatusInfo
    let isTokenRedeemed: Bool?
    let refreshTokenValidUntil: Date?
}

struct AuthenticationTokensResponse: Decodable {
    let accessToken: TokenInfo
    let refreshToken: TokenInfo
}

// MARK: - Zapytanie o metadane faktur

enum InvoiceSubjectType: String, Codable {
    /// Podmiot 1 — sprzedawca. Filtr faktur wystawionych przez kontekst.
    case subject1 = "Subject1"
    /// Podmiot 2 — nabywca. Filtr faktur otrzymanych przez kontekst.
    case subject2 = "Subject2"
}

struct InvoiceQueryDateRange: Encodable {
    let dateType: String
    let from: String
    let to: String
}

struct InvoiceQueryFilters: Encodable {
    let subjectType: String
    let dateRange: InvoiceQueryDateRange
}

struct FormCode: Codable, Hashable {
    let systemCode: String
    let schemaVersion: String
    let value: String
}

struct InvoiceMetadataSeller: Codable, Hashable {
    let nip: String?
    let name: String?
}

struct InvoiceMetadataBuyerIdentifier: Codable, Hashable {
    let type: String?
    let value: String?
}

struct InvoiceMetadataBuyer: Codable, Hashable {
    let identifier: InvoiceMetadataBuyerIdentifier?
    let name: String?
}

/// Metadane faktury zwracane przez `/invoices/query/metadata` i powtórzone w `_metadata.json`
/// paczki eksportu.
///
/// Kwoty w tym typie są przybliżeniem (API zwraca je jako `double`) i służą wyłącznie
/// do wstępnej prezentacji zanim faktura zostanie sparsowana z XML. Wszystkie sumy
/// pokazywane użytkownikowi liczone są na `Decimal` z danych XML.
struct InvoiceMetadata: Codable, Hashable, Identifiable {
    let ksefNumber: String
    let invoiceNumber: String
    let issueDate: String
    let invoicingDate: Date?
    let acquisitionDate: Date?
    let permanentStorageDate: Date?
    let seller: InvoiceMetadataSeller?
    let buyer: InvoiceMetadataBuyer?
    let netAmount: Double?
    let grossAmount: Double?
    let vatAmount: Double?
    let currency: String?
    let invoicingMode: String?
    let invoiceType: String?
    let formCode: FormCode?
    let isSelfInvoicing: Bool?
    let hasAttachment: Bool?
    let invoiceHash: String?
    let hashOfCorrectedInvoice: String?

    var id: String { ksefNumber }
}

struct QueryInvoicesMetadataResponse: Decodable {
    let hasMore: Bool
    let isTruncated: Bool
    let permanentStorageHwmDate: Date?
    let invoices: [InvoiceMetadata]
}

/// Zawartość pliku `_metadata.json` w paczce eksportu.
struct ExportMetadataFile: Decodable {
    let invoices: [InvoiceMetadata]
}

// MARK: - Eksport paczki faktur

struct EncryptionInfo: Encodable {
    let encryptedSymmetricKey: String
    let initializationVector: String
    let publicKeyId: String?
}

struct InvoiceExportRequest: Encodable {
    let encryption: EncryptionInfo
    let filters: InvoiceQueryFilters
    let onlyMetadata: Bool?
}

struct InvoiceExportResponse: Decodable {
    let referenceNumber: String
}

struct InvoicePackagePart: Decodable {
    let ordinalNumber: Int
    let partName: String
    let method: String
    let url: String
    let partSize: Int64
    let partHash: String
    let encryptedPartSize: Int64
    let encryptedPartHash: String
    let expirationDate: Date?
}

struct InvoicePackage: Decodable {
    let invoiceCount: Int
    let size: Int64
    let parts: [InvoicePackagePart]
    let isTruncated: Bool
}

struct InvoiceExportStatusResponse: Decodable {
    let status: StatusInfo
    let completedDate: Date?
    let packageExpirationDate: Date?
    let package: InvoicePackage?
}

// MARK: - Błędy API

struct ApiError: Decodable {
    let code: Int?
    let description: String?
    let details: [String]?
}

/// Format `application/problem+json` — preferowany, włączany nagłówkiem `X-Error-Format`.
struct ProblemDetails: Decodable {
    let title: String?
    let status: Int?
    let detail: String?
    let errors: [ApiError]?
    let timestamp: Date?
    let traceId: String?
}

/// Starszy format `ExceptionResponse` — nadal zwracany przez część endpointów.
struct ExceptionDetails: Decodable {
    let exceptionCode: Int?
    let exceptionDescription: String?
    let details: [String]?
}

struct ExceptionInfo: Decodable {
    let exceptionDetailList: [ExceptionDetails]?
    let referenceNumber: String?
    let timestamp: Date?
}

struct ExceptionResponse: Decodable {
    let exception: ExceptionInfo?
}

/// Format odpowiedzi 429 w starszym wariancie.
struct TooManyRequestsResponse: Decodable {
    let status: StatusInfo?
}
