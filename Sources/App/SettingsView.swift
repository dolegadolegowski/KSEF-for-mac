import SwiftUI

/// Ustawienia: kontekst NIP, token KSeF, kryterium przypisania do miesiąca i sposób wysyłki.
struct SettingsView: View {
    var isPresentedAsSheet = false

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var nipDraft = ""
    @State private var tokenDraft = ""
    @State private var tokenStored = false
    @State private var didLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    contextSection
                    Divider()
                    periodCriterionSection
                    Divider()
                    mailSection
                    Divider()
                    updatesSection
                    Divider()
                    dataSection
                }
                .padding(24)
            }

            Divider()
            HStack {
                if let url = Log.shared.logFileURL {
                    Button("Pokaż dziennik") { model.revealInFinder(url) }
                        .buttonStyle(.link)
                        .help("Dziennik nie zawiera tokenów ani nagłówków autoryzacji")
                }
                Spacer()
                if isPresentedAsSheet {
                    Button("Gotowe") {
                        applyChanges()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 520)
        .onAppear(perform: load)
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        nipDraft = settings.nip
        tokenStored = settings.isNipValid && Keychain.hasToken(forNip: settings.normalizedNip)
    }

    // MARK: - Kontekst

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Kontekst KSeF").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                TextField("NIP podmiotu", text: $nipDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(applyChanges)

                if nipDraft.isEmpty {
                    Text("Dziesięciocyfrowy NIP podmiotu, w którego kontekście działa token.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if Nip.isValid(nipDraft) {
                    Label("NIP poprawny: \(Nip.formatted(Nip.normalize(nipDraft)))",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                } else {
                    Label("Nieprawidłowa suma kontrolna NIP-u.", systemImage: "xmark.circle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                SecureField(tokenStored ? "Token zapisany — wpisz nowy, aby zmienić" : "Token KSeF",
                            text: $tokenDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(applyChanges)

                Text("Token wymaga uprawnienia InvoiceRead. Jest przechowywany wyłącznie "
                    + "w pęku kluczy (Keychain) tego komputera i nigdy nie trafia do dziennika.")
                    .font(.caption).foregroundStyle(.secondary)

                if tokenStored {
                    HStack(spacing: 10) {
                        Label("Token zapisany w Keychain", systemImage: "key.fill")
                            .font(.caption).foregroundStyle(.green)
                        Button("Usuń token") {
                            try? Keychain.deleteToken(forNip: settings.normalizedNip)
                            tokenStored = false
                            tokenDraft = ""
                            model.connection = .unknown
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                }
            }

            HStack(spacing: 10) {
                Button("Zapisz") { applyChanges() }
                    .disabled(!Nip.isValid(nipDraft))

                Button("Sprawdź połączenie") {
                    applyChanges()
                    model.checkConnection()
                }
                .disabled(!Nip.isValid(nipDraft) || model.isBusy)
            }

            statusBox
        }
    }

    @ViewBuilder
    private var statusBox: some View {
        switch model.connection {
        case .unknown:
            EmptyView()
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Uwierzytelnianie w KSeF…").font(.callout)
            }
        case let .connected(detail):
            Label(detail, systemImage: "checkmark.seal.fill")
                .font(.callout)
                .foregroundStyle(.green)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case let .failed(detail):
            Label(detail, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Kryterium miesiąca

    private var periodCriterionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Przypisanie faktury do miesiąca").font(.headline)

            Picker("Kryterium", selection: Binding(
                get: { settings.dateType },
                set: { settings.dateType = $0 }
            )) {
                ForEach(InvoiceDateType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Text(settings.dateType.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Wybór wpływa na to, które faktury znajdą się w miesiącu — a więc na zawartość "
                + "zestawienia księgowego.")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Poczta

    private var mailSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wiadomość z zestawieniem").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                TextField("Adres odbiorcy (np. biuro rachunkowe)",
                          text: Binding(get: { settings.recipientEmail },
                                        set: { settings.recipientEmail = $0 }))
                    .textFieldStyle(.roundedBorder)

                if settings.recipientEmail.isEmpty {
                    Text("Podaj adres, na który ma trafiać zestawienie. Zostanie wpisany "
                        + "w pole odbiorcy, więc gotową wiadomość wystarczy otworzyć i wysłać.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if settings.isRecipientEmailValid {
                    Label("Wiadomość będzie zaadresowana do \(settings.recipientEmail)",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("To nie wygląda na poprawny adres e-mail.", systemImage: "xmark.circle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
            }

            Picker("Metoda", selection: Binding(
                get: { settings.mailMethod },
                set: { settings.mailMethod = $0 }
            )) {
                ForEach(MailDeliveryMethod.allCases) { method in
                    Text(method.displayName).tag(method)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Text("Aplikacja nigdy nie wysyła wiadomości samodzielnie — przygotowuje ją, "
                + "a wysyłkę zatwierdzasz w kliencie pocztowym.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Aktualizacje

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Aktualizacje").font(.headline)

            Toggle("Sprawdzaj aktualizacje automatycznie (raz dziennie)",
                   isOn: Binding(get: { settings.automaticUpdateCheck },
                                 set: { settings.automaticUpdateCheck = $0 }))

            HStack(spacing: 10) {
                Button("Sprawdź teraz") { model.checkForUpdates() }
                    .disabled(model.isBusy)

                if model.availableUpdate != nil {
                    Button("Pobierz aktualizację") { model.downloadUpdate() }
                        .buttonStyle(.borderedProminent)
                    Button("Zobacz opis zmian") { model.openReleasePage() }
                }
            }

            if let release = model.availableUpdate {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Dostępna wersja \(release.version) — masz \(AppInfo.version)",
                          systemImage: "arrow.down.circle.fill")
                        .font(.callout).foregroundStyle(.blue)
                    if !release.notes.isEmpty {
                        Text(release.notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(8)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            } else if let status = model.updateStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Aktualizacje pochodzą z repozytorium \(UpdateChecker.defaultRepository). "
                + "Aplikacja nie podmienia się sama — pobrany pakiet przeciągasz do katalogu Programy.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Dane lokalne

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pamięć aplikacji").font(.headline)

            Text("Pobrane faktury, oryginalne pliki XML i wygenerowane pliki PDF są przechowywane "
                + "w pamięci aplikacji, osobno dla każdego NIP-u. Dzięki temu po ponownym "
                + "uruchomieniu są dostępne bez łączenia się z KSeF. Zmiana NIP-u kasuje dane "
                + "poprzedniego podmiotu.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("Pokaż pliki w Finderze") {
                    if let url = Storage.applicationSupportDirectory() {
                        model.revealInFinder(url)
                    }
                }
                Button("Wyczyść pamięć aplikacji", role: .destructive) {
                    Storage.clearCache(forNip: settings.normalizedNip)
                    model.invoiceSet = nil
                    model.pdfs = [:]
                    model.lastOutputDirectory = nil
                    model.step = .period
                    model.infoMessage = "Pobrane faktury zostały usunięte z pamięci aplikacji."
                }
                .disabled(!settings.isNipValid)
            }

            Text(AppInfo.displayVersion + " · środowisko produkcyjne KSeF")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Zapis

    private func applyChanges() {
        let normalized = Nip.normalize(nipDraft)
        guard Nip.isValid(normalized) else { return }

        let contextChanged = normalized != settings.normalizedNip
        settings.nip = normalized
        nipDraft = normalized

        if contextChanged {
            model.handleContextChange()
            tokenStored = Keychain.hasToken(forNip: normalized)
        }

        let token = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            model.saveToken(token)
            tokenDraft = ""
            tokenStored = true
        }
    }
}
