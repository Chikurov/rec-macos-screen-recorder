#!/bin/zsh
set -euo pipefail

IDENTITY="Rec Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Сертификат «$IDENTITY» уже есть в связке ключей."
    exit 0
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

cat > "$WORKDIR/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$WORKDIR/cert.cnf" \
    -keyout "$WORKDIR/key.pem" -out "$WORKDIR/cert.pem" 2>/dev/null

P12_PASSWORD=$(openssl rand -hex 16)
openssl pkcs12 -export -legacy \
    -inkey "$WORKDIR/key.pem" -in "$WORKDIR/cert.pem" \
    -name "$IDENTITY" -out "$WORKDIR/identity.p12" -passout "pass:$P12_PASSWORD"

security import "$WORKDIR/identity.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign

echo "Готово: сертификат «$IDENTITY» добавлен в связку ключей «login»."
