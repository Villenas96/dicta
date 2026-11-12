#!/bin/bash
# Instalador de una línea para alumnos (Mac). Uso:
#   curl -fsSL <URL de este script> | bash
# Descarga Dicta, la copia a Aplicaciones y la abre. Al descargarse con curl, macOS no
# la bloquea como «app de un desarrollador no identificado».
set -euo pipefail
ZIP_URL="${DICTA_ZIP_URL:-https://github.com/Villenas96/dicta/releases/latest/download/Dicta-mac.zip}"

if [[ "$(sw_vers -productVersion | cut -d. -f1)" -lt 26 ]]; then
  echo "Dicta necesita macOS 26 o superior. Tienes $(sw_vers -productVersion)." >&2; exit 1
fi
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
echo "→ Descargando Dicta…"
curl -fsSL "$ZIP_URL" -o "$TMP/Dicta.zip"
ditto -x -k "$TMP/Dicta.zip" "$TMP"
DEST=/Applications
[[ -w "$DEST" ]] || DEST="$HOME/Applications"
mkdir -p "$DEST"
pkill -x Dicta 2>/dev/null || true
rm -rf "$DEST/Dicta.app"
cp -R "$TMP/Dicta.app" "$DEST/"
xattr -dr com.apple.quarantine "$DEST/Dicta.app" 2>/dev/null || true
echo "✔ Instalada en $DEST/Dicta.app"
open "$DEST/Dicta.app"
echo "Concede Micrófono, Accesibilidad y Monitorización de entrada cuando te lo pida."
