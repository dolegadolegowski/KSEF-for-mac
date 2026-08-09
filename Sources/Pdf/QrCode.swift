import CoreGraphics
import CoreImage
import Foundation

/// Generator kodów QR weryfikujących fakturę (KOD I).
///
/// Link i sposób jego budowy pochodzą z dokumentu `kody-qr.md` w repozytorium
/// `CIRFMF/ksef-api`: adres środowiska, NIP sprzedawcy, data wystawienia w formacie
/// DD-MM-RRRR oraz skrót SHA-256 pliku faktury zakodowany Base64URL.
enum QrCode {
    /// Buduje link weryfikacyjny KOD I.
    ///
    /// - Parameters:
    ///   - sellerNip: NIP sprzedawcy (Podmiot1).
    ///   - issueDate: data wystawienia faktury (pole P_1).
    ///   - invoiceHashBase64: skrót SHA-256 faktury w Base64 — z metadanych KSeF
    ///     albo policzony z oryginalnego XML.
    ///   - baseURL: adres serwisu weryfikacji; produkcyjnie `https://qr.ksef.mf.gov.pl`.
    static func verificationURL(
        sellerNip: String?,
        issueDate: Date?,
        invoiceHashBase64: String?,
        baseURL: String = KsefHTTP.productionQrBaseURL
    ) -> String? {
        guard let sellerNip, !sellerNip.isEmpty,
              let issueDate,
              let invoiceHashBase64, !invoiceHashBase64.isEmpty
        else { return nil }

        let nip = Nip.normalize(sellerNip)
        let date = Fmt.qrDate(issueDate)
        let hash = Crypto.base64ToBase64URL(invoiceHashBase64)
        return "\(baseURL)/invoice/\(nip)/\(date)/\(hash)"
    }

    /// Renderuje kod QR zgodny z ISO/IEC 18004 jako obraz rastrowy.
    ///
    /// - Parameter pixelSize: docelowy bok obrazu w pikselach; skalowanie jest całkowite,
    ///   żeby moduły kodu pozostały ostre.
    static func image(for text: String, pixelSize: CGFloat = 480) -> CGImage? {
        guard let data = text.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }

        filter.setValue(data, forKey: "inputMessage")
        // Poziom korekcji „M" — kompromis między gęstością a odpornością na uszkodzenia wydruku.
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let output = filter.outputImage else { return nil }

        // Skalujemy całkowitą krotnością, żeby uniknąć rozmycia na granicach modułów.
        let scale = max(1, (pixelSize / output.extent.width).rounded(.down))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext(options: [.useSoftwareRenderer: true])
        return context.createCGImage(scaled, from: scaled.extent)
    }
}
