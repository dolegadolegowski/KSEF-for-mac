# KSeF Faktury

Aplikacja macOS, która pobiera z Krajowego Systemu e-Faktur faktury wystawione i otrzymane
za wybrany miesiąc, generuje dla każdej z nich osobny plik PDF i przygotowuje gotową do wysłania
wiadomość e-mail z zestawieniem oraz załącznikami.

Powstała po to, żeby comiesięczne wysłanie kompletu faktur do biura rachunkowego zajmowało
dwa kliknięcia zamiast godziny klikania w Aplikacji Podatnika.

- **Środowisko:** wyłącznie produkcyjne API KSeF — `https://api.ksef.mf.gov.pl/v2/`
- **System:** macOS 26 „Tahoe”, wyłącznie Apple Silicon (arm64)
- **Zależności:** brak — aplikacja korzysta jedynie z frameworków systemowych

---

## Jak to działa

```
KSeF  ──►  metadane faktur        ──►  pobranie dokumentów XML  ──►  parser FA(3)/FA(2)/PEF
                                                                            │
                     wiadomość e-mail  ◄──  zestawienie HTML  ◄─────────────┤
                     z załącznikami                                         │
                                              osobny PDF na fakturę  ◄──────┘
```

1. **Uwierzytelnienie** tokenem KSeF w kontekście NIP-u: pobranie klucza publicznego,
   `challenge`, zaszyfrowanie `token|timestamp` algorytmem RSA-OAEP SHA-256, wymiana na parę
   tokenów dostępowych i ich automatyczne odświeżanie.
2. **Metadane** faktur wystawionych (`Subject1`) i otrzymanych (`Subject2`) za wybrany miesiąc —
   wszystkie strony wyników, z deduplikacją po numerze KSeF.
3. **Treść faktur**: pojedynczo (`GET /invoices/ksef/{numer}`) albo — gdy liczba faktur przekracza
   limit godzinowy — przez eksport zaszyfrowanej paczki, który aplikacja wybiera automatycznie.
4. **Parsowanie** dokumentów XML: komplet danych faktury, w tym pozycje, podsumowanie stawek VAT,
   adnotacje i dane korekty. Wszystkie kwoty liczone na typie dziesiętnym.
5. **Wizualizacja**: osobny plik PDF na fakturę, w układzie polskiej faktury VAT, z kodem QR
   weryfikującym dokument w KSeF.
6. **Zestawienie**: dwie tabele z sumami i saldem oraz gotowa wiadomość e-mail z fakturami
   w załącznikach.

Dokumentem źródłowym każdej faktury pozostaje jej plik XML w KSeF — pliki PDF są wyłącznie
wizualizacją i wprost to komunikują.

---

## Instalacja

1. Zbuduj pakiet:

   ```bash
   ./scripts/build-macos-arm64.sh
   ```

2. Przeciągnij `artifacts/KSeFFaktury.app` do katalogu `/Applications`.

Pakiet jest samodzielny — nie wymaga instalatora ani żadnego dodatkowego środowiska
uruchomieniowego.

> Pakiet budowany domyślnie jest podpisany ad-hoc, więc przy pierwszym uruchomieniu Gatekeeper
> wyświetli ostrzeżenie. Kliknij pakiet prawym przyciskiem myszy i wybierz **Otwórz**.
> Aby usunąć ostrzeżenie u odbiorców, podpisz pakiet certyfikatem Developer ID i poświadcz go
> notarialnie — instrukcję wypisuje skrypt budujący.

Gotowe wydania są też dostępne w zakładce
[Releases](https://github.com/dolegadolegowski/KSEF-for-mac/releases).

---

## Wygenerowanie tokena KSeF

Aplikacja uwierzytelnia się tokenem KSeF w kontekście konkretnego NIP-u.

1. Zaloguj się do [Aplikacji Podatnika KSeF](https://ksef.mf.gov.pl) — Profilem Zaufanym,
   podpisem kwalifikowanym albo certyfikatem KSeF.
2. Wybierz kontekst podmiotu (NIP), którego faktury chcesz pobierać.
3. Przejdź do sekcji **Tokeny** i wygeneruj nowy token.
4. Nadaj mu uprawnienie **`InvoiceRead`** — to jedyne uprawnienie potrzebne tej aplikacji.
   Nie wymaga ona prawa do wystawiania faktur ani zarządzania uprawnieniami.
5. Skopiuj wartość tokena. **KSeF pokazuje ją tylko raz.**

---

## Pierwsze uruchomienie

1. Uruchom aplikację. Przy pustej konfiguracji ekran ustawień otworzy się automatycznie
   (później dostępny skrótem **⌘,**).
2. Wpisz **NIP** podmiotu — suma kontrolna sprawdzana jest na bieżąco.
3. Wklej **token KSeF**. Trafia wyłącznie do pęku kluczy (Keychain) tego komputera.
4. Podaj **adres odbiorcy** zestawienia (zwykle biuro rachunkowe). Zostanie wpisany w pole
   adresata, więc gotową wiadomość wystarczy otworzyć i wysłać.
5. Kliknij **Sprawdź połączenie** — aplikacja wykona pełne uwierzytelnienie i potwierdzi
   uprawnienie `InvoiceRead`.

### Kryterium przypisania faktury do miesiąca

| Kryterium | Znaczenie |
| --- | --- |
| **Data wystawienia** (domyślne) | Pole `P_1` faktury. Najczęstsze kryterium księgowe. |
| **Data przyjęcia w KSeF** | Moment przyjęcia dokumentu przez system do dalszego przetwarzania. |
| **Data trwałego zapisu w KSeF** | Moment trwałego zapisu w repozytorium. Gwarantuje kompletność przy pobieraniu przyrostowym, ale faktura wystawiona pod koniec miesiąca może trafić do miesiąca następnego. |

Wybór realnie zmienia zawartość zestawienia, dlatego jest opisany także w oknie ustawień.

---

## Korzystanie

**1. Wybór okresu.** Wskaż miesiąc (domyślnie poprzedni) i kliknij **Pobierz**. Jeśli miesiąc
był już pobierany, dane wczytają się z pamięci aplikacji; **Pobierz ponownie** wymusza
odświeżenie z KSeF.

**2. Pobieranie.** Pasek postępu pokazuje etapy: uwierzytelnianie, metadane obu kierunków,
pobieranie dokumentów XML, przetwarzanie i generowanie PDF-ów. **Anuluj** bezpiecznie przerywa
pracę — dotychczasowa pamięć aplikacji pozostaje nienaruszona.

**3. Wyniki.** Dwie tabele: faktury wystawione i otrzymane. Każdą kolumnę można sortować,
a kwoty sortują się liczbowo — również korekty z wartościami ujemnymi. Pod tabelami sumy netto,
VAT i brutto osobno dla każdej waluty, niżej saldo sprzedaży i zakupów. Kliknięcie wiersza
otwiera podgląd faktury z zakładkami **Wizualizacja** (PDF), **Wszystkie pola** (pełna lista pól
dokumentu z filtrem) i **Surowy XML**.

**4. E-mail.** Przycisk **Generuj e-mail** (⌘E) przygotowuje wiadomość z obiema tabelami
w treści, podsumowaniem zbiorczym i wszystkimi plikami PDF jako osobnymi załącznikami.
Wiadomość otwiera się w kliencie pocztowym z wpisanym adresatem — pozostaje kliknąć **Wyślij**.
**Aplikacja nigdy nie wysyła wiadomości samodzielnie.**

Gdy łączny rozmiar załączników przekroczy 20 MB, aplikacja zapyta, czy dołączyć pliki mimo to,
spakować je w jedno archiwum ZIP, czy wysłać wiadomość bez załączników, z odnośnikiem do katalogu.

### Gdzie trafiają pliki

Pobrane faktury zostają w pamięci aplikacji — nie trzeba nic zapisywać ręcznie i przy kolejnym
uruchomieniu ostatni pobrany miesiąc pokazuje się od razu, bez łączenia się z KSeF. Struktura
plików jest zwykłym katalogiem, który otwiera przycisk **Pokaż pliki**:

```
KSeF_2026-07/
  wystawione/WYSTAWIONE_2026-07_FV-123-2026_NABYWCA-SP-Z-O-O_1770PLN.pdf
  otrzymane/OTRZYMANE_2026-07_FA-2024_DOSTAWCA-SA_2460PLN.pdf
  xml/5260250274-20260715-01ABCDEF-01.xml
  podsumowanie.html
  wiadomosc.eml
```

---

## Aktualizacje

Aplikacja sprawdza wydania w tym repozytorium — automatycznie raz na dobę (można wyłączyć)
oraz na żądanie przyciskiem **Sprawdź teraz** w ustawieniach. Gdy pojawi się nowsza wersja,
w oknie głównym wyświetla się pasek z numerem wersji, odnośnikiem do opisu zmian i przyciskiem
pobrania.

Aplikacja nie podmienia się sama: działa w piaskownicy systemowej i nie ma prawa zapisu
do `/Applications`. Pobrany pakiet rozpakowujesz i przeciągasz do katalogu Programy.

---

## Bezpieczeństwo i prywatność

- Token KSeF przechowywany jest **wyłącznie w Keychain**
  (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`) — nigdy w `UserDefaults`, w plikach
  ani w dzienniku.
- Każdy wpis dziennika i każdy komunikat błędu przechodzi przez centralną redakcję: tokeny KSeF,
  nagłówki `Authorization`, tokeny JWT i klucze prywatne są zastępowane znacznikiem.
- Aplikacja łączy się **wyłącznie** z API KSeF oraz — przy sprawdzaniu aktualizacji — z API
  serwisu GitHub. Nie ma telemetrii ani własnego zaplecza serwerowego; żadne dane faktur
  nie opuszczają komputera.
- Działa w piaskownicy systemowej: klient sieciowy i zapis do własnego magazynu.
- Zmiana NIP-u kasuje dane poprzedniego podmiotu.

---

## Znane ograniczenia

- **Limity API.** Pobranie treści pojedynczej faktury podlega limitowi 64 żądań na godzinę
  (oraz 8/s i 16/min). Gdy liczba faktur przekracza dostępny limit, aplikacja automatycznie
  przechodzi na eksport paczki i informuje o tym w interfejsie.
- **Zakres wyników.** Zapytanie o metadane zwraca maksymalnie 10 000 faktur; przekroczenie
  tej granicy jest odnotowywane jako ostrzeżenie.
- **Otwieranie pliku `.eml`.** Część klientów pocztowych (w tym Mail.app) otwiera `.eml`
  w trybie podglądu zamiast edycji. W takim wypadku użyj polecenia „Edytuj jako nową wiadomość”
  albo przełącz w ustawieniach metodę na **wiadomość roboczą w Mail.app (AppleScript)**.
- **PDF to wizualizacja.** Dokumentem źródłowym pozostaje plik XML w KSeF; oryginały są
  zapisywane obok, w podkatalogu `xml/`.

---

## Testy

```bash
./scripts/run-tests.sh
```

Zestaw obejmuje m.in. walidację NIP, szyfrowanie RSA-OAEP SHA-256, pełny przebieg
uwierzytelniania na zamockowanym HTTP, granice miesiąca ze zmianą czasu, paginację
i deduplikację, parsery FA(3)/FA(2)/korekt/PEF, faktury w konwencji brutto, sumowanie
wielowalutowe, podział długiej faktury na strony A4, poprawność pliku `.eml`, obsługę
`HTTP 429`, porównywanie wersji przy aktualizacji oraz redakcję sekretów w dzienniku.

---

## Struktura projektu

| Katalog | Zawartość |
| --- | --- |
| `Sources/Core` | walidacja NIP, formatowanie `pl_PL`, okresy rozliczeniowe, Keychain, dziennik z redakcją |
| `Sources/Auth` | kryptografia (RSA-OAEP, AES-256-CBC, SHA-256) i przebieg uwierzytelniania KSeF |
| `Sources/Client` | warstwa HTTP, modele API, limiter żądań, czytnik archiwów ZIP |
| `Sources/Parser` | model faktury i parser FA(3)/FA(2)/PEF wraz z sumowaniem |
| `Sources/Pdf` | generator PDF i kodów QR |
| `Sources/Mail` | raport HTML i kompozytor wiadomości `.eml` |
| `Sources/Storage` | magazyn per NIP, zapis atomowy, struktura katalogu wyników |
| `Sources/Update` | sprawdzanie wydań w serwisie GitHub |
| `Sources/App` | model aplikacji i interfejs SwiftUI |
| `Tests` | zestaw testów wraz z serwerem testowym KSeF |

Skrypty: `build-macos-arm64.sh` (pakiet), `run-tests.sh` (testy), `make-icon.sh` (ikona).

Decyzje projektowe, przyjęte założenia i rozbieżności względem dokumentacji KSeF opisano
w pliku [NOTES.md](NOTES.md).

---

## Licencja

Projekt prywatny, udostępniony publicznie. Korzystasz na własną odpowiedzialność — przed
użyciem księgowym porównaj wyniki z danymi w Aplikacji Podatnika KSeF.
