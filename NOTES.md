# Notatki projektowe

Dokument opisuje decyzje podjęte przy budowie aplikacji, rozbieżności między treścią zlecenia
a rzeczywistą dokumentacją KSeF, świadome uproszczenia oraz listę rzeczy do wykonania przed
użyciem produkcyjnym.

Kontrakt API odtworzono ze specyfikacji `open-api.json` oraz przewodnika integratora
z repozytorium [CIRFMF/ksef-api](https://github.com/CIRFMF/ksef-api) (stan na sierpień 2026).
Nazwy endpointów, pól i wartości enumów pochodzą wprost z tych źródeł — nie były zgadywane.

---

## 1. Rozbieżności względem treści zlecenia

Wszędzie tam, gdzie zlecenie rozmijało się z dokumentacją, zastosowano dokumentację.

| Zagadnienie | Treść zlecenia | Stan faktyczny | Co zrobiono |
| --- | --- | --- | --- |
| Limit pobierania XML | „ok. 60 pobrań na godzinę” | `GET /invoices/ksef/{ksefNumber}`: **64/h**, dodatkowo 8/s i 16/min | Limiter egzekwuje wszystkie trzy progi równolegle |
| `POST /auth/challenge` | „z kontekstem NIP” | Endpoint **nie przyjmuje treści żądania** | Kontekst przekazywany dopiero w `POST /auth/ksef-token` |
| Żądanie uwierzytelnienia | „wyślij żądanie uwierzytelnienia tokenem (JSON)” | Konkretna ścieżka to `POST /auth/ksef-token` | Użyto właściwej ścieżki |
| Odświeżenie tokena | sugerowana para tokenów | `POST /auth/token/refresh` zwraca **wyłącznie `accessToken`** | Refresh token zachowywany lokalnie do wygaśnięcia |
| `dateType` dla daty wystawienia | „`Issue`/`Invoicing`” | To dwie **różne** wartości: `Issue` = data wystawienia, `Invoicing` = data przyjęcia w KSeF | Domyślnie `Issue`; oba warianty plus `PermanentStorage` dostępne w ustawieniach |
| Paginacja | „`pageOffset`/`pageSize`” | `pageOffset` to **indeks strony** (0 = pierwsza), nie przesunięcie rekordu; `pageSize` maks. 250 | Pobierane są kolejne indeksy stron po 250 pozycji |
| Klucz publiczny | „certyfikaty DER w Base64” | Dla przeznaczenia `KsefTokenEncryption` zwracana bywa sama struktura **SubjectPublicKeyInfo**, nie certyfikat X.509 | `Crypto.publicKey(fromDER:)` obsługuje X.509, SPKI i goły PKCS#1 |
| Schemat `FA_KOR` | wymieniony jako osobny schemat | Nie istnieje — korekty to zwykłe FA z `RodzajFaktury` = `KOR`, `KOR_ZAL` lub `KOR_ROZ` | Korekty obsługiwane w ramach parsera FA |
| Błąd `21301` | „chwilowy błąd przy redeem” | Potwierdzone w dokumentacji jako jeden z możliwych stanów | Ponawianie z narastającym opóźnieniem, do 6 prób |

## 2. Przyjęte założenia

- **Przestrzenie nazw schematów.** FA(3) rozpoznawany po `http://crd.gov.pl/wzor/2025/06/25/13775/`,
  FA(2) po `http://crd.gov.pl/wzor/2023/06/29/12648/`. Dokument o nieznanej przestrzeni nazw,
  ale zawierający element `Fa`, jest przetwarzany jak FA(3) — dzięki temu nowszy wzór da się
  odczytać bez aktualizacji aplikacji.
- **Wartości adnotacji.** W schemacie FA pola `P_16`–`P_18A` przyjmują `1` (brak) albo `2`
  (wystąpienie). Adnotację uznajemy za obecną wyłącznie przy wartości `2`. Sekcje `Zwolnienie`,
  `NoweSrodkiTransportu` i `PMarzy` interpretowane są przez pola zaprzeczające
  (`P_19N`, `P_22N`, `P_PMarzyN`).
- **Podsumowanie stawek VAT.** Odwzorowanie pól `P_13_*`/`P_14_*` na etykiety stawek przyjęto
  zgodnie z dokumentacją pól w XSD (m.in. `P_13_4` — ryczałt dla taksówek osobowych,
  `P_13_5` — procedura szczególna z działu XII rozdz. 6a, `P_13_10` — odwrotne obciążenie,
  `P_13_11` — procedura marży).
- **Skrót faktury do kodu QR.** Używany jest `invoiceHash` z metadanych KSeF, bo to wartość
  wyliczona przez system. Gdy metadanych brak (np. odczyt z lokalnej kopii), skrót liczony jest
  z pobranego dokumentu XML.
- **Wybór ścieżki pobierania.** Eksport paczki uruchamiany jest, gdy liczba faktur przekracza
  mniejszą z wartości: limit godzinowy (64) i liczba żądań pozostałych w bieżącym oknie.
  Wybrana ścieżka jest pokazywana w interfejsie.
- **Wiadomość e-mail.** Plik `.eml` nie zawiera nagłówka `From`, a `To` jest puste — adresata
  wpisuje użytkownik. Dodano `X-Unsent: 1`, honorowany przez część klientów jako oznaczenie
  wiadomości roboczej.
- **Nazwa firmy.** Uzupełniana automatycznie z pola sprzedawcy pierwszej faktury wystawionej;
  trafia do tematu wiadomości.

## 3. Świadome uproszczenia

- **PDF/A-3 z osadzonym XML — nie zrealizowano.** Osadzenie załącznika w PDF wymaga struktur
  `EmbeddedFiles`/`AF` oraz metadanych XMP, których `CGContext` nie udostępnia, a warunkiem
  zlecenia był brak zewnętrznych bibliotek. Zgodnie z zapisem zlecenia oryginalne pliki XML
  zapisywane są obok, w podkatalogu `xml/`, a każdy PDF w stopce wskazuje numer KSeF i informuje,
  że jest wyłącznie wizualizacją.
- **Testy bez XCTest.** Narzędzia wiersza poleceń Xcode nie zawierają ani XCTest, ani Swift
  Testing, a aplikacja nie może mieć zewnętrznych zależności. Testy są zwykłym programem
  konsolowym zbudowanym z tych samych źródeł (`scripts/run-tests.sh`), z własnym, minimalnym
  harnessem. Zestaw uruchamia się jedną komendą i kończy kodem wyjścia 1 przy niepowodzeniu.
- **Formatowanie kwot bez `NumberFormatter`.** Polska lokalizacja CLDR ma
  `minimumGroupingDigits = 2`, przez co `NumberFormatter` zapisuje `1234,56` zamiast wymaganego
  `1 234,56`. Kwoty formatowane są więc ręcznie, deterministycznie i niezależnie od ustawień
  systemowych.
- **Kolumna rabatu w PDF.** Pokazywana tylko wtedy, gdy którakolwiek pozycja zawiera rabat —
  inaczej zabierałaby szerokość nazwie towaru na stronie A4 pionowo.
- **Podpis kodu QR.** Kod QR (KOD I) generowany jest dla faktur online. KOD II, potwierdzający
  autentyczność wystawcy, dotyczy wyłącznie faktur wystawianych offline i wymaga certyfikatu
  KSeF typu Offline — aplikacja tylko pobiera faktury, więc go nie generuje.
- **`restrictToPermanentStorageHwmDate`** nie jest ustawiane. Aplikacja pobiera zamknięte
  miesiące kalendarzowe, a nie dane przyrostowe, więc ograniczanie zakresu do znacznika HWM
  nie jest potrzebne.
- **Klasa ustawień nosi nazwę `AppSettings`.** Nazwa `Settings` koliduje ze sceną `Settings`
  z SwiftUI, obsługującą skrót ⌘,.
- **Brak ręcznego zapisu na dysk.** Pobrane faktury trafiają do magazynu aplikacji i są
  wczytywane przy starcie, więc nie ma osobnego kroku „zapisz”. Katalog z plikami można otworzyć
  w Finderze, gdyby były potrzebne gdzie indziej. Konsekwencja: pliki leżą w kontenerze
  piaskownicy (`~/Library/Containers/pl.ksef.faktury/…`), a nie w dowolnym miejscu na dysku.
- **Aktualizacja nie podmienia pakietu samodzielnie.** Aplikacja działa w piaskownicy, więc nie
  ma prawa zapisu do `/Applications` — samoaktualizacja wymagałaby rezygnacji z piaskownicy albo
  osobnego pomocnika instalacyjnego. Moduł sprawdza wydania przez API GitHuba, pokazuje opis zmian
  i pobiera pakiet do wskazanego miejsca; instalację (przeciągnięcie) wykonuje użytkownik.
- **Ikona generowana kodem.** `scripts/make-icon.sh` rysuje ją z `scripts/make-icon.swift`
  i składa `iconutil`. Gotowy `Resources/AppIcon.icns` jest wersjonowany, więc zwykły build
  nie musi go odtwarzać.

## 4. Decyzje dotyczące poprawności kwot

- Wszystkie sumy liczone są na typie `Decimal`; `Double` nie występuje w ścieżce obliczeń.
  Kwoty z metadanych API (zwracane jako `double`) służą wyłącznie do wstępnej prezentacji
  i nigdy nie trafiają do sum — te pochodzą z parsowania XML.
- Kwoty zapisane przez wystawcę nie są nadpisywane. Wartość wyliczana jest wyłącznie wtedy,
  gdy pole jest puste (np. brak `P_11Vat`), i wówczas oznaczana gwiazdką, z wyjaśnieniem
  w stopce PDF.
- **Faktury w konwencji brutto.** Część wystawców korzysta z art. 106e ust. 7 i 8 ustawy
  i podaje w pozycjach wyłącznie wartość brutto (`P_11A`), bez `P_9A`, `P_11` i `P_11Vat`.
  W takim przypadku netto liczone jest metodą „w stu” (brutto ÷ (1 + stawka)), a podatek
  jako **różnica** brutto i netto — nie przez mnożenie. Dzięki temu netto i VAT każdej pozycji
  zawsze sumują się dokładnie do wartości brutto podanej przez wystawcę, bez błędu zaokrąglenia.
  Poprawność potwierdza test: dla rzeczywistej faktury (160,65 zł i 194,65 zł brutto przy 23%)
  wyliczone pozycje dają 288,86 zł netto i 66,44 zł podatku, czyli dokładnie tyle, ile wystawca
  wykazał w polach `P_13_1` i `P_14_1`.
- Suma brutto pochodzi z pola `P_15` (kwota należności ogółem), a nie z sumowania pozycji.
  Suma pozycji używana jest tylko wtedy, gdy wystawca nie wypełnił podsumowania stawek.
- Waluty sumowane są rozłącznie — nie ma przeliczeń między walutami. Dla faktur w walucie obcej
  prezentowana jest dodatkowo kwota VAT w złotych z pól `P_14_*W`.
- Korekty mają kwoty ujemne już w dokumencie źródłowym, więc pomniejszają sumy w naturalny
  sposób; sortowanie w tabelach odbywa się po `Decimal`, czyli liczbowo.

## 5. Do wykonania przed użyciem produkcyjnym

1. **Weryfikacja na prawdziwych danych.** Repozytorium MF nie zawiera przykładowych plików
   faktur, więc parser sprawdzono na dokumentach zbudowanych ściśle według XSD. Przed użyciem
   księgowym należy porównać wynik z kilkoma rzeczywistymi fakturami — zwłaszcza korektami,
   fakturami zaliczkowymi i rozliczeniowymi oraz dokumentami w walucie obcej.
2. **Potwierdzenie skrótu w kodzie QR.** Należy sprawdzić na prawdziwej fakturze, że
   `invoiceHash` z metadanych daje link weryfikacyjny akceptowany przez
   `https://qr.ksef.mf.gov.pl` (czy skrót liczony jest z tych samych bajtów, które zwraca
   `GET /invoices/ksef/{ksefNumber}`).
3. **Sprawdzenie ścieżki eksportu paczki na dużym miesiącu.** Odszyfrowanie AES-256-CBC
   i rozpakowanie archiwum przetestowano na danych syntetycznych; warto potwierdzić je na
   miesiącu z liczbą faktur przekraczającą limit godzinowy.
4. **Podpisanie i notaryzacja.** Bez certyfikatu Developer ID i poświadczenia notarialnego
   odbiorcy zobaczą ostrzeżenie Gatekeepera. Instrukcję wypisuje `scripts/build-macos-arm64.sh`.
5. **Zachowanie klienta pocztowego.** Warto sprawdzić, jak docelowy klient traktuje plik `.eml`
   — jeśli otwiera go w trybie podglądu, wygodniejszy będzie wariant AppleScript dla Mail.app
   dostępny w ustawieniach.
6. **Zachowanie przy dużej liczbie faktur w interfejsie.** Tabele nie są wirtualizowane ponad
   to, co daje `Table` z SwiftUI; przy kilku tysiącach pozycji warto zmierzyć płynność.

## 6. Weryfikacja wykonana

- **80 testów automatycznych**, w tym pełny przebieg uwierzytelniania na zamockowanym HTTP
  (z faktycznym odszyfrowaniem ładunku `token|timestampMs` kluczem prywatnym), paginacja
  z deduplikacją, wznowienie po `HTTP 429`, trwałość limitera między uruchomieniami oraz
  kompletny przepływ aplikacji: metadane → XML → parser → PDF → struktura katalogu wyników.
- **Wizualna kontrola wygenerowanego PDF-a** — układ, polskie znaki diakrytyczne, kod QR,
  oznaczenia kwot wyliczonych.
- **Zbudowanie i uruchomienie pakietu** `KSeFFaktury.app` (arm64, 2,2 MB) na macOS 26.
  Zrzut ekranu działającego okna nie był możliwy — środowisko, w którym powstawała aplikacja,
  blokuje przechwytywanie ekranu i API dostępności. Interfejs został więc zweryfikowany
  pośrednio, testami modelu aplikacji sterującego wszystkimi krokami przepływu.
