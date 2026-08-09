import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Generator wizualizacji faktury w formacie PDF.
///
/// Dokumentem źródłowym pozostaje faktura ustrukturyzowana w KSeF — PDF jest wyłącznie
/// jej wizualizacją, co jest wprost napisane w stopce każdej strony.
///
/// Układ odpowiada typowej polskiej fakturze VAT i zawiera elementy wymagane
/// art. 106e ustawy o podatku od towarów i usług.
enum PdfRenderer {
    // MARK: - Geometria strony

    /// A4 w punktach typograficznych (210 × 297 mm).
    static let pageWidth: CGFloat = 595.276
    static let pageHeight: CGFloat = 841.890

    /// Margines 17 mm.
    private static let margin: CGFloat = 48
    private static var contentWidth: CGFloat { pageWidth - 2 * margin }
    /// Pas u dołu strony zarezerwowany na numerację.
    private static let footerReserve: CGFloat = 26

    private static let qrSide: CGFloat = 82

    // MARK: - Kolory i czcionki

    private static let inkColor = CGColor(gray: 0.08, alpha: 1)
    private static let mutedColor = CGColor(gray: 0.42, alpha: 1)
    private static let ruleColor = CGColor(gray: 0.72, alpha: 1)
    private static let panelColor = CGColor(gray: 0.945, alpha: 1)

    /// Czcionka systemowa ma komplet polskich znaków diakrytycznych i osadza się w PDF.
    private static func font(_ size: CGFloat, bold: Bool = false) -> CTFont {
        NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular) as CTFont
    }

    // MARK: - Wejście

    /// Renderuje fakturę do dokumentu PDF.
    static func render(_ invoice: Invoice, qrBaseURL: String = KsefHTTP.productionQrBaseURL) -> Data {
        let layout = InvoiceLayout(invoice: invoice, qrBaseURL: qrBaseURL)

        // Przebieg pomiarowy: ustala liczbę stron, żeby numeracja „Strona X z Y" była poprawna.
        let totalPages = layout.run(context: nil, totalPages: nil)

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { return Data() }
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        var info: [String: Any] = [
            kCGPDFContextTitle as String: invoice.invoiceNumber,
            kCGPDFContextSubject as String: invoice.ksefNumber,
            kCGPDFContextCreator as String: AppInfo.displayVersion,
        ]
        if let seller = invoice.seller.name { info[kCGPDFContextAuthor as String] = seller }

        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary) else {
            return Data()
        }
        _ = layout.run(context: context, totalPages: totalPages)
        context.closePDF()
        return data as Data
    }

    // MARK: - Rysowanie tekstu

    private static func paragraphStyle(_ alignment: NSTextAlignment) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byWordWrapping
        return style
    }

    /// Buduje tekst z atrybutami CoreText.
    ///
    /// Używamy kluczy `kCT*` zamiast odpowiedników AppKit, bo to `CTFramesetter` rysuje
    /// zawartość i tylko te klucze odczytuje — w szczególności kolor musi być `CGColor`.
    private static func attributed(_ text: String,
                                   font: CTFont,
                                   color: CGColor = inkColor,
                                   alignment: NSTextAlignment = .left) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: color,
            kCTParagraphStyleAttributeName as NSAttributedString.Key: paragraphStyle(alignment),
        ])
    }

    /// Rysuje (albo tylko mierzy) blok tekstu i zwraca jego wysokość.
    ///
    /// `context == nil` oznacza przebieg pomiarowy — używany do wyznaczenia podziału na strony.
    @discardableResult
    private static func text(_ string: String,
                             font ctFont: CTFont,
                             x: CGFloat,
                             top: CGFloat,
                             width: CGFloat,
                             color: CGColor = inkColor,
                             alignment: NSTextAlignment = .left,
                             context: CGContext?) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        let attributed = attributed(string, font: ctFont, color: color, alignment: alignment)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)

        var fitRange = CFRange()
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: width, height: .greatestFiniteMagnitude),
            &fitRange
        )
        // Zapas jednego punktu chroni przed obcięciem ostatniego wiersza przy zaokrągleniu.
        let height = ceil(suggested.height) + 1

        if let context {
            let rect = CGRect(x: x, y: pageHeight - top - height, width: width, height: height)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: 0, length: 0),
                CGPath(rect: rect, transform: nil),
                nil
            )
            CTFrameDraw(frame, context)
        }
        return height
    }

    private static func line(from x1: CGFloat, to x2: CGFloat, top: CGFloat,
                             color: CGColor = ruleColor, width: CGFloat = 0.5,
                             context: CGContext?) {
        guard let context else { return }
        context.saveGState()
        context.setStrokeColor(color)
        context.setLineWidth(width)
        context.move(to: CGPoint(x: x1, y: pageHeight - top))
        context.addLine(to: CGPoint(x: x2, y: pageHeight - top))
        context.strokePath()
        context.restoreGState()
    }

    private static func rect(x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat,
                             fill: CGColor, context: CGContext?) {
        guard let context else { return }
        context.saveGState()
        context.setFillColor(fill)
        context.fill(CGRect(x: x, y: pageHeight - top - height, width: width, height: height))
        context.restoreGState()
    }

    // MARK: - Układ dokumentu

    /// Realizuje układ faktury. Ten sam kod wykonuje przebieg pomiarowy i rysujący,
    /// dzięki czemu podział na strony jest w obu identyczny.
    private final class InvoiceLayout {
        private let invoice: Invoice
        private let qrBaseURL: String

        private var context: CGContext?
        private var totalPages: Int?
        private var page = 0
        private var top: CGFloat = 0

        /// Kolumny tabeli pozycji; szerokości dobrane tak, by zmieścić się w A4 pionowo.
        private struct Column {
            let title: String
            let width: CGFloat
            let alignment: NSTextAlignment
        }

        private let showsDiscount: Bool
        private let columns: [Column]

        init(invoice: Invoice, qrBaseURL: String) {
            self.invoice = invoice
            self.qrBaseURL = qrBaseURL
            // Kolumnę rabatu pokazujemy tylko wtedy, gdy którakolwiek pozycja go zawiera —
            // inaczej zabierałaby miejsce nazwie towaru.
            showsDiscount = invoice.lines.contains { ($0.discount ?? 0) != 0 }

            var columns: [Column] = [
                Column(title: "Lp.", width: 20, alignment: .left),
                Column(title: "Nazwa towaru lub usługi", width: 0, alignment: .left),
                Column(title: "Ilość", width: 38, alignment: .right),
                Column(title: "J.m.", width: 28, alignment: .left),
                Column(title: "Cena netto", width: 52, alignment: .right),
            ]
            if showsDiscount {
                columns.append(Column(title: "Rabat", width: 42, alignment: .right))
            }
            columns.append(contentsOf: [
                Column(title: "Stawka", width: 34, alignment: .right),
                Column(title: "Wartość netto", width: 56, alignment: .right),
                Column(title: "Kwota VAT", width: 52, alignment: .right),
                Column(title: "Wartość brutto", width: 58, alignment: .right),
            ])

            let fixed = columns.reduce(0) { $0 + $1.width }
            let flexible = PdfRenderer.contentWidth - fixed
            columns[1] = Column(title: columns[1].title, width: max(90, flexible), alignment: .left)
            self.columns = columns
        }

        /// Wykonuje układ i zwraca liczbę stron.
        func run(context: CGContext?, totalPages: Int?) -> Int {
            self.context = context
            self.totalPages = totalPages
            page = 0

            beginPage(firstPageHeader: true)

            if invoice.lines.isEmpty {
                _ = flow(block: { ctx, top in
                    PdfRenderer.text("Faktura nie zawiera pozycji szczegółowych.",
                                     font: PdfRenderer.font(8), x: PdfRenderer.margin, top: top,
                                     width: PdfRenderer.contentWidth,
                                     color: PdfRenderer.mutedColor, context: ctx)
                }, height: 14)
            } else {
                drawTableHeader()
                for line in invoice.lines {
                    let height = measureRow(line)
                    // Nowa strona wymaga ponownego nagłówka tabeli — pozycje nie mogą się zgubić
                    // ani zmienić kolejności.
                    if !fits(height) {
                        endPage()
                        beginPage(firstPageHeader: false)
                        drawTableHeader()
                    }
                    drawRow(line, height: height)
                }
                PdfRenderer.line(from: PdfRenderer.margin,
                                 to: PdfRenderer.pageWidth - PdfRenderer.margin,
                                 top: top, context: context)
                top += 10
            }

            for block in trailerBlocks() {
                let height = block(nil, 0)
                if !fits(height) {
                    endPage()
                    beginPage(firstPageHeader: false)
                }
                _ = block(context, top)
                top += height
            }

            endPage()
            return page
        }

        // MARK: Strony

        private var pageLimit: CGFloat { PdfRenderer.pageHeight - PdfRenderer.margin - PdfRenderer.footerReserve }

        private func fits(_ height: CGFloat) -> Bool {
            top + height <= pageLimit
        }

        private func beginPage(firstPageHeader: Bool) {
            page += 1
            context?.beginPDFPage(nil)
            top = PdfRenderer.margin
            if firstPageHeader {
                drawFullHeader()
            } else {
                drawContinuationHeader()
            }
        }

        private func endPage() {
            drawPageFooter()
            context?.endPDFPage()
        }

        /// Wykonuje blok, przechodząc wcześniej na nową stronę, jeśli się nie mieści.
        private func flow(block: (CGContext?, CGFloat) -> CGFloat, height: CGFloat) -> CGFloat {
            if !fits(height) {
                endPage()
                beginPage(firstPageHeader: false)
            }
            let used = block(context, top)
            top += used
            return used
        }

        // MARK: Nagłówek

        private func drawFullHeader() {
            let ctx = context
            let left = PdfRenderer.margin
            let right = PdfRenderer.pageWidth - PdfRenderer.margin
            let headerTop = top

            // Kod QR w prawym górnym rogu, z numerem KSeF jako podpisem.
            let qrURL = QrCode.verificationURL(
                sellerNip: invoice.seller.nip,
                issueDate: invoice.issueDate,
                invoiceHashBase64: invoice.invoiceHashBase64,
                baseURL: qrBaseURL
            )
            if let qrURL, let image = QrCode.image(for: qrURL), let ctx {
                let x = right - PdfRenderer.qrSide
                let y = PdfRenderer.pageHeight - headerTop - PdfRenderer.qrSide
                ctx.draw(image, in: CGRect(x: x, y: y, width: PdfRenderer.qrSide, height: PdfRenderer.qrSide))
            }
            if qrURL != nil {
                // Zgodnie ze specyfikacją MF pod kodem umieszcza się numer KSeF faktury.
                // Pole jest szersze od samego kodu, żeby numer zmieścił się w jednym wierszu.
                let labelWidth: CGFloat = 150
                _ = PdfRenderer.text(invoice.ksefNumber.isEmpty ? "OFFLINE" : invoice.ksefNumber,
                                     font: PdfRenderer.font(5.6),
                                     x: right - labelWidth,
                                     top: headerTop + PdfRenderer.qrSide + 3,
                                     width: labelWidth,
                                     color: PdfRenderer.mutedColor,
                                     alignment: .right, context: ctx)
            }

            let titleWidth = PdfRenderer.contentWidth - PdfRenderer.qrSide - 16

            var cursor = headerTop
            cursor += PdfRenderer.text(invoice.kind.displayName,
                                       font: PdfRenderer.font(17, bold: true),
                                       x: left, top: cursor, width: titleWidth, context: ctx)
            cursor += PdfRenderer.text("nr \(invoice.invoiceNumber)",
                                       font: PdfRenderer.font(11, bold: true),
                                       x: left, top: cursor, width: titleWidth, context: ctx)
            cursor += 4

            var meta: [String] = []
            if let issueDate = invoice.issueDate {
                meta.append("Data wystawienia: \(Fmt.isoDate(issueDate))")
            }
            if let place = invoice.issuePlace {
                meta.append("Miejsce wystawienia: \(place)")
            }
            if let saleDate = invoice.saleDate {
                meta.append("Data dokonania dostawy / wykonania usługi: \(Fmt.isoDate(saleDate))")
            }
            if let acquisition = invoice.acquisitionDate {
                meta.append("Data przyjęcia w KSeF: \(Fmt.dateTime(acquisition))")
            }
            cursor += PdfRenderer.text(meta.joined(separator: "\n"),
                                       font: PdfRenderer.font(8),
                                       x: left, top: cursor, width: titleWidth, context: ctx)

            top = max(cursor, headerTop + PdfRenderer.qrSide + 12) + 8
            drawParties()
        }

        private func drawParties() {
            let ctx = context
            let gap: CGFloat = 14
            let columnWidth = (PdfRenderer.contentWidth - gap) / 2
            let leftX = PdfRenderer.margin
            let rightX = PdfRenderer.margin + columnWidth + gap
            let boxTop = top

            func partyText(_ party: Party) -> String {
                var lines: [String] = [party.displayName]
                if let identifier = party.identifierLabel { lines.append(identifier) }
                if let line1 = party.address.line1 { lines.append(line1) }
                if let line2 = party.address.line2 { lines.append(line2) }
                if let email = party.email { lines.append(email) }
                return lines.joined(separator: "\n")
            }

            let labelHeight: CGFloat = 12
            let sellerHeight = PdfRenderer.text(partyText(invoice.seller), font: PdfRenderer.font(8.5),
                                                x: leftX + 6, top: boxTop + labelHeight + 2,
                                                width: columnWidth - 12, context: nil)
            let buyerHeight = PdfRenderer.text(partyText(invoice.buyer), font: PdfRenderer.font(8.5),
                                               x: rightX + 6, top: boxTop + labelHeight + 2,
                                               width: columnWidth - 12, context: nil)
            let boxHeight = max(sellerHeight, buyerHeight) + labelHeight + 10

            PdfRenderer.rect(x: leftX, top: boxTop, width: columnWidth, height: boxHeight,
                             fill: PdfRenderer.panelColor, context: ctx)
            PdfRenderer.rect(x: rightX, top: boxTop, width: columnWidth, height: boxHeight,
                             fill: PdfRenderer.panelColor, context: ctx)

            _ = PdfRenderer.text("SPRZEDAWCA", font: PdfRenderer.font(7, bold: true),
                                 x: leftX + 6, top: boxTop + 5, width: columnWidth - 12,
                                 color: PdfRenderer.mutedColor, context: ctx)
            _ = PdfRenderer.text("NABYWCA", font: PdfRenderer.font(7, bold: true),
                                 x: rightX + 6, top: boxTop + 5, width: columnWidth - 12,
                                 color: PdfRenderer.mutedColor, context: ctx)

            _ = PdfRenderer.text(partyText(invoice.seller), font: PdfRenderer.font(8.5),
                                 x: leftX + 6, top: boxTop + labelHeight + 2,
                                 width: columnWidth - 12, context: ctx)
            _ = PdfRenderer.text(partyText(invoice.buyer), font: PdfRenderer.font(8.5),
                                 x: rightX + 6, top: boxTop + labelHeight + 2,
                                 width: columnWidth - 12, context: ctx)

            top = boxTop + boxHeight + 12
        }

        private func drawContinuationHeader() {
            let ctx = context
            let text = "\(invoice.kind.displayName) nr \(invoice.invoiceNumber) — ciąg dalszy"
            top += PdfRenderer.text(text, font: PdfRenderer.font(9, bold: true),
                                    x: PdfRenderer.margin, top: top,
                                    width: PdfRenderer.contentWidth, context: ctx)
            top += PdfRenderer.text("Numer KSeF: \(invoice.ksefNumber)",
                                    font: PdfRenderer.font(7),
                                    x: PdfRenderer.margin, top: top,
                                    width: PdfRenderer.contentWidth,
                                    color: PdfRenderer.mutedColor, context: ctx)
            top += 6
        }

        private func drawPageFooter() {
            guard let context else { return }
            let label: String
            if let totalPages {
                label = "Strona \(page) z \(totalPages)"
            } else {
                label = "Strona \(page)"
            }
            _ = PdfRenderer.text(label, font: PdfRenderer.font(7),
                                 x: PdfRenderer.margin,
                                 top: PdfRenderer.pageHeight - PdfRenderer.margin + 4,
                                 width: PdfRenderer.contentWidth,
                                 color: PdfRenderer.mutedColor,
                                 alignment: .right, context: context)
        }

        // MARK: Tabela pozycji

        private func drawTableHeader() {
            let ctx = context
            let headerHeight: CGFloat = 20

            PdfRenderer.rect(x: PdfRenderer.margin, top: top,
                             width: PdfRenderer.contentWidth, height: headerHeight,
                             fill: PdfRenderer.panelColor, context: ctx)

            var x = PdfRenderer.margin
            for column in columns {
                _ = PdfRenderer.text(column.title, font: PdfRenderer.font(6.6, bold: true),
                                     x: x + 3, top: top + 4, width: column.width - 6,
                                     alignment: column.alignment, context: ctx)
                x += column.width
            }
            top += headerHeight
            PdfRenderer.line(from: PdfRenderer.margin,
                             to: PdfRenderer.pageWidth - PdfRenderer.margin,
                             top: top, context: ctx)
        }

        /// Wartości komórek jednej pozycji. Gwiazdka oznacza kwotę wyliczoną przez aplikację.
        private func cells(for line: InvoiceLine) -> [String] {
            func amount(_ value: Decimal?, computed: Bool) -> String {
                guard let value else { return "—" }
                return Fmt.amount(value) + (computed ? "*" : "")
            }

            var values: [String] = [
                String(line.index),
                itemName(for: line),
                line.quantity.map { Fmt.quantity($0) } ?? "—",
                line.unit ?? "—",
                line.unitNetPrice.map {
                    Fmt.amount($0) + (line.computed.contains(.unitNetPrice) ? "*" : "")
                } ?? "—",
            ]
            if showsDiscount {
                values.append(line.discount.map { Fmt.amount($0) } ?? "—")
            }
            values.append(contentsOf: [
                line.vatRate ?? "—",
                amount(line.net, computed: line.computed.contains(.net)),
                amount(line.vat, computed: line.computed.contains(.vat)),
                amount(line.gross, computed: line.computed.contains(.gross)),
            ])
            return values
        }

        /// Nazwa pozycji wzbogacona o klasyfikacje i oznaczenia GTU.
        private func itemName(for line: InvoiceLine) -> String {
            var text = line.name ?? "—"
            var extras: [String] = []
            if let pkwiu = line.pkwiu { extras.append("PKWiU \(pkwiu)") }
            if let cn = line.cn { extras.append("CN \(cn)") }
            if let indeks = line.indeks { extras.append("indeks \(indeks)") }
            if !line.gtu.isEmpty { extras.append(line.gtu.joined(separator: ", ")) }
            if !line.procedures.isEmpty { extras.append(line.procedures.joined(separator: ", ")) }
            if !extras.isEmpty { text += "\n" + extras.joined(separator: " · ") }
            return text
        }

        private func measureRow(_ line: InvoiceLine) -> CGFloat {
            let values = cells(for: line)
            var height: CGFloat = 0
            for (index, column) in columns.enumerated() {
                let cellHeight = PdfRenderer.text(values[index], font: PdfRenderer.font(7),
                                                  x: 0, top: 0, width: column.width - 6,
                                                  alignment: column.alignment, context: nil)
                height = max(height, cellHeight)
            }
            return height + 7
        }

        private func drawRow(_ line: InvoiceLine, height: CGFloat) {
            let ctx = context
            let values = cells(for: line)
            var x = PdfRenderer.margin
            for (index, column) in columns.enumerated() {
                _ = PdfRenderer.text(values[index], font: PdfRenderer.font(7),
                                     x: x + 3, top: top + 3, width: column.width - 6,
                                     alignment: column.alignment, context: ctx)
                x += column.width
            }
            top += height
            PdfRenderer.line(from: PdfRenderer.margin,
                             to: PdfRenderer.pageWidth - PdfRenderer.margin,
                             top: top, color: CGColor(gray: 0.88, alpha: 1), context: ctx)
        }

        // MARK: Bloki końcowe

        /// Bloki poniżej tabeli pozycji. Każdy jest niepodzielny — jeśli nie mieści się
        /// na bieżącej stronie, przechodzi w całości na następną.
        private func trailerBlocks() -> [(CGContext?, CGFloat) -> CGFloat] {
            var blocks: [(CGContext?, CGFloat) -> CGFloat] = []

            blocks.append(vatSummaryBlock)
            blocks.append(totalsBlock)

            if invoice.currency != "PLN" {
                blocks.append(currencyBlock)
            }
            if let correction = invoice.correction {
                blocks.append { ctx, top in self.correctionBlock(correction, ctx, top) }
            }
            blocks.append(paymentBlock)

            if !invoice.annotations.printable.isEmpty {
                blocks.append(annotationsBlock)
            }
            if !invoice.additionalDescription.isEmpty {
                blocks.append(additionalBlock)
            }
            blocks.append(sourceNoticeBlock)
            return blocks
        }

        private func vatSummaryBlock(_ ctx: CGContext?, _ startTop: CGFloat) -> CGFloat {
            guard !invoice.vatSummary.isEmpty else { return 0 }
            var cursor = startTop
            cursor += PdfRenderer.text("Podsumowanie według stawek podatku",
                                       font: PdfRenderer.font(8, bold: true),
                                       x: PdfRenderer.margin, top: cursor,
                                       width: PdfRenderer.contentWidth, context: ctx)
            cursor += 3

            let widths: [CGFloat] = [110, 90, 90, 90]
            let titles = ["Stawka", "Wartość netto", "Kwota VAT", "Wartość brutto"]
            let tableWidth = widths.reduce(0, +)
            let originX = PdfRenderer.pageWidth - PdfRenderer.margin - tableWidth

            PdfRenderer.rect(x: originX, top: cursor, width: tableWidth, height: 15,
                             fill: PdfRenderer.panelColor, context: ctx)
            var x = originX
            for (index, title) in titles.enumerated() {
                _ = PdfRenderer.text(title, font: PdfRenderer.font(6.8, bold: true),
                                     x: x + 4, top: cursor + 3.5, width: widths[index] - 8,
                                     alignment: index == 0 ? .left : .right, context: ctx)
                x += widths[index]
            }
            cursor += 15

            for row in invoice.vatSummary {
                let values = [
                    row.rateLabel,
                    Fmt.amount(row.net),
                    Fmt.amount(row.vat) + (row.isVatComputed ? "*" : ""),
                    Fmt.amount(row.gross),
                ]
                var cellX = originX
                for (index, value) in values.enumerated() {
                    _ = PdfRenderer.text(value, font: PdfRenderer.font(7.4),
                                         x: cellX + 4, top: cursor + 3, width: widths[index] - 8,
                                         alignment: index == 0 ? .left : .right, context: ctx)
                    cellX += widths[index]
                }
                cursor += 14
                PdfRenderer.line(from: originX, to: originX + tableWidth, top: cursor,
                                 color: CGColor(gray: 0.88, alpha: 1), context: ctx)
            }

            // Kwota VAT przeliczona na złote — obowiązkowa dla faktur w walucie obcej.
            let vatInPLN = invoice.vatSummary.compactMap(\.vatInPLN).reduce(0, +)
            if vatInPLN != 0 {
                cursor += 3
                cursor += PdfRenderer.text("Kwota podatku w PLN: \(Fmt.money(vatInPLN, currency: "PLN"))",
                                           font: PdfRenderer.font(7.4, bold: true),
                                           x: originX, top: cursor, width: tableWidth,
                                           alignment: .right, context: ctx)
            }
            return cursor - startTop + 8
        }

        private func totalsBlock(_ ctx: CGContext?, _ startTop: CGFloat) -> CGFloat {
            var cursor = startTop
            let width: CGFloat = 250
            let originX = PdfRenderer.pageWidth - PdfRenderer.margin - width

            func row(_ label: String, _ value: String, bold: Bool = false, size: CGFloat = 8) -> CGFloat {
                let labelHeight = PdfRenderer.text(label, font: PdfRenderer.font(size, bold: bold),
                                                   x: originX, top: cursor, width: width - 110,
                                                   context: ctx)
                let valueHeight = PdfRenderer.text(value, font: PdfRenderer.font(size, bold: bold),
                                                   x: originX + width - 110, top: cursor, width: 110,
                                                   alignment: .right, context: ctx)
                return max(labelHeight, valueHeight)
            }

            cursor += row("Razem netto", Fmt.money(invoice.totalNet, currency: invoice.currency))
            cursor += row("Razem VAT", Fmt.money(invoice.totalVat, currency: invoice.currency))
            cursor += 2
            PdfRenderer.line(from: originX, to: originX + width, top: cursor, context: ctx)
            cursor += 4
            cursor += row("Razem brutto", Fmt.money(invoice.totalGross, currency: invoice.currency),
                          bold: true, size: 10)

            if let due = invoice.amountDue, due != invoice.totalGross {
                cursor += row("Do zapłaty", Fmt.money(due, currency: invoice.currency), bold: true, size: 10)
            } else if invoice.amountDue != nil {
                cursor += row("Do zapłaty", Fmt.money(invoice.amountDue!, currency: invoice.currency),
                              bold: true, size: 10)
            }
            if let paid = invoice.alreadyPaid, paid != 0 {
                cursor += row("Zapłacono", Fmt.money(paid, currency: invoice.currency))
            }
            return cursor - startTop + 10
        }

        private func currencyBlock(_ ctx: CGContext?, _ startTop: CGFloat) -> CGFloat {
            var parts = ["Waluta faktury: \(invoice.currency)"]
            if let rate = invoice.exchangeRate {
                parts.append("kurs przeliczeniowy: \(Fmt.quantity(rate))")
            }
            let height = PdfRenderer.text(parts.joined(separator: ", "),
                                          font: PdfRenderer.font(7.6),
                                          x: PdfRenderer.margin, top: startTop,
                                          width: PdfRenderer.contentWidth, context: ctx)
            return height + 6
        }

        private func correctionBlock(_ correction: CorrectionInfo,
                                     _ ctx: CGContext?, _ startTop: CGFloat) -> CGFloat {
            var cursor = startTop
            cursor += PdfRenderer.text("Dane faktury korygowanej",
                                       font: PdfRenderer.font(8, bold: true),
                                       x: PdfRenderer.margin, top: cursor,
                                       width: PdfRenderer.contentWidth, context: ctx)
            var lines: [String] = []
            if let number = correction.correctedInvoiceNumber {
                lines.append("Numer faktury korygowanej: \(number)")
            }
            if let date = correction.correctedIssueDate {
                lines.append("Data wystawienia faktury korygowanej: \(Fmt.isoDate(date))")
            }
            if let ksef = correction.correctedKsefNumber {
                lines.append("Numer KSeF faktury korygowanej: \(ksef)")
            } else if correction.correctedOutsideKsef {
                lines.append("Faktura korygowana została wystawiona poza KSeF.")
            }
            if let period = correction.correctedPeriod {
                lines.append("Okres, którego dotyczy korekta: \(period)")
            }
            if let reason = correction.reason {
                lines.append("Przyczyna korekty: \(reason)")
            }
            if let type = correction.correctionTypeDescription {
                lines.append("Typ korekty: \(type)")
            }
            cursor += PdfRenderer.text(lines.joined(separator: "\n"),
                                       font: PdfRenderer.font(7.6),
                                       x: PdfRenderer.margin, top: cursor,
                                       width: PdfRenderer.contentWidth, context: ctx)
            return cursor - startTop + 8
        }

        private func paymentBlock(_ ctx: CGContext?, _ startTop: CGFloat) -> CGFloat {
            var lines: [String] = []
            if let form = invoice.paymentForm { lines.append("Forma płatności: \(form)") }
            if let due = invoice.paymentDueDate { lines.append("Termin płatności: \(Fmt.isoDate(due))") }
            if let description = invoice.paymentDueDescription { lines.append("Termin: \(description)") }
            if invoice.isPaid {
                let date = invoice.paymentDate.map { " (\(Fmt.isoDate($0)))" } ?? ""
                lines.append("Faktura zapłacona\(date)")
            }
            for account in invoice.bankAccounts {
                guard let number = account.number else { continue }
                var text = account.isFactor ? "Rachunek faktora: \(number)" : "Rachunek bankowy: \(number)"
                if let bank = account.bankName { text += " — \(bank)" }
                lines.append(text)
            }
            guard !lines.isEmpty else { return 0 }

            var cursor = startTop
            cursor += PdfRenderer.text("Płatność", font: PdfRenderer.font(8, bold: true),
                                       x: PdfRenderer.margin, top: cursor,
                                       width: PdfRenderer.contentWidth, context: ctx)
            cursor += PdfRenderer.text(lines.joined(separator: "\n"),
                                       font: PdfRenderer.font(7.6),
                                       x: PdfRenderer.margin, top: cursor,
                                       width: PdfRenderer.contentWidth, context: ctx)
            return cursor - startTop + 8
        }

        private func annotationsBlock(_ ctx: CGContext?, _ startTop: CGFloat) -> CGFloat {
            var cursor = startTop
            cursor += PdfRenderer.text("Adnotacje", font: PdfRenderer.font(8, bold: true),
                                       x: PdfRenderer.margin, top: cursor,
                                       width: PdfRenderer.contentWidth, context: ctx)
            let text = invoice.annotations.printable.map { "• \($0)" }.joined(separator: "\n")
            cursor += PdfRenderer.text(text, font: PdfRenderer.font(7.6),
                                       x: PdfRenderer.margin, top: cursor,
                                       width: PdfRenderer.contentWidth, context: ctx)
            return cursor - startTop + 8
        }

        private func additionalBlock(_ ctx: CGContext?, _ startTop: CGFloat) -> CGFloat {
            var cursor = startTop
            cursor += PdfRenderer.text("Informacje dodatkowe", font: PdfRenderer.font(8, bold: true),
                                       x: PdfRenderer.margin, top: cursor,
                                       width: PdfRenderer.contentWidth, context: ctx)
            cursor += PdfRenderer.text(invoice.additionalDescription.joined(separator: "\n"),
                                       font: PdfRenderer.font(7.6),
                                       x: PdfRenderer.margin, top: cursor,
                                       width: PdfRenderer.contentWidth, context: ctx)
            return cursor - startTop + 8
        }

        /// Obowiązkowa informacja o charakterze dokumentu oraz legenda oznaczeń.
        private func sourceNoticeBlock(_ ctx: CGContext?, _ startTop: CGFloat) -> CGFloat {
            var cursor = startTop
            PdfRenderer.line(from: PdfRenderer.margin,
                             to: PdfRenderer.pageWidth - PdfRenderer.margin,
                             top: cursor, context: ctx)
            cursor += 6

            var notice = "Numer KSeF: \(invoice.ksefNumber)\n"
            notice += "Dokumentem źródłowym jest faktura ustrukturyzowana zapisana w Krajowym Systemie "
            notice += "e-Faktur. Niniejszy plik PDF stanowi wyłącznie jej wizualizację i nie jest oryginałem faktury."
            if invoice.hasComputedAmounts {
                notice += "\n* Wartość wyliczona przez aplikację na podstawie pozostałych pól faktury — "
                notice += "wystawca nie podał jej wprost w dokumencie źródłowym."
            }
            notice += "\nWizualizację wygenerowano \(Fmt.dateTime(Date())) w programie \(AppInfo.displayVersion)."

            cursor += PdfRenderer.text(notice, font: PdfRenderer.font(6.6),
                                       x: PdfRenderer.margin, top: cursor,
                                       width: PdfRenderer.contentWidth,
                                       color: PdfRenderer.mutedColor, context: ctx)
            return cursor - startTop
        }
    }
}
