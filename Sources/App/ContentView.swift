import SwiftUI

/// Okno główne: wybór okresu, postęp pobierania i wyniki.
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
                case .period: periodStep
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
        .sheet(isPresented: $showingSettings) {
            SettingsView(isPresentedAsSheet: true)
                .environmentObject(model)
                .environmentObject(settings)
        }
        .onAppear {
            if !model.hasUsableConfiguration {
                showingSettings = true
            } else {
                // Ostatnio pobrany miesiąc jest w pamięci aplikacji — pokazujemy go od razu.
                model.restoreLastSession()
            }
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

            if model.step == .results {
                Button("Nowy okres") {
                    model.step = .period
                }
                .help("Wróć do wyboru miesiąca")
            }

            Button {
                showingSettings = true
            } label: {
                Label("Ustawienia", systemImage: "gearshape")
            }
            .help("Ustawienia (⌘,)")
            .keyboardShortcut(",", modifiers: .command)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var contextLabel: String {
        guard settings.isNipValid else { return "Uzupełnij NIP w ustawieniach" }
        let nip = "NIP \(Nip.formatted(settings.normalizedNip))"
        switch model.connection {
        case .unknown: return "\(nip) · połączenie niesprawdzone"
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

    // MARK: - Krok 1: okres

    private var periodStep: some View {
        VStack(spacing: 22) {
            Spacer()

            VStack(spacing: 6) {
                Text("Wybierz miesiąc rozliczeniowy").font(.title2).bold()
                Text("Aplikacja pobierze faktury wystawione i otrzymane za wskazany miesiąc.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Picker("Miesiąc", selection: Binding(
                    get: { model.period },
                    set: { model.period = $0 }
                )) {
                    ForEach(MonthPeriod.selectableRange(), id: \.self) { period in
                        Text(period.displayName).tag(period)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }

            Text("Kryterium przypisania do miesiąca: \(settings.dateType.displayName.lowercased()).")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    model.fetch()
                } label: {
                    Label("Pobierz", systemImage: "arrow.down.circle")
                        .frame(minWidth: 110)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isBusy || !model.hasUsableConfiguration)

                if model.cacheAvailable {
                    Button("Pobierz ponownie") {
                        model.fetch(forceRefresh: true)
                    }
                    .help("Pomija lokalną kopię i pobiera dane z KSeF od nowa")
                    .disabled(model.isBusy)
                }

                Button("Sprawdź połączenie") {
                    model.checkConnection()
                }
                .disabled(model.isBusy || !settings.isNipValid)
            }

            if !model.hasUsableConfiguration {
                Text("Uzupełnij NIP i token KSeF w ustawieniach (⌘,), aby pobrać faktury.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            Spacer()
        }
        .padding(30)
    }

    // MARK: - Krok 2: pobieranie

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

            Text("Przerwanie jest bezpieczne — lokalna kopia poprzednich pobrań pozostaje nienaruszona.")
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
