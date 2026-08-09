import CommonCrypto
import CryptoKit
import Foundation
import Security

enum CryptoError: LocalizedError {
    case invalidCertificate
    case keyExtractionFailed(String)
    case encryptionUnsupported
    case encryptionFailed(String)
    case decryptionFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidCertificate:
            return "Nie udało się odczytać certyfikatu klucza publicznego KSeF."
        case let .keyExtractionFailed(detail):
            return "Nie udało się wydobyć klucza publicznego z certyfikatu KSeF: \(detail)"
        case .encryptionUnsupported:
            return "Klucz publiczny KSeF nie obsługuje szyfrowania RSA-OAEP SHA-256."
        case let .encryptionFailed(detail):
            return "Szyfrowanie RSA-OAEP nie powiodło się: \(detail)"
        case let .decryptionFailed(status):
            return "Odszyfrowanie paczki faktur nie powiodło się (kod \(status))."
        }
    }
}

enum Crypto {
    // MARK: - Skróty

    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// Skrót SHA-256 zakodowany Base64 — postać używana przez KSeF w metadanych faktur.
    static func sha256Base64(_ data: Data) -> String {
        sha256(data).base64EncodedString()
    }

    /// Skrót SHA-256 w Base64URL — postać wymagana w linku weryfikacyjnym kodu QR (KOD I).
    static func sha256Base64URL(_ data: Data) -> String {
        base64ToBase64URL(sha256(data).base64EncodedString())
    }

    /// Konwersja Base64 → Base64URL (bez dopełnienia), zgodnie ze specyfikacją kodów QR.
    static func base64ToBase64URL(_ base64: String) -> String {
        base64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Losowość

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if status != errSecSuccess {
            // Awaryjnie generator systemowy Swift — nadal kryptograficznie bezpieczny na Darwinie.
            bytes = (0 ..< count).map { _ in UInt8.random(in: 0 ... 255) }
        }
        return Data(bytes)
    }

    // MARK: - RSA-OAEP SHA-256

    /// Buduje `SecKey` z materiału zwróconego przez `/security/public-key-certificates`.
    ///
    /// Endpoint deklaruje certyfikat DER, ale dla klucza o przeznaczeniu `KsefTokenEncryption`
    /// zwracana bywa sama struktura SubjectPublicKeyInfo. Obsługiwane są obie postacie,
    /// a także goły PKCS#1 RSAPublicKey.
    static func publicKey(fromDER der: Data) throws -> SecKey {
        // 1. Pełny certyfikat X.509.
        if let cert = SecCertificateCreateWithData(nil, der as CFData),
           let key = SecCertificateCopyKey(cert) {
            return key
        }

        // 2. SubjectPublicKeyInfo — wydobywamy zagnieżdżony PKCS#1.
        if let pkcs1 = DER.pkcs1PublicKey(fromSPKI: der),
           let key = makeRSAPublicKey(pkcs1) {
            return key
        }

        // 3. Materiał już w postaci PKCS#1.
        if let key = makeRSAPublicKey(der) {
            return key
        }

        throw CryptoError.invalidCertificate
    }

    private static func makeRSAPublicKey(_ pkcs1: Data) -> SecKey? {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error) else {
            error?.release()
            return nil
        }
        return key
    }

    /// Szyfruje dane algorytmem RSA-OAEP z SHA-256 (MGF1-SHA-256).
    static func rsaOaepSha256Encrypt(_ plaintext: Data, publicKey: SecKey) throws -> Data {
        let algorithm = SecKeyAlgorithm.rsaEncryptionOAEPSHA256
        guard SecKeyIsAlgorithmSupported(publicKey, .encrypt, algorithm) else {
            throw CryptoError.encryptionUnsupported
        }
        var error: Unmanaged<CFError>?
        guard let cipher = SecKeyCreateEncryptedData(publicKey, algorithm, plaintext as CFData, &error) else {
            let detail = (error?.takeRetainedValue() as Error?)?.localizedDescription ?? "brak szczegółów"
            throw CryptoError.encryptionFailed(detail)
        }
        return cipher as Data
    }

    /// Buduje ciąg uwierzytelniający `"{token}|{timestampMs}"`, szyfruje go i koduje Base64.
    static func encryptKsefToken(_ token: String, challengeTimestampMs: Int64, publicKey: SecKey) throws -> String {
        let payload = "\(token)|\(challengeTimestampMs)"
        guard let data = payload.data(using: .utf8) else {
            throw CryptoError.encryptionFailed("nieprawidłowe kodowanie tokena")
        }
        let cipher = try rsaOaepSha256Encrypt(data, publicKey: publicKey)
        return cipher.base64EncodedString()
    }

    // MARK: - AES-256-CBC

    /// Szyfruje AES-256-CBC z dopełnieniem PKCS#7 — używane wyłącznie w testach spójności.
    static func aes256CBCEncrypt(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
        try aes256CBC(plaintext, key: key, iv: iv, operation: CCOperation(kCCEncrypt))
    }

    /// Odszyfrowuje część paczki eksportu. KSeF szyfruje paczki AES-256-CBC z dopełnieniem PKCS#7.
    static func aes256CBCDecrypt(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
        try aes256CBC(ciphertext, key: key, iv: iv, operation: CCOperation(kCCDecrypt))
    }

    private static func aes256CBC(_ input: Data, key: Data, iv: Data, operation: CCOperation) throws -> Data {
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let outputCount = output.count

        let status: CCCryptorStatus = output.withUnsafeMutableBytes { outPtr in
            input.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(operation,
                                CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, key.count,
                                ivPtr.baseAddress,
                                inPtr.baseAddress, input.count,
                                outPtr.baseAddress, outputCount,
                                &moved)
                    }
                }
            }
        }

        guard status == CCCryptorStatus(kCCSuccess) else {
            throw CryptoError.decryptionFailed(status)
        }
        output.removeSubrange(moved ..< output.count)
        return output
    }
}

/// Minimalny czytnik DER — wystarczający, by wyłuskać PKCS#1 z SubjectPublicKeyInfo.
enum DER {
    /// Zwraca zawartość `BIT STRING` z SubjectPublicKeyInfo, czyli strukturę PKCS#1 RSAPublicKey.
    static func pkcs1PublicKey(fromSPKI der: Data) -> Data? {
        var cursor = 0
        let bytes = [UInt8](der)

        // SubjectPublicKeyInfo ::= SEQUENCE { algorithm AlgorithmIdentifier, subjectPublicKey BIT STRING }
        guard let outer = readTLV(bytes, &cursor), outer.tag == 0x30 else { return nil }

        var inner = outer.valueStart
        let innerEnd = outer.valueStart + outer.length

        // Pomijamy AlgorithmIdentifier.
        guard let algorithm = readTLV(bytes, &inner), algorithm.tag == 0x30 else { return nil }
        inner = algorithm.valueStart + algorithm.length
        guard inner < innerEnd else { return nil }

        guard let bitString = readTLV(bytes, &inner), bitString.tag == 0x03 else { return nil }
        // Pierwszy bajt BIT STRING to liczba nieużywanych bitów — dla klucza zawsze 0.
        let start = bitString.valueStart + 1
        let end = bitString.valueStart + bitString.length
        guard start < end, end <= bytes.count else { return nil }
        return Data(bytes[start ..< end])
    }

    private struct TLV {
        let tag: UInt8
        let valueStart: Int
        let length: Int
    }

    private static func readTLV(_ bytes: [UInt8], _ cursor: inout Int) -> TLV? {
        guard cursor + 1 < bytes.count else { return nil }
        let tag = bytes[cursor]
        cursor += 1

        var length = Int(bytes[cursor])
        cursor += 1

        if length & 0x80 != 0 {
            let lengthBytes = length & 0x7F
            guard lengthBytes > 0, lengthBytes <= 4, cursor + lengthBytes <= bytes.count else { return nil }
            length = 0
            for _ in 0 ..< lengthBytes {
                length = (length << 8) | Int(bytes[cursor])
                cursor += 1
            }
        }

        guard cursor + length <= bytes.count else { return nil }
        return TLV(tag: tag, valueStart: cursor, length: length)
    }
}
