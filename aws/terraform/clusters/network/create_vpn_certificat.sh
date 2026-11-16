#!/bin/bash
set -e

WORKDIR="${VPN_CERT_DIR:?Set VPN_CERT_DIR to a new output directory}"
SERVER_CN="${VPN_DOMAIN:?Set VPN_DOMAIN}"
DAYS_VALIDITY=730
: "${AWS_REGION:?Set AWS_REGION}"

if [[ ! "$SERVER_CN" =~ ^(\*\.)?[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then
  echo "VPN_DOMAIN must be one ASCII DNS name." >&2
  exit 2
fi

umask 077
mkdir -- "$WORKDIR"
cd -- "$WORKDIR"

echo "➡️ Génération de la CA racine..."
openssl genrsa -out ca.key 2048
openssl req -x509 -new -nodes -key ca.key -sha256 -days $DAYS_VALIDITY \
    -out ca.crt -subj "/O=Example Organization/CN=vpn-client-root-ca"

echo "➡️ Génération du certificat serveur avec SAN..."
openssl genrsa -out server.key 2048
openssl req -new -key server.key -out server.csr \
    -subj "/O=Example Organization/CN=$SERVER_CN"

# Créer le fichier de configuration avec SAN
cat > server_ext.cnf << EOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:$SERVER_CN
EOF

openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out server.crt -days $DAYS_VALIDITY -sha256 -extfile server_ext.cnf

echo "➡️ Vérification du SAN..."
openssl x509 -in server.crt -noout -text | grep -A1 "Subject Alternative Name"

echo "➡️ Import dans ACM (région: $AWS_REGION)..."
SERVER_ARN=$(aws acm import-certificate \
  --certificate fileb://server.crt \
  --private-key fileb://server.key \
  --certificate-chain fileb://ca.crt \
  --region="$AWS_REGION" \
  --query CertificateArn --output text)

ROOT_CA_ARN=$(aws acm import-certificate \
  --certificate fileb://ca.crt \
  --private-key fileb://ca.key \
  --region="$AWS_REGION" \
  --query CertificateArn --output text)

echo ""
echo "✅ Certificats importés avec SAN dans $AWS_REGION:"
echo "server_certificate_arn     = \"$SERVER_ARN\""
echo "root_certificate_chain_arn = \"$ROOT_CA_ARN\""
