import Compression
import Foundation

/// Minimalny czytnik archiwów ZIP oparty wyłącznie na frameworku `Compression`.
///
/// Obsługuje metody „stored" (0) i „deflate" (8) oraz rozszerzenie ZIP64 w zakresie
/// rozmiarów i przesunięć — tyle wystarcza dla paczek eksportu faktur z KSeF.
enum ZipArchive {
    struct Entry {
        let name: String
        let data: Data
    }

    enum ZipError: LocalizedError {
        case notAnArchive
        case corrupted(String)
        case unsupportedMethod(UInt16)

        var errorDescription: String? {
            switch self {
            case .notAnArchive:
                return "Pobrana paczka nie jest poprawnym archiwum ZIP."
            case let .corrupted(detail):
                return "Archiwum ZIP jest uszkodzone: \(detail)"
            case let .unsupportedMethod(method):
                return "Nieobsługiwana metoda kompresji w archiwum ZIP: \(method)."
            }
        }
    }

    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    private static let zip64EndOfCentralDirectorySignature: UInt32 = 0x0606_4B50
    private static let centralDirectorySignature: UInt32 = 0x0201_4B50
    private static let localHeaderSignature: UInt32 = 0x0403_4B50

    /// Rozpakowuje wszystkie pliki z archiwum. Katalogi są pomijane.
    static func entries(in archive: Data) throws -> [Entry] {
        let bytes = [UInt8](archive)
        guard bytes.count > 22 else { throw ZipError.notAnArchive }

        let eocd = try findEndOfCentralDirectory(bytes)
        var directoryOffset = Int(read32(bytes, eocd + 16))
        var entryCount = Int(read16(bytes, eocd + 10))

        // ZIP64: wartości 0xFFFF/0xFFFFFFFF oznaczają, że prawdziwe dane są w rekordzie ZIP64.
        if directoryOffset == 0xFFFF_FFFF || entryCount == 0xFFFF {
            let locator = eocd - 20
            if locator >= 0, read32(bytes, locator) == 0x0706_4B50 {
                let zip64Offset = Int(read64(bytes, locator + 8))
                if zip64Offset >= 0, zip64Offset + 56 <= bytes.count,
                   read32(bytes, zip64Offset) == zip64EndOfCentralDirectorySignature {
                    entryCount = Int(read64(bytes, zip64Offset + 32))
                    directoryOffset = Int(read64(bytes, zip64Offset + 48))
                }
            }
        }

        guard directoryOffset >= 0, directoryOffset < bytes.count else {
            throw ZipError.corrupted("nieprawidłowe przesunięcie katalogu centralnego")
        }

        var results: [Entry] = []
        var cursor = directoryOffset

        for _ in 0 ..< entryCount {
            guard cursor + 46 <= bytes.count, read32(bytes, cursor) == centralDirectorySignature else { break }

            let method = read16(bytes, cursor + 10)
            var compressedSize = Int(read32(bytes, cursor + 20))
            var uncompressedSize = Int(read32(bytes, cursor + 24))
            let nameLength = Int(read16(bytes, cursor + 28))
            let extraLength = Int(read16(bytes, cursor + 30))
            let commentLength = Int(read16(bytes, cursor + 32))
            var localOffset = Int(read32(bytes, cursor + 42))

            let nameStart = cursor + 46
            guard nameStart + nameLength <= bytes.count else {
                throw ZipError.corrupted("nazwa pliku wykracza poza archiwum")
            }
            let name = String(decoding: bytes[nameStart ..< nameStart + nameLength], as: UTF8.self)

            // Pola ZIP64 w sekcji „extra".
            if uncompressedSize == 0xFFFF_FFFF || compressedSize == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                let extraStart = nameStart + nameLength
                var p = extraStart
                let extraEnd = min(extraStart + extraLength, bytes.count)
                while p + 4 <= extraEnd {
                    let headerId = read16(bytes, p)
                    let size = Int(read16(bytes, p + 2))
                    var q = p + 4
                    if headerId == 0x0001 {
                        if uncompressedSize == 0xFFFF_FFFF, q + 8 <= extraEnd {
                            uncompressedSize = Int(read64(bytes, q)); q += 8
                        }
                        if compressedSize == 0xFFFF_FFFF, q + 8 <= extraEnd {
                            compressedSize = Int(read64(bytes, q)); q += 8
                        }
                        if localOffset == 0xFFFF_FFFF, q + 8 <= extraEnd {
                            localOffset = Int(read64(bytes, q))
                        }
                        break
                    }
                    p += 4 + size
                }
            }

            cursor = nameStart + nameLength + extraLength + commentLength

            // Katalogi rozpoznajemy po zakończeniu nazwy ukośnikiem.
            if name.hasSuffix("/") { continue }

            // Nagłówek lokalny wskazuje faktyczny początek danych — długości pól
            // potrafią się różnić od tych w katalogu centralnym.
            guard localOffset + 30 <= bytes.count,
                  read32(bytes, localOffset) == localHeaderSignature else {
                throw ZipError.corrupted("brak nagłówka lokalnego dla \(name)")
            }
            let localNameLength = Int(read16(bytes, localOffset + 26))
            let localExtraLength = Int(read16(bytes, localOffset + 28))
            let dataStart = localOffset + 30 + localNameLength + localExtraLength
            guard dataStart + compressedSize <= bytes.count else {
                throw ZipError.corrupted("dane pliku \(name) wykraczają poza archiwum")
            }

            let payload = Data(bytes[dataStart ..< dataStart + compressedSize])
            let content: Data
            switch method {
            case 0:
                content = payload
            case 8:
                content = try inflate(payload, expectedSize: uncompressedSize)
            default:
                throw ZipError.unsupportedMethod(method)
            }
            results.append(Entry(name: name, data: content))
        }

        return results
    }

    /// Dekompresja „raw deflate". W API Apple `COMPRESSION_ZLIB` oznacza właśnie surowy strumień
    /// DEFLATE, bez nagłówka zlib — dokładnie to, co zapisuje ZIP.
    static func inflate(_ input: Data, expectedSize: Int) throws -> Data {
        guard !input.isEmpty else { return Data() }
        // Gdy rozmiar docelowy jest nieznany, przyjmujemy hojny zapas i przycinamy wynik.
        let capacity = expectedSize > 0 ? expectedSize : max(input.count * 8, 64 * 1024)

        var output = Data(count: capacity)
        let written: Int = output.withUnsafeMutableBytes { outPtr in
            input.withUnsafeBytes { inPtr in
                guard let dst = outPtr.bindMemory(to: UInt8.self).baseAddress,
                      let src = inPtr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dst, capacity, src, input.count, nil, COMPRESSION_ZLIB)
            }
        }

        guard written > 0 else {
            throw ZipError.corrupted("dekompresja strumienia DEFLATE nie powiodła się")
        }
        if written < output.count { output.removeSubrange(written ..< output.count) }
        return output
    }

    // MARK: - Odczyt pól

    private static func findEndOfCentralDirectory(_ bytes: [UInt8]) throws -> Int {
        // Komentarz archiwum ma maksymalnie 65535 bajtów, więc dalej wstecz nie ma sensu szukać.
        let minOffset = max(0, bytes.count - 22 - 65535)
        var i = bytes.count - 22
        while i >= minOffset {
            if read32(bytes, i) == endOfCentralDirectorySignature { return i }
            i -= 1
        }
        throw ZipError.notAnArchive
    }

    private static func read16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 2 <= bytes.count, offset >= 0 else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count, offset >= 0 else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func read64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        guard offset + 8 <= bytes.count, offset >= 0 else { return 0 }
        var value: UInt64 = 0
        for i in (0 ..< 8).reversed() {
            value = (value << 8) | UInt64(bytes[offset + i])
        }
        return value
    }

    // MARK: - Zapis (na potrzeby archiwum ZIP z załącznikami e-maila)

    /// Buduje archiwum ZIP bez kompresji. Używane, gdy załączniki e-maila przekraczają próg
    /// rozmiaru i użytkownik wybierze spakowanie ich w jeden plik.
    static func makeStoredArchive(files: [(name: String, data: Data)]) -> Data {
        var output = Data()
        var directory = Data()
        var offset = 0

        for file in files {
            let nameBytes = Array(file.name.utf8)
            let crc = crc32(file.data)
            let size = UInt32(file.data.count)

            var local = Data()
            local.appendLE(localHeaderSignature)
            local.appendLE(UInt16(20))          // wersja wymagana do rozpakowania
            local.appendLE(UInt16(0))           // flagi
            local.appendLE(UInt16(0))           // metoda: stored
            local.appendLE(UInt16(0))           // czas
            local.appendLE(UInt16(0))           // data
            local.appendLE(crc)
            local.appendLE(size)
            local.appendLE(size)
            local.appendLE(UInt16(nameBytes.count))
            local.appendLE(UInt16(0))           // długość pola extra
            local.append(contentsOf: nameBytes)
            local.append(file.data)

            var central = Data()
            central.appendLE(centralDirectorySignature)
            central.appendLE(UInt16(20))        // wersja twórcy
            central.appendLE(UInt16(20))        // wersja wymagana
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(crc)
            central.appendLE(size)
            central.appendLE(size)
            central.appendLE(UInt16(nameBytes.count))
            central.appendLE(UInt16(0))         // extra
            central.appendLE(UInt16(0))         // komentarz
            central.appendLE(UInt16(0))         // numer dysku
            central.appendLE(UInt16(0))         // atrybuty wewnętrzne
            central.appendLE(UInt32(0))         // atrybuty zewnętrzne
            central.appendLE(UInt32(offset))
            central.append(contentsOf: nameBytes)

            output.append(local)
            directory.append(central)
            offset += local.count
        }

        let directoryOffset = offset
        output.append(directory)

        var eocd = Data()
        eocd.appendLE(endOfCentralDirectorySignature)
        eocd.appendLE(UInt16(0))
        eocd.appendLE(UInt16(0))
        eocd.appendLE(UInt16(files.count))
        eocd.appendLE(UInt16(files.count))
        eocd.appendLE(UInt32(directory.count))
        eocd.appendLE(UInt32(directoryOffset))
        eocd.appendLE(UInt16(0))
        output.append(eocd)

        return output
    }

    /// CRC-32 (wielomian IEEE) — wymagany w nagłówkach ZIP.
    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0 ..< 256 {
            var c = UInt32(i)
            for _ in 0 ..< 8 {
                c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
