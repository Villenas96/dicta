#!/bin/zsh
# Compila Dicta en modo release y genera dist/Dicta.app firmada.
#   ./scripts/build-app.sh            → dist/Dicta.app
#   ./scripts/build-app.sh --install  → además la copia a ~/Applications
set -euo pipefail
cd "$(dirname "$0")/.."

# UNIVERSAL=1 → binario para Apple Silicon e Intel (para repartir a otros Macs).
ARCH_FLAGS=()
[[ "${UNIVERSAL:-0}" == "1" ]] && ARCH_FLAGS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCH_FLAGS[@]}"
BIN="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)/Dicta"

APP=dist/Dicta.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Dicta"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Firma: si existe un certificado de firma local, los permisos de macOS (micrófono,
# accesibilidad…) sobreviven a las recompilaciones. Si no, firma ad-hoc (hay que volver
# a conceder permisos tras cada compilación). Ver scripts/create-signing-cert.sh.
IDENTITY="${DICTA_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]] && security find-identity -p codesigning 2>/dev/null | grep -q "Dicta Local Signing"; then
  IDENTITY="Dicta Local Signing"
fi
if [[ -n "$IDENTITY" ]]; then
  codesign --force --options runtime --entitlements Resources/Dicta.entitlements --sign "$IDENTITY" "$APP"
else
  codesign --force --entitlements Resources/Dicta.entitlements --sign - "$APP"
fi
codesign --verify --verbose=1 "$APP"
echo "✔ $APP (firma: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/Dicta.app
  cp -R "$APP" ~/Applications/
  echo "✔ Instalada en ~/Applications/Dicta.app"
fi
