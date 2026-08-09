import Foundation
import Security

enum CryptoTests {
    /// Generuje parę kluczy RSA na potrzeby testów szyfrowania.
    static func makeKeyPair(bits: Int = 2048) -> (private: SecKey, public: SecKey)? {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: bits,
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey) else {
            error?.release()
            return nil
        }
        return (privateKey, publicKey)
    }

    /// Zwraca klucz publiczny w postaci PKCS#1 (tak eksportuje go Security framework).
    static func pkcs1Representation(_ key: SecKey) -> Data? {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            error?.release()
            return nil
        }
        return data
    }

    /// Opakowuje PKCS#1 w strukturę SubjectPublicKeyInfo — tak, jak robi to KSeF
    /// dla klucza o przeznaczeniu `KsefTokenEncryption`.
    static func wrapInSPKI(pkcs1: Data) -> Data {
        // AlgorithmIdentifier dla rsaEncryption (OID 1.2.840.113549.1.1.1) z parametrem NULL.
        let algorithm: [UInt8] = [
            0x30, 0x0D,
            0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01,
            0x05, 0x00,
        ]
        var bitString = Data([0x03])
        var bitContent = Data([0x00])
        bitContent.append(pkcs1)
        bitString.append(derLength(bitContent.count))
        bitString.append(bitContent)

        var body = Data(algorithm)
        body.append(bitString)

        var out = Data([0x30])
        out.append(derLength(body.count))
        out.append(body)
        return out
    }

    private static func derLength(_ length: Int) -> Data {
        if length < 0x80 { return Data([UInt8(length)]) }
        var bytes: [UInt8] = []
        var value = length
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    static func run() {
        T.suite("Kryptografia") {
            T.test("szyfruje token RSA-OAEP SHA-256 w formacie token|timestamp") {
                guard let keys = makeKeyPair() else {
                    T.fail("nie udało się wygenerować pary kluczy RSA")
                    return
                }

                let token = "TESTOWY-TOKEN-KSEF-123456"
                let timestampMs: Int64 = 1_784_000_123_456

                let encoded = try Crypto.encryptKsefToken(token,
                                                          challengeTimestampMs: timestampMs,
                                                          publicKey: keys.public)
                guard let cipher = Data(base64Encoded: encoded) else {
                    T.fail("wynik szyfrowania nie jest poprawnym Base64")
                    return
                }

                // Odszyfrowanie kluczem prywatnym musi odtworzyć dokładnie ten sam ciąg.
                var error: Unmanaged<CFError>?
                guard let plain = SecKeyCreateDecryptedData(keys.private,
                                                            .rsaEncryptionOAEPSHA256,
                                                            cipher as CFData,
                                                            &error) as Data? else {
                    error?.release()
                    T.fail("odszyfrowanie nie powiodło się")
                    return
                }
                T.equal(String(data: plain, encoding: .utf8), "\(token)|\(timestampMs)",
                        "odszyfrowana treść żądania uwierzytelnienia")
            }

            T.test("odczytuje klucz publiczny z SubjectPublicKeyInfo") {
                guard let keys = makeKeyPair(), let pkcs1 = pkcs1Representation(keys.public) else {
                    T.fail("nie udało się przygotować klucza")
                    return
                }

                // KSeF potrafi zwrócić klucz jako SPKI zamiast pełnego certyfikatu X.509.
                let spki = wrapInSPKI(pkcs1: pkcs1)
                T.equal(DER.pkcs1PublicKey(fromSPKI: spki), pkcs1, "PKCS#1 wydobyty ze struktury SPKI")

                let imported = try Crypto.publicKey(fromDER: spki)
                let roundTrip = try Crypto.rsaOaepSha256Encrypt(Data("próba".utf8), publicKey: imported)
                T.expect(!roundTrip.isEmpty, "klucz zaimportowany z SPKI musi umożliwiać szyfrowanie")
            }

            T.test("odrzuca materiał, który nie jest kluczem") {
                T.throwsError("przypadkowe bajty") {
                    _ = try Crypto.publicKey(fromDER: Data([0x01, 0x02, 0x03, 0x04]))
                }
            }

            T.test("szyfruje i odszyfrowuje paczkę AES-256-CBC") {
                let key = Crypto.randomBytes(32)
                let iv = Crypto.randomBytes(16)
                // Treść dłuższa niż blok i niebędąca jego wielokrotnością — sprawdza dopełnienie PKCS#7.
                let payload = Data(("Zawartość paczki faktur — ąćęłńóśźż " + String(repeating: "x", count: 1000)).utf8)

                let cipher = try Crypto.aes256CBCEncrypt(payload, key: key, iv: iv)
                T.expect(cipher.count % 16 == 0, "szyfrogram musi być wielokrotnością bloku")
                T.expect(cipher != payload, "szyfrogram musi różnić się od tekstu jawnego")

                let plain = try Crypto.aes256CBCDecrypt(cipher, key: key, iv: iv)
                T.equal(plain, payload, "odszyfrowana zawartość paczki")
            }

            T.test("odrzuca odszyfrowanie niewłaściwym kluczem") {
                let key = Crypto.randomBytes(32)
                let iv = Crypto.randomBytes(16)
                let cipher = try Crypto.aes256CBCEncrypt(Data("dane".utf8), key: key, iv: iv)

                // Zły klucz albo psuje dopełnienie (błąd), albo daje inną treść — nigdy oryginał.
                let wrongKey = Crypto.randomBytes(32)
                if let plain = try? Crypto.aes256CBCDecrypt(cipher, key: wrongKey, iv: iv) {
                    T.expect(plain != Data("dane".utf8), "niewłaściwy klucz nie może odtworzyć treści")
                }
            }

            T.test("liczy skróty SHA-256 w Base64 i Base64URL") {
                // Wektor kontrolny: SHA-256 pustego wejścia.
                let empty = Crypto.sha256Base64(Data())
                T.equal(empty, "47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=", "SHA-256 pustych danych")

                let url = Crypto.base64ToBase64URL("a+b/c=")
                T.equal(url, "a-b_c", "konwersja Base64 na Base64URL usuwa dopełnienie")

                let hashURL = Crypto.sha256Base64URL(Data("faktura".utf8))
                T.expect(!hashURL.contains("+") && !hashURL.contains("/") && !hashURL.contains("="),
                         "Base64URL nie może zawierać znaków +, / ani =")
            }

            T.test("buduje link weryfikacyjny kodu QR zgodnie ze specyfikacją") {
                let issueDate = InvoiceParser.parseDate("2026-02-01")!
                let url = QrCode.verificationURL(
                    sellerNip: "1111111111",
                    issueDate: issueDate,
                    // Base64 odpowiadający skrótowi z przykładu w dokumentacji:
                    // znaki „+" przechodzą w „-", a dopełnienie „=" jest usuwane.
                    invoiceHashBase64: "UtQp9Gpc51y+u3xApZjIjgkpZ01js+J8KflSPW8WzIE=",
                    baseURL: "https://qr-test.ksef.mf.gov.pl"
                )
                // Postać linku wprost z dokumentacji MF (kody-qr.md).
                T.equal(url,
                        "https://qr-test.ksef.mf.gov.pl/invoice/1111111111/01-02-2026/UtQp9Gpc51y-u3xApZjIjgkpZ01js-J8KflSPW8WzIE",
                        "link weryfikacyjny KOD I")
            }

            T.test("nie buduje linku QR bez kompletu danych") {
                T.isNil(QrCode.verificationURL(sellerNip: nil, issueDate: Date(), invoiceHashBase64: "abc"),
                        "brak NIP-u sprzedawcy")
                T.isNil(QrCode.verificationURL(sellerNip: "1111111111", issueDate: nil, invoiceHashBase64: "abc"),
                        "brak daty wystawienia")
                T.isNil(QrCode.verificationURL(sellerNip: "1111111111", issueDate: Date(), invoiceHashBase64: nil),
                        "brak skrótu faktury")
            }

            T.test("generuje obraz kodu QR") {
                let image = QrCode.image(for: "https://qr.ksef.mf.gov.pl/invoice/1111111111/01-02-2026/abc",
                                         pixelSize: 240)
                T.notNil(image, "obraz kodu QR")
                if let image {
                    T.expect(image.width >= 100 && image.width == image.height,
                             "kod QR musi być kwadratowy i odpowiednio duży (otrzymano \(image.width)×\(image.height))")
                }
            }
        }
    }
}
