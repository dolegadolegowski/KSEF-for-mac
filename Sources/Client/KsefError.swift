import Foundation

/// Błąd zwrócony przez KSeF lub warstwę transportową.
///
/// Komunikaty są po polsku i zawsze niosą kod błędu KSeF, jeśli API go podało —
/// nie zastępujemy go ogólnikiem.
enum KsefError: LocalizedError {
    case rateLimited(retryAfter: TimeInterval, message: String)
    case api(httpStatus: Int, codes: [Int], message: String, traceId: String?)
    case network(String)
    case decoding(String)
    case notAuthenticated
    case missingPermission(String)
    case authenticationFailed(code: Int, message: String)
    case exportFailed(code: Int, message: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .rateLimited(retryAfter, message):
            let seconds = Int(retryAfter.rounded())
            let base = "Przekroczono limit żądań API KSeF (HTTP 429)."
            let wait = seconds > 0 ? " Ponowienie za \(seconds) s." : ""
            return message.isEmpty ? base + wait : "\(base)\(wait) \(message)"
        case let .api(httpStatus, codes, message, traceId):
            var parts: [String] = []
            if !codes.isEmpty {
                parts.append("Kod KSeF: \(codes.map(String.init).joined(separator: ", "))")
            }
            parts.append("HTTP \(httpStatus)")
            if let traceId, !traceId.isEmpty { parts.append("traceId: \(traceId)") }
            return "\(message) (\(parts.joined(separator: ", ")))"
        case let .network(detail):
            return "Błąd połączenia z KSeF: \(detail)"
        case let .decoding(detail):
            return "Nie udało się odczytać odpowiedzi KSeF: \(detail)"
        case .notAuthenticated:
            return "Brak uwierzytelnienia. Uzupełnij NIP i token KSeF w ustawieniach."
        case let .missingPermission(detail):
            return "Token nie ma wymaganego uprawnienia InvoiceRead. \(detail)"
        case let .authenticationFailed(code, message):
            return "Uwierzytelnianie nie powiodło się (status \(code)): \(message)"
        case let .exportFailed(code, message):
            return "Eksport paczki faktur nie powiódł się (status \(code)): \(message)"
        case .cancelled:
            return "Operacja przerwana przez użytkownika."
        }
    }

    /// Czy warto ponowić żądanie automatycznie.
    var isRetryable: Bool {
        switch self {
        case .rateLimited: return true
        case .network: return true
        case let .api(httpStatus, _, _, _): return httpStatus >= 500
        default: return false
        }
    }

    /// Przejściowy błąd wykupu tokenów — status operacji jest już sukcesem,
    /// ale para tokenów nie została jeszcze wystawiona.
    var isTransientRedeem: Bool {
        if case let .api(_, codes, _, _) = self { return codes.contains(21301) }
        return false
    }

    var codes: [Int] {
        if case let .api(_, codes, _, _) = self { return codes }
        return []
    }
}
