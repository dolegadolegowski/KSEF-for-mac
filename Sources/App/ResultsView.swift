import SwiftUI

/// Wiersz tabeli wyników. Kwoty przechowywane są jako `Decimal`, dzięki czemu
/// sortowanie po nich jest liczbowe — także dla korekt ujemnych i dużych wartości.
struct InvoiceRow: Identifiable {
    let invoice: Invoice

    var id: String { invoice.ksefNumber }
    var date: Date { invoice.issueDate ?? .distantPast }
    var dateText: String { invoice.issueDate.map { Fmt.isoDate($0) } ?? "—" }
    var number: String { invoice.invoiceNumber }
    var ksefNumber: String { invoice.ksefNumber }
    var counterparty: String { invoice.counterparty.displayName }
    var net: Decimal { invoice.totalNet }
    var gross: Decimal { invoice.totalGross }
    var isCorrection: Bool { invoice.isCorrection }
    var currency: String { invoice.currency }
}

struct ResultsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var issuedSort = [KeyPathComparator(\InvoiceRow.date)]
    @State private var receivedSort = [KeyPathComparator(\InvoiceRow.date)]
    @State private var issuedSelection: InvoiceRow.ID?
    @State private var receivedSelection: InvoiceRow.ID?
    @State private var showingAttachmentChoice = false

    private var results: InvoiceSet { model.invoiceSet ?? InvoiceSet(period: model.period, nip: "") }

    private var issuedRows: [InvoiceRow] {
        results.issued.map(InvoiceRow.init).sorted(using: issuedSort)
    }

    private var receivedRows: [InvoiceRow] {
        results.received.map(InvoiceRow.init).sorted(using: receivedSort)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section(
                        title: "Faktury wystawione",
                        counterpartyTitle: "Odbiorca",
                        rows: issuedRows,
                        invoices: results.issued,
                        sort: $issuedSort,
                        selection: $issuedSelection
                    )
                    section(
                        title: "Faktury otrzymane",
                        counterpartyTitle: "Wystawiający",
                        rows: receivedRows,
                        invoices: results.received,
                        sort: $receivedSort,
                        selection: $receivedSelection
                    )
                    balanceSection
                }
                .padding(20)
            }
        }
        .sheet(item: $model.selectedInvoice) { invoice in
            InvoiceDetailView(invoice: invoice, pdfData: model.pdfs[invoice.ksefNumber])
                .environmentObject(model)
        }
        .confirmationDialog("Załączniki przekraczają 20 MB",
                            isPresented: $showingAttachmentChoice,
                            titleVisibility: .visible) {
            Button("Dołącz mimo to") { model.generateEmail(attachmentMode: .individual) }
            Button("Dołącz jedno archiwum ZIP") { model.generateEmail(attachmentMode: .archive) }
            Button("Bez załączników, z odnośnikiem do katalogu") { model.generateEmail(attachmentMode: .none) }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Łączny rozmiar załączników to około \(model.attachmentsExceedThreshold().megabytes) MB. "
                + "Część serwerów pocztowych odrzuca tak duże wiadomości.")
        }
    }

    // MARK: - Pasek narzędzi

    private var toolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(results.period.displayName).font(.title3).bold()
                Text("\(results.all.count) faktur · \(results.strategy.displayName) · pobrano \(Fmt.dateTime(results.fetchedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !results.warnings.isEmpty {
                Label("\(results.warnings.count)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help(results.warnings.joined(separator: "\n"))
            }

            Button {
                if model.attachmentsExceedThreshold().exceeds {
                    showingAttachmentChoice = true
                } else {
                    model.generateEmail()
                }
            } label: {
                Label("Generuj e-mail", systemImage: "envelope")
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(results.isEmpty)

            if let directory = model.lastOutputDirectory {
                Button {
                    model.revealInFinder(directory)
                } label: {
                    Label("Pokaż pliki", systemImage: "folder")
                }
                .help("Faktury są przechowywane w pamięci aplikacji — ten przycisk otwiera je w Finderze")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Sekcja z tabelą

    @ViewBuilder
    private func section(title: String,
                         counterpartyTitle: String,
                         rows: [InvoiceRow],
                         invoices: [Invoice],
                         sort: Binding<[KeyPathComparator<InvoiceRow>]>,
                         selection: Binding<InvoiceRow.ID?>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)

            if rows.isEmpty {
                Text("Brak faktur w tym miesiącu.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                Table(rows, selection: selection, sortOrder: sort) {
                    TableColumn("Data", value: \.date) { row in
                        Text(row.dateText).monospacedDigit()
                    }
                    .width(min: 88, ideal: 92)

                    TableColumn("Numer", value: \.number) { row in
                        HStack(spacing: 5) {
                            Text(row.number).lineLimit(1)
                            if row.isCorrection {
                                Text("korekta")
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.red.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    .width(min: 130, ideal: 170)

                    TableColumn("Numer KSeF", value: \.ksefNumber) { row in
                        Text(row.ksefNumber)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                    .width(min: 180, ideal: 230)

                    TableColumn(counterpartyTitle, value: \.counterparty) { row in
                        Text(row.counterparty).lineLimit(1)
                    }
                    .width(min: 150, ideal: 220)

                    // Sortowanie po `Decimal` jest liczbowe, więc korekty ujemne
                    // i separatory tysięcy nie zaburzają kolejności.
                    TableColumn("Netto", value: \.net) { row in
                        Text(Fmt.money(row.net, currency: row.currency))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 100, ideal: 120)

                    TableColumn("Brutto", value: \.gross) { row in
                        Text(Fmt.money(row.gross, currency: row.currency))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 100, ideal: 120)
                }
                .frame(minHeight: 160, idealHeight: min(CGFloat(rows.count) * 26 + 32, 320))
                .onChange(of: selection.wrappedValue) { _, newValue in
                    guard let newValue,
                          let row = rows.first(where: { $0.id == newValue }) else { return }
                    model.selectedInvoice = row.invoice
                }

                totalsRows(for: invoices)
            }
        }
    }

    /// Wiersze sum pod tabelą — osobno dla każdej waluty.
    private func totalsRows(for invoices: [Invoice]) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            ForEach(Totals.byCurrency(invoices)) { total in
                HStack(spacing: 18) {
                    Spacer()
                    Text("Razem (\(total.currency)), \(total.count) fakt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    label("netto", total.netFormatted)
                    label("VAT", total.vatFormatted)
                    label("brutto", total.grossFormatted, bold: true)
                }
            }
        }
        .padding(.trailing, 4)
    }

    private func label(_ title: String, _ value: String, bold: Bool = false) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .fontWeight(bold ? .semibold : .regular)
                .monospacedDigit()
        }
        .frame(minWidth: 150, alignment: .trailing)
    }

    // MARK: - Saldo

    private var balanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Podsumowanie zbiorcze").font(.headline)

            let balances = Totals.balance(issued: results.issued, received: results.received)
            if balances.isEmpty {
                Text("Brak danych do podsumowania.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(balances) { balance in
                    let sales = Totals.byCurrency(results.issued).first { $0.currency == balance.currency }
                        ?? CurrencyTotals(currency: balance.currency)
                    let purchases = Totals.byCurrency(results.received).first { $0.currency == balance.currency }
                        ?? CurrencyTotals(currency: balance.currency)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Waluta \(balance.currency)").font(.subheadline).bold()
                        summaryLine("Sprzedaż (wystawione)", sales)
                        summaryLine("Zakupy (otrzymane)", purchases)
                        Divider()
                        summaryLine("Saldo (wystawione − otrzymane)", balance, emphasised: true)
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func summaryLine(_ title: String, _ totals: CurrencyTotals, emphasised: Bool = false) -> some View {
        HStack(spacing: 18) {
            Text(title)
                .font(.callout)
                .fontWeight(emphasised ? .semibold : .regular)
            Spacer()
            label("netto", totals.netFormatted, bold: emphasised)
            label("VAT", totals.vatFormatted, bold: emphasised)
            label("brutto", totals.grossFormatted, bold: emphasised)
        }
    }
}
