#!/bin/bash
# Buduje i uruchamia zestaw testów aplikacji KSeF Faktury.
#
# Narzędzia wiersza poleceń Xcode nie zawierają XCTest, dlatego testy są zwykłym
# programem konsolowym zbudowanym z tych samych źródeł co aplikacja (bez warstwy UI).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUILD_DIR=".build"
BINARY="$BUILD_DIR/KSeFFakturyTests"

mkdir -p "$BUILD_DIR"

echo "Kompilacja testów…"
swiftc \
  -target arm64-apple-macos26.0 \
  -swift-version 6 \
  -O \
  -o "$BINARY" \
  Sources/Core/*.swift \
  Sources/Auth/*.swift \
  Sources/Client/*.swift \
  Sources/Parser/*.swift \
  Sources/Pdf/*.swift \
  Sources/Mail/*.swift \
  Sources/Storage/*.swift \
  Sources/Update/*.swift \
  Sources/App/AppModel.swift \
  Tests/*.swift

echo
"$BINARY"
