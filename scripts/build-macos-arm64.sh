#!/bin/bash
# Buduje KSeFFaktury.app dla macOS 26 na Apple Silicon (arm64).
#
# Wynikiem jest dokładnie jeden artefakt: artifacts/KSeFFaktury.app — samodzielny pakiet
# bez instalatora, bez zewnętrznego środowiska uruchomieniowego i bez zależności
# instalowanych przez użytkownika. Wystarczy przeciągnąć go do /Applications.
#
# Podpis: domyślnie ad-hoc. Aby podpisać własnym certyfikatem Developer ID, ustaw
#   CODESIGN_IDENTITY="Developer ID Application: Imię Nazwisko (TEAMID)"
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="KSeFFaktury"
BUNDLE="artifacts/${APP_NAME}.app"
TARGET="arm64-apple-macos26.0"
IDENTITY="${CODESIGN_IDENTITY:--}"

echo "▸ Sprzątanie poprzedniej wersji"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

echo "▸ Kompilacja (Release, $TARGET)"
# -parse-as-library jest wymagane, bo punktem wejścia jest struktura oznaczona @main,
# a nie plik main.swift.
swiftc \
  -target "$TARGET" \
  -swift-version 6 \
  -O -whole-module-optimization \
  -parse-as-library \
  -o "$BUNDLE/Contents/MacOS/${APP_NAME}" \
  Sources/Core/*.swift \
  Sources/Auth/*.swift \
  Sources/Client/*.swift \
  Sources/Parser/*.swift \
  Sources/Pdf/*.swift \
  Sources/Mail/*.swift \
  Sources/Storage/*.swift \
  Sources/Update/*.swift \
  Sources/App/*.swift

echo "▸ Składanie pakietu"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
else
  echo "OSTRZEŻENIE: brak Resources/AppIcon.icns — uruchom ./scripts/make-icon.sh" >&2
fi

echo "▸ Podpisywanie (tożsamość: $IDENTITY)"
codesign --force --deep \
  --options runtime \
  --entitlements Resources/${APP_NAME}.entitlements \
  --sign "$IDENTITY" \
  --timestamp=none \
  "$BUNDLE"

echo "▸ Weryfikacja podpisu"
codesign --verify --verbose=2 "$BUNDLE"

ARCHS=$(lipo -archs "$BUNDLE/Contents/MacOS/${APP_NAME}")
echo "▸ Architektury: $ARCHS"
if [ "$ARCHS" != "arm64" ]; then
  echo "OSTRZEŻENIE: oczekiwano wyłącznie arm64, otrzymano: $ARCHS" >&2
fi

SIZE=$(du -sh "$BUNDLE" | cut -f1)
echo
echo "Gotowe: $BUNDLE ($SIZE)"
echo
if [ "$IDENTITY" = "-" ]; then
  cat <<'INSTRUKCJA'
Pakiet jest podpisany ad-hoc, więc przy pierwszym uruchomieniu Gatekeeper pokaże ostrzeżenie.
Aby je usunąć u odbiorców, podpisz i poświadcz pakiet notarialnie:

  1. Podpisanie certyfikatem Developer ID:
       CODESIGN_IDENTITY="Developer ID Application: Imię Nazwisko (TEAMID)" ./scripts/build-macos-arm64.sh

  2. Spakowanie do przesłania:
       ditto -c -k --keepParent artifacts/KSeFFaktury.app artifacts/KSeFFaktury.zip

  3. Poświadczenie notarialne (dane logowania zapisane wcześniej w pęku kluczy):
       xcrun notarytool store-credentials "ksef-notary" \
         --apple-id "adres@example.com" --team-id TEAMID --password "hasło-aplikacji"
       xcrun notarytool submit artifacts/KSeFFaktury.zip --keychain-profile "ksef-notary" --wait

  4. Dołączenie potwierdzenia do pakietu:
       xcrun stapler staple artifacts/KSeFFaktury.app
       spctl --assess --type execute --verbose artifacts/KSeFFaktury.app

Uruchomienie lokalnie bez notaryzacji: kliknij pakiet prawym przyciskiem i wybierz „Otwórz”.
INSTRUKCJA
fi
