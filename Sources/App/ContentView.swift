import SwiftUI

/// Okno główne. Po uruchomieniu pokazuje podgląd bieżącego miesiąca;
/// wcześniejsze okresy wybiera się listą rozwijaną w nagłówku.
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Group {
                switch model.step {
                case .downloading: downloadingStep
                case .results: ResultsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if model.errorMessage != nil || model.infoMessage != nil || model.availableUpdate != nil {
                Divider()
                messages
            }
        }
        .sheet(isPresented: $showingSettings, onDismiss: {
            // Po zmianie NIP-u lista miesięcy i zawartość podglądu mogą być inne.
            model.refreshStoredPeriods()
        }) {
            SettingsView(isPresentedAsSheet: true)
                .environmentObject(model)
                .environmentObject(settings)
        }
        .onAppear {
            model.openInitialMonth()
            if !model.hasUsableConfiguration { showingSettings = true }
            model.checkForUpdates(automatic: true)
        }
    }

    // MARK: - Nagłówek

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Faktury KSeF").font(.headline)
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(contextLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            monthPicker

            Button {
                model.fetch(forceRefresh: model.cacheAvailable)
            } label: {
                Label(model.cacheAvailable ? "Pobierz ponownie" : "Pobierz",
                      systemImage: "arrow.down.circle")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.isBusy || !model.hasUsableConfiguration)
            .help(model.cacheAvailable
                ? "Pobiera miesiąc z KSeF od nowa, zastępując dane w pamięci aplikacji"
                : "Pobiera faktury za wybrany miesiąc z KSeF")

            Button {
                showingSettings = true
            } label: {
                Label("Ustawienia", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
            }
            .help("Ustawienia (⌘,)")
            .keyboardShortcut(",", modifiers: .command)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// Lista rozwijana z miesiącami. Pobrane okresy są oznaczone kropką,
    /// żeby było widać, które otworzą się od razu, bez łączenia z KSeF.
    private var monthPicker: some View {
        Picker("Miesiąc", selection: Binding(
            get: { model.period },
            set: { model.selectPeriod($0) }
        )) {
            ForEach(model.selectableMonths, id: \.self) { period in
                Text(model.isStored(period) ? "\(period.displayName)  ●" : period.displayName)
                    .tag(period)
            }
        }
        .labelsHidden()
        .frame(width: 190)
        .disabled(model.isBusy)
        .help("Wybierz miesiąc rozliczeniowy. Kropka oznacza miesiąc zapisany w pamięci aplikacji.")
    }

    private var contextLabel: String {
        guard settings.isNipValid else { return "Uzupełnij NIP w ustawieniach (⌘,)" }
        let nip = "NIP \(Nip.formatted(settings.normalizedNip))"
        switch model.connection {
        case .unknown: return "\(nip) · \(settings.dateType.displayName.lowercased())"
        case .checking: return "\(nip) · sprawdzanie połączenia…"
        case .connected: return "\(nip) · połączono z KSeF"
        case .failed: return "\(nip) · problem z połączeniem"
        }
    }

    private var statusColor: Color {
        switch model.connection {
        case .connected: return .green
        case .failed: return .red
        case .checking: return .orange
        case .unknown: return .secondary
        }
    }

    // MARK: - Pobieranie

    private var downloadingStep: some View {
        VStack(spacing: 20) {
            Spacer()

            ProgressView(value: model.progress?.fraction ?? 0) {
                Text(model.progress?.stage ?? "Pracuję…").font(.headline)
            } currentValueLabel: {
                if let progress = model.progress, progress.total > 0 {
                    Text(progressLabel(progress))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .progressViewStyle(.linear)
            .frame(maxWidth: 460)

            Button("Anuluj", role: .cancel) {
                model.cancel()
            }
            .keyboardShortcut(.cancelAction)

            Text("Przerwanie jest bezpieczne — faktury zapisane wcześniej pozostają nienaruszone.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(30)
    }

    private func progressLabel(_ progress: FetchProgress) -> String {
        var text = "\(progress.current) z \(progress.total)"
        if let detail = progress.detail { text += " — \(detail)" }
        return text
    }

    // MARK: - Komunikaty

    private var messages: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let release = model.availableUpdate {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                    Text("Dostępna nowa wersja \(release.version). Masz \(AppInfo.version).")
                        .font(.callout)
                    Spacer()
                    Button("Pobierz") { model.downloadUpdate() }.buttonStyle(.link)
                    Button("Opis zmian") { model.openReleasePage() }.buttonStyle(.link)
                    Button("Ukryj") { model.availableUpdate = nil }.buttonStyle(.link)
                }
            }
            if let info = model.infoMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(.blue)
                    Text(info).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button("Ukryj") { model.infoMessage = nil }.buttonStyle(.link)
                }
            }
            if let error = model.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(error).font(.callout).bold().textSelection(.enabled)
                        if let details = model.errorDetails {
                            Text(details)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer()
                    if let details = model.errorDetails {
                        Button("Kopiuj szczegóły") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(error)\n\(details)", forType: .string)
                        }
                        .buttonStyle(.link)
                    }
                    Button("Ukryj") {
                        model.errorMessage = nil
                        model.errorDetails = nil
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.4))
    }
}
