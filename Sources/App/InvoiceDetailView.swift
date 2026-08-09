import PDFKit
import SwiftUI

/// Podgląd wygenerowanego pliku PDF.
struct PDFKitView: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(data: data)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.dataRepresentation() != data {
            view.document = PDFDocument(data: data)
        }
    }
}

/// Szczegóły faktury: wizualizacja PDF, pełna lista pól i dokument źródłowy XML.
struct InvoiceDetailView: View {
    let invoice: Invoice
    let pdfData: Data?

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private enum Tab: String, CaseIterable, Identifiable {
        case visualization = "Wizualizacja"
        case fields = "Wszystkie pola"
        case xml = "Surowy XML"

        var id: String { rawValue }
    }

    @State private var tab: Tab = .visualization
    @State private var fieldFilter = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Picker("Widok", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            Group {
                switch tab {
                case .visualization: visualization
                case .fields: fields
                case .xml: rawXML
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 780, idealWidth: 940, minHeight: 560, idealHeight: 720)
    }

    // MARK: - Nagłówek

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("\(invoice.kind.displayName) nr \(invoice.invoiceNumber)")
                        .font(.headline)
                    if invoice.isCorrection {
                        Text("korekta")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red.opacity(0.15), in: Capsule())
                            .foregroundStyle(.red)
                    }
                    Text(invoice.schema.rawValue)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Text(invoice.ksefNumber)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("\(invoice.direction.displayName) · \(invoice.counterparty.displayName) · "
                    + Fmt.money(invoice.totalGross, currency: invoice.currency))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                Button("Zamknij") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    model.revealInvoicePDF(invoice)
                } label: {
                    Label("Pokaż w Finderze", systemImage: "folder")
                }
                .disabled(pdfData == nil)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Zakładki

    @ViewBuilder
    private var visualization: some View {
        if let pdfData {
            PDFKitView(data: pdfData)
        } else {
            ContentUnavailableView {
                Label("Brak wizualizacji", systemImage: "doc.questionmark")
            } description: {
                Text("Dla tej faktury nie wygenerowano pliku PDF. "
                    + "Dokument źródłowy jest dostępny w zakładce „Surowy XML”.")
            }
        }
    }

    /// Wszystkie pola dokumentu źródłowego, spłaszczone do listy „ścieżka → wartość".
    private var fields: some View {
        let all = (try? XmlTreeBuilder.parse(invoice.rawXML))?.flattened() ?? []
        let filtered = fieldFilter.isEmpty
            ? all
            : all.filter {
                $0.path.localizedCaseInsensitiveContains(fieldFilter)
                    || $0.value.localizedCaseInsensitiveContains(fieldFilter)
            }

        return VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filtruj pola", text: $fieldFilter)
                    .textFieldStyle(.plain)
                Text("\(filtered.count) z \(all.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            Divider()

            List(Array(filtered.enumerated()), id: \.offset) { _, field in
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(field.value)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
        }
    }

    private var rawXML: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(String(data: invoice.rawXML, encoding: .utf8) ?? "Nie udało się odczytać dokumentu jako tekst UTF-8.")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
    }
}
