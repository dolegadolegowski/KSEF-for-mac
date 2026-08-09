import Foundation

/// Lekkie drzewo XML budowane na `XMLParser` z Foundation.
///
/// Węzły są indeksowane po nazwie lokalnej, bo schematy faktur różnią się wyłącznie
/// przestrzenią nazw — struktura elementów jest w FA(2) i FA(3) w większości wspólna.
final class XmlNode {
    let name: String
    let namespaceURI: String?
    var text: String = ""
    var attributes: [String: String]
    private(set) var children: [XmlNode] = []
    private(set) weak var parent: XmlNode?

    private var childIndex: [String: [XmlNode]] = [:]

    init(name: String, namespaceURI: String? = nil, attributes: [String: String] = [:]) {
        self.name = name
        self.namespaceURI = namespaceURI
        self.attributes = attributes
    }

    func append(_ child: XmlNode) {
        child.parent = self
        children.append(child)
        childIndex[child.name, default: []].append(child)
    }

    /// Pierwsze dziecko o podanej nazwie lokalnej.
    func child(_ name: String) -> XmlNode? {
        childIndex[name]?.first
    }

    /// Wszystkie dzieci o podanej nazwie lokalnej.
    func all(_ name: String) -> [XmlNode] {
        childIndex[name] ?? []
    }

    /// Zawartość tekstowa dziecka, przycięta; pusty ciąg traktowany jest jak brak wartości.
    func string(_ name: String) -> String? {
        guard let value = child(name)?.trimmedText, !value.isEmpty else { return nil }
        return value
    }

    /// Zawartość tekstowa wskazana ścieżką nazw lokalnych, np. `path("Platnosc", "TerminPlatnosci", "Termin")`.
    func string(path: [String]) -> String? {
        guard let node = node(path: path) else { return nil }
        let value = node.trimmedText
        return value.isEmpty ? nil : value
    }

    func node(path: [String]) -> XmlNode? {
        var current: XmlNode? = self
        for component in path {
            current = current?.child(component)
            if current == nil { return nil }
        }
        return current
    }

    /// Kwota z pola o podanej nazwie, parsowana na `Decimal`.
    func decimal(_ name: String) -> Decimal? {
        guard let raw = string(name) else { return nil }
        return Decimal(ksefString: raw)
    }

    /// Wartość logiczna zapisana w schemacie jako „1"/„0" lub „true"/„false".
    func bool(_ name: String) -> Bool? {
        guard let raw = string(name)?.lowercased() else { return nil }
        switch raw {
        case "1", "true", "tak": return true
        case "0", "false", "nie": return false
        default: return nil
        }
    }

    var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pierwszy potomek o danej nazwie na dowolnej głębokości — używane dla pól,
    /// których zagnieżdżenie różni się między wersjami schematu.
    func firstDescendant(_ name: String) -> XmlNode? {
        if let direct = child(name) { return direct }
        for child in children {
            if let found = child.firstDescendant(name) { return found }
        }
        return nil
    }

    /// Spłaszczona lista „ścieżka → wartość" dla wszystkich liści.
    /// Zasila zakładkę „Wszystkie pola" w podglądzie faktury.
    func flattened(prefix: String = "", ordinal: Int? = nil) -> [(path: String, value: String)] {
        var out: [(String, String)] = []
        // Numer porządkowy dopisujemy do nazwy własnego elementu, nie do ścieżki rodzica,
        // żeby powtarzalne pozycje były rozróżnialne jako „FaWiersz [3]".
        let label = ordinal.map { "\(name) [\($0)]" } ?? name
        let path = prefix.isEmpty ? label : "\(prefix) › \(label)"

        if children.isEmpty {
            let value = trimmedText
            if !value.isEmpty { out.append((path, value)) }
        } else {
            var counters: [String: Int] = [:]
            var totals: [String: Int] = [:]
            for child in children { totals[child.name, default: 0] += 1 }
            for child in children {
                let index = counters[child.name, default: 0] + 1
                counters[child.name] = index
                let childOrdinal = (totals[child.name] ?? 1) > 1 ? index : nil
                out.append(contentsOf: child.flattened(prefix: path, ordinal: childOrdinal))
            }
        }
        return out
    }
}

/// Buduje drzewo `XmlNode` z surowych bajtów XML.
final class XmlTreeBuilder: NSObject, XMLParserDelegate {
    private var root: XmlNode?
    private var stack: [XmlNode] = []
    private var parseError: Error?

    enum XmlError: LocalizedError {
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case let .malformed(detail):
                return "Nie udało się odczytać dokumentu XML faktury: \(detail)"
            }
        }
    }

    static func parse(_ data: Data) throws -> XmlNode {
        let builder = XmlTreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        // Nazwy lokalne bez prefiksów — dzięki temu ten sam kod obsługuje FA(2), FA(3) i PEF.
        parser.shouldProcessNamespaces = true

        guard parser.parse(), let root = builder.root else {
            let detail = builder.parseError?.localizedDescription
                ?? parser.parserError?.localizedDescription
                ?? "dokument jest pusty lub niepoprawny"
            throw XmlError.malformed(detail)
        }
        return root
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?,
                attributes: [String: String]) {
        let node = XmlNode(name: elementName, namespaceURI: namespaceURI, attributes: attributes)
        if let current = stack.last {
            current.append(node)
        } else {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) {
            stack.last?.text += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if !stack.isEmpty { stack.removeLast() }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred error: Error) {
        parseError = error
    }
}
