#!/bin/zsh
# OPCIONAL. Crea en tu llavero de inicio de sesión un certificado autofirmado
# «Dicta Local Signing» para firmar Dicta siempre con la misma identidad.
# Así macOS recuerda los permisos (micrófono, accesibilidad, monitorización de
# entrada) entre recompilaciones. Sin él, la firma es ad-hoc y tras cada
# compilación hay que volver a concederlos.
set -euo pipefail
NAME="Dicta Local Signing"
if security find-identity -p codesigning | grep -q "$NAME"; then
  echo "Ya existe «$NAME»."; exit 0
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cfg" <<EOF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cfg"
# OpenSSL 3 necesita -legacy para que el Llavero lea el .p12; LibreSSL (macOS) no lo admite.
LEGACY=()
openssl version | grep -q '^OpenSSL 3' && LEGACY=(-legacy)
openssl pkcs12 -export "${LEGACY[@]}" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:dicta -name "$NAME"
security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db -P dicta -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db "$TMP/cert.pem"
echo "✔ Certificado «$NAME» creado. Vuelve a ejecutar ./scripts/build-app.sh"
