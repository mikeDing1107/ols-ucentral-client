#!/bin/bash
#
# Test EST Enrollment Script
#
# This script demonstrates manual EST enrollment using birth certificates
# to obtain an operational certificate from the EST server.
#
# Usage: ./test-est-enrollment.sh [est-server]
#

set -e

# Configuration
BIRTH_CERT="${BIRTH_CERT:-/etc/ucentral/cert.pem}"
BIRTH_KEY="${BIRTH_KEY:-/etc/ucentral/key.pem}"
CA_BUNDLE="${CA_BUNDLE:-/etc/ucentral/cas.pem}"
EST_SERVER="${1:-qaest.certificates.open-lan.org:8001}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp}"

echo "========================================="
echo "EST Enrollment Test"
echo "========================================="
echo "Birth Certificate: $BIRTH_CERT"
echo "Birth Key: $BIRTH_KEY"
echo "CA Bundle: $CA_BUNDLE"
echo "EST Server: $EST_SERVER"
echo "Output Directory: $OUTPUT_DIR"
echo ""

# Verify birth certificates exist
if [ ! -f "$BIRTH_CERT" ]; then
    echo "ERROR: Birth certificate not found: $BIRTH_CERT"
    exit 1
fi

if [ ! -f "$BIRTH_KEY" ]; then
    echo "ERROR: Birth key not found: $BIRTH_KEY"
    exit 1
fi

if [ ! -f "$CA_BUNDLE" ]; then
    echo "ERROR: CA bundle not found: $CA_BUNDLE"
    exit 1
fi

# Verify birth certificate is valid
echo "Verifying birth certificate..."
if ! openssl verify -CAfile "$CA_BUNDLE" "$BIRTH_CERT" > /dev/null 2>&1; then
    echo "WARNING: Birth certificate verification failed"
fi

# Extract Common Name from birth certificate
CN=$(openssl x509 -in "$BIRTH_CERT" -noout -subject | sed 's/.*CN = //')
echo "Device Common Name: $CN"
echo ""

# Generate CSR from birth certificate
echo "Generating Certificate Signing Request (CSR)..."
CSR_FILE="$OUTPUT_DIR/device.csr"
openssl req -new -key "$BIRTH_KEY" -out "$CSR_FILE" -subj "/CN=$CN"

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to generate CSR"
    exit 1
fi

echo "CSR generated: $CSR_FILE"
echo ""

# Base64 encode CSR (no headers, DER format)
echo "Encoding CSR to base64..."
CSR_B64=$(openssl req -in "$CSR_FILE" -outform DER | base64 | tr -d '\n')

if [ -z "$CSR_B64" ]; then
    echo "ERROR: Failed to encode CSR"
    exit 1
fi

echo "CSR encoded successfully"
echo ""

# Perform EST simple enrollment
echo "Performing EST simple enrollment..."
echo "Contacting EST server: https://$EST_SERVER/.well-known/est/simpleenroll"
echo ""

PKCS7_FILE="$OUTPUT_DIR/operational.p7"
curl -v --cacert "$CA_BUNDLE" \
     --cert "$BIRTH_CERT" \
     --key "$BIRTH_KEY" \
     -H "Content-Type: application/pkcs10" \
     -H "Content-Transfer-Encoding: base64" \
     --data "$CSR_B64" \
     "https://${EST_SERVER}/.well-known/est/simpleenroll" \
     -o "$PKCS7_FILE"

CURL_EXIT=$?

echo ""
if [ $CURL_EXIT -ne 0 ]; then
    echo "ERROR: EST enrollment failed with curl exit code: $CURL_EXIT"
    echo ""
    echo "Troubleshooting:"
    echo "1. Verify EST server is reachable:"
    echo "   curl -I https://$EST_SERVER/.well-known/est/cacerts"
    echo "2. Check birth certificate is valid and not expired"
    echo "3. Verify CA bundle contains the correct root CA"
    exit 1
fi

if [ ! -f "$PKCS7_FILE" ] || [ ! -s "$PKCS7_FILE" ]; then
    echo "ERROR: No response received from EST server"
    exit 1
fi

echo "EST enrollment response received"
echo ""

# Convert PKCS#7 to PEM
echo "Converting PKCS#7 response to PEM format..."
OPERATIONAL_CERT="$OUTPUT_DIR/operational.pem"
openssl pkcs7 -inform DER -in "$PKCS7_FILE" -print_certs -out "$OPERATIONAL_CERT"

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to convert PKCS#7 to PEM"
    exit 1
fi

# Verify operational certificate was created
if [ ! -f "$OPERATIONAL_CERT" ] || [ ! -s "$OPERATIONAL_CERT" ]; then
    echo "ERROR: Failed to create operational certificate"
    exit 1
fi

echo "Operational certificate created: $OPERATIONAL_CERT"
echo ""

# Display certificate information
echo "========================================="
echo "Operational Certificate Information"
echo "========================================="
openssl x509 -in "$OPERATIONAL_CERT" -noout -text | head -30
echo ""

# Display expiration date
echo "Certificate Expiration:"
openssl x509 -in "$OPERATIONAL_CERT" -noout -enddate
echo ""

# Verify operational certificate
echo "Verifying operational certificate..."
if openssl verify -CAfile "$CA_BUNDLE" "$OPERATIONAL_CERT" > /dev/null 2>&1; then
    echo "✓ Certificate verification successful"
else
    echo "⚠ Certificate verification failed (may need operational CA bundle)"
fi

echo ""
echo "========================================="
echo "EST Enrollment Test Complete"
echo "========================================="
echo ""
echo "Next steps:"
echo "1. Copy operational certificate to /etc/ucentral/operational.pem"
echo "2. Copy operational CA bundle to /etc/ucentral/operational.ca"
echo "3. Restart ucentral-client service"
echo ""
echo "Commands:"
echo "  sudo cp $OPERATIONAL_CERT /etc/ucentral/operational.pem"
echo "  sudo cp $CA_BUNDLE /etc/ucentral/operational.ca"
echo "  sudo systemctl restart ucentral-client"
