#!/bin/bash
# Generuje Resources/AppIcon.icns na podstawie scripts/make-icon.swift.
#
# Wynik jest wersjonowany w repozytorium, więc skrypt uruchamia się tylko wtedy,
# gdy ikona ma się zmienić — zwykły build z niego nie korzysta.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ICONSET="$WORK/AppIcon.iconset"

echo "▸ Rysowanie ikony"
swift scripts/make-icon.swift "$ICONSET"

echo "▸ Składanie pliku .icns"
iconutil --convert icns "$ICONSET" --output Resources/AppIcon.icns

echo "Gotowe: Resources/AppIcon.icns ($(du -h Resources/AppIcon.icns | cut -f1))"
