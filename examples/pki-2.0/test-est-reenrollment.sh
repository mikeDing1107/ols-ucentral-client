#!/bin/bash
#
# Test EST Re-enrollment Script
#
# This script demonstrates manual EST re-enrollment using an existing
# operational certificate to obtain a renewed operational certificate.
#
# Usage: ./test-est-reenrollment.sh [est-server]
#

set -e

# Configuration
OPERATIONAL_CERT="${OPERATIONAL_CERT:-/etc/ucentral/operational.pem}"
KEY="${KEY:-/etc/ucentral/key.pem}"
CA_BUNDLE="${CA_BUNDLE:-/etc/ucentral/operational.ca}"
EST_SERVER="${1:-qaest.certificates.open-lan.org:8001}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp}"

echo "========================================="
echo "EST Re-enrollment Test"
echo "========================================="
echo "Operational Certificate: $OPERATIONAL_CERT"
echo "Private Key: $KEY"
echo "CA Bundle: $CA_BUNDLE"
echo "EST Server: $EST_SERVER"
echo "Output Directory: $OUTPUT_DIR"
echo ""

# Verify operational certificate exists
if [ ! -f "$OPERATIONAL_CERT" ]; then
    echo "ERROR: Operational certificate not found: $OPERATIONAL_CERT"
    echo ""
    echo "Run test-est-enrollment.sh first to obtain an operational certificate"
    exit 1
fi

if [ ! -f "$KEY" ]; then
    echo "ERROR: Private key not found: $KEY"
    exit 1
fi

if [ ! -f "$CA_BUNDLE" ]; then
    echo "ERROR: CA bundle not found: $CA_BUNDLE"
    echo "Attempting to use cas.pem as fallback..."
    CA_BUNDLE="/etc/ucentral/cas.pem"
    if [ ! -f "$CA_BUNDLE" ]; then
        echo "ERROR: No CA bundle found"
        exit 1
    fi
fi

# Display current certificate information
echo "Current Operational Certificate Information:"
echo "Subject: $(openssl x509 -in "$OPERATIONAL_CERT" -noout -subject)"
echo "Issuer: $(openssl x509 -in "$OPERATIONAL_CERT" -noout -issuer)"
echo "Valid until: $(openssl x509 -in "$OPERATIONAL_CERT" -noout -enddate)"
echo ""

# Verify operational certificate is valid
echo "Verifying current operational certificate..."
if ! openssl verify -CAfile "$CA_BUNDLE" "$OPERATIONAL_CERT" > /dev/null 2>&1; then
    echo "WARNING: Operational certificate verification failed"
fi

# Extract Common Name from operational certificate
CN=$(openssl x509 -in "$OPERATIONAL_CERT" -noout -subject | sed 's/.*CN = //')
echo "Device Common Name: $CN"
echo ""

# Generate CSR for renewal
echo "Generating Certificate Signing Request (CSR) for renewal..."
CSR_FILE="$OUTPUT_DIR/device-renew.csr"
openssl req -new -key "$KEY" -out "$CSR_FILE" -subj "/CN=$CN"

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

# Perform EST simple re-enrollment
echo "Performing EST simple re-enrollment..."
echo "Contacting EST server: https://$EST_SERVER/.well-known/est/simplereenroll"
echo ""

PKCS7_FILE="$OUTPUT_DIR/operational-renewed.p7"
curl -v --cacert "$CA_BUNDLE" \
     --cert "$OPERATIONAL_CERT" \
     --key "$KEY" \
     -H "Content-Type: application/pkcs10" \
     -H "Content-Transfer-Encoding: base64" \
     --data "$CSR_B64" \
     "https://${EST_SERVER}/.well-known/est/simplereenroll" \
     -o "$PKCS7_FILE"

CURL_EXIT=$?

echo ""
if [ $CURL_EXIT -ne 0 ]; then
    echo "ERROR: EST re-enrollment failed with curl exit code: $CURL_EXIT"
    echo ""
    echo "Troubleshooting:"
    echo "1. Verify EST server is reachable:"
    echo "   curl -I https://$EST_SERVER/.well-known/est/cacerts"
    echo "2. Check operational certificate is valid and not expired"
    echo "3. Verify CA bundle contains the correct root CA"
    echo "4. Check if operational certificate is trusted by EST server"
    exit 1
fi

if [ ! -f "$PKCS7_FILE" ] || [ ! -s "$PKCS7_FILE" ]; then
    echo "ERROR: No response received from EST server"
    exit 1
fi

echo "EST re-enrollment response received"
echo ""

# Convert PKCS#7 to PEM
echo "Converting PKCS#7 response to PEM format..."
RENEWED_CERT="$OUTPUT_DIR/operational-renewed.pem"
openssl pkcs7 -inform DER -in "$PKCS7_FILE" -print_certs -out "$RENEWED_CERT"

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to convert PKCS#7 to PEM"
    exit 1
fi

# Verify renewed certificate was created
if [ ! -f "$RENEWED_CERT" ] || [ ! -s "$RENEWED_CERT" ]; then
    echo "ERROR: Failed to create renewed certificate"
    exit 1
fi

echo "Renewed operational certificate created: $RENEWED_CERT"
echo ""

# Display renewed certificate information
echo "========================================="
echo "Renewed Certificate Information"
echo "========================================="
openssl x509 -in "$RENEWED_CERT" -noout -text | head -30
echo ""

# Display expiration date
echo "New Certificate Expiration:"
openssl x509 -in "$RENEWED_CERT" -noout -enddate
echo ""

# Compare old and new expiration dates
OLD_EXPIRE=$(openssl x509 -in "$OPERATIONAL_CERT" -noout -enddate | cut -d= -f2)
NEW_EXPIRE=$(openssl x509 -in "$RENEWED_CERT" -noout -enddate | cut -d= -f2)

echo "Certificate Renewal Comparison:"
echo "  Old expiration: $OLD_EXPIRE"
echo "  New expiration: $NEW_EXPIRE"
echo ""

# Verify renewed certificate
echo "Verifying renewed certificate..."
if openssl verify -CAfile "$CA_BUNDLE" "$RENEWED_CERT" > /dev/null 2>&1; then
    echo "✓ Certificate verification successful"
else
    echo "⚠ Certificate verification failed"
fi

echo ""
echo "========================================="
echo "EST Re-enrollment Test Complete"
echo "========================================="
echo ""
echo "Next steps:"
echo "1. Backup current operational certificate"
echo "2. Replace with renewed certificate"
echo "3. Restart ucentral-client service"
echo ""
echo "Commands:"
echo "  sudo cp $OPERATIONAL_CERT ${OPERATIONAL_CERT}.backup"
echo "  sudo cp $RENEWED_CERT $OPERATIONAL_CERT"
echo "  sudo systemctl restart ucentral-client"
