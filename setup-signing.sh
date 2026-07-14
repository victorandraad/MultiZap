#!/bin/bash
# Cria (uma única vez) um certificado de assinatura local e estável para o
# MultiZap. Com uma identidade fixa, o macOS reconhece o app como "o mesmo"
# entre builds e para de pedir a senha do Keychain toda hora.
set -e

cd "$(dirname "$0")"

IDENTITY="MultiZap Local"
P12_PASS="multizap"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TMP="$(mktemp -d)"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "==> Identidade \"$IDENTITY\" já existe e é válida. Nada a fazer."
    exit 0
fi

echo "==> Gerando certificado de assinatura \"$IDENTITY\" ..."

cat > "$TMP/openssl.cnf" <<'CNF'
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[ dn ]
CN = MultiZap Local
[ v3 ]
basicConstraints   = critical,CA:FALSE
keyUsage           = critical,digitalSignature
extendedKeyUsage   = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/openssl.cnf" >/dev/null 2>&1

# Algoritmos legados + senha: exigido pelo Keychain do macOS (senão dá
# "MAC verification failed" no import).
openssl pkcs12 -export \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/multizap.p12" -passout "pass:$P12_PASS" -name "$IDENTITY" \
    -macalg sha1 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES >/dev/null 2>&1

echo "==> Importando no Keychain (login) ..."
security import "$TMP/multizap.p12" -k "$KEYCHAIN" -P "$P12_PASS" -A -T /usr/bin/codesign >/dev/null 2>&1

echo "==> Marcando como confiável para assinatura de código ..."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" >/dev/null 2>&1

rm -rf "$TMP"

echo ""
echo "Pronto! Identidade \"$IDENTITY\" criada e permanente."
echo "Rode ./build-app.sh — ele já vai assinar com ela."
