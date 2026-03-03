#!/bin/bash
#
# Test EST Get CA Certificates Script
#
# This script demonstrates retrieving CA certificates from an EST server.
# The CA certificates are needed to verify operational certificates.
#
# Usage: ./test-get-cacerts.sh [est-server]
#

set -e

# Configuration
OPERATIONAL_CERT="${OPERATIONAL_CERT:-/etc/ucentral/operational.pem}"
KEY="${KEY:-/etc/ucentral/key.pem}"
CA_BUNDLE="${CA_BUNDLE:-/etc/ucentral/operational.ca}"
EST_SERVER="${1:-qaest.certificates.open-lan.org:8001}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp}"

echo "========================================="
echo "EST Get CA Certificates Test"
echo "========================================="
echo "Operational Certificate: $OPERATIONAL_CERT"
echo "Private Key: $KEY"
echo "CA Bundle: $CA_BUNDLE"
echo "EST Server: $EST_SERVER"
echo "Output Directory: $OUTPUT_DIR"
echo ""

# Verify operational certificate exists
if [ ! -f "$OPERATIONAL_CERT" ]; then
    echo "WARNING: Operational certificate not found: $OPERATIONAL_CERT"
    echo "Attempting to use birth certificate..."
    OPERATIONAL_CERT="/etc/ucentral/cert.pem"
    if [ ! -f "$OPERATIONAL_CERT" ]; then
        echo "ERROR: No certificate found for authentication"
        exit 1
    fi
fi

if [ ! -f "$KEY" ]; then
    echo "ERROR: Private key not found: $KEY"
    exit 1
fi

# CA bundle may not exist yet, use birth CA as fallback
if [ ! -f "$CA_BUNDLE" ]; then
    echo "WARNING: CA bundle not found: $CA_BUNDLE"
    echo "Attempting to use birth CA bundle..."
    CA_BUNDLE="/etc/ucentral/cas.pem"
    if [ ! -f "$CA_BUNDLE" ]; then
        echo "ERROR: No CA bundle found"
        exit 1
    fi
fi

echo "Using certificate: $OPERATIONAL_CERT"
echo "Using CA bundle: $CA_BUNDLE"
echo ""

# Fetch CA certificates from EST server
echo "Fetching CA certificates from EST server..."
echo "Contacting: https://$EST_SERVER/.well-known/est/cacerts"
echo ""

PKCS7_FILE="$OUTPUT_DIR/cacerts.p7"
curl -v --cacert "$CA_BUNDLE" \
     --cert "$OPERATIONAL_CERT" \
     --key "$KEY" \
     "https://${EST_SERVER}/.well-known/est/cacerts" \
     -o "$PKCS7_FILE"

CURL_EXIT=$?

echo ""
if [ $CURL_EXIT -ne 0 ]; then
    echo "ERROR: Failed to fetch CA certificates, curl exit code: $CURL_EXIT"
    echo ""
    echo "Troubleshooting:"
    echo "1. Verify EST server is reachable:"
    echo "   curl -I https://$EST_SERVER/.well-known/est/cacerts"
    echo "2. Check certificate is valid for authentication"
    echo "3. Verify CA bundle contains the correct root CA"
    exit 1
fi

if [ ! -f "$PKCS7_FILE" ] || [ ! -s "$PKCS7_FILE" ]; then
    echo "ERROR: No response received from EST server"
    exit 1
fi

echo "CA certificates response received"
echo ""

# Convert PKCS#7 to PEM
echo "Converting PKCS#7 response to PEM format..."
CACERTS_PEM="$OUTPUT_DIR/cacerts.pem"
openssl pkcs7 -inform DER -in "$PKCS7_FILE" -print_certs -out "$CACERTS_PEM"

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to convert PKCS#7 to PEM"
    exit 1
fi

# Verify CA certificates were extracted
if [ ! -f "$CACERTS_PEM" ] || [ ! -s "$CACERTS_PEM" ]; then
    echo "ERROR: Failed to extract CA certificates"
    exit 1
fi

echo "CA certificates extracted: $CACERTS_PEM"
echo ""

# Count number of certificates
CERT_COUNT=$(grep -c "BEGIN CERTIFICATE" "$CACERTS_PEM" || true)
echo "Number of CA certificates: $CERT_COUNT"
echo ""

# Display information about each certificate
echo "========================================="
echo "CA Certificates Information"
echo "========================================="
echo ""

# Split certificates and display info for each
csplit -s -f "$OUTPUT_DIR/ca-" "$CACERTS_PEM" '/-----BEGIN CERTIFICATE-----/' '{*}'

for cert_file in "$OUTPUT_DIR"/ca-*; do
    if [ -f "$cert_file" ] && [ -s "$cert_file" ]; then
        if grep -q "BEGIN CERTIFICATE" "$cert_file" 2>/dev/null; then
            echo "Certificate:"
            echo "  Subject: $(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null || echo 'N/A')"
            echo "  Issuer: $(openssl x509 -in "$cert_file" -noout -issuer 2>/dev/null || echo 'N/A')"
            echo "  Valid until: $(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null || echo 'N/A')"
            echo ""
        fi
        rm -f "$cert_file"
    fi
done

# Test verification with the new CA bundle
echo "========================================="
echo "Certificate Verification Test"
echo "========================================="
echo ""

if [ -f "/etc/ucentral/operational.pem" ]; then
    echo "Testing operational certificate verification with retrieved CA bundle..."
    if openssl verify -CAfile "$CACERTS_PEM" "/etc/ucentral/operational.pem" > /dev/null 2>&1; then
        echo "✓ Operational certificate verification successful"
    else
        echo "⚠ Operational certificate verification failed"
        echo "  This may be normal if the operational cert was issued by a different CA"
    fi
    echo ""
fi

if [ -f "/etc/ucentral/cert.pem" ]; then
    echo "Testing birth certificate verification with retrieved CA bundle..."
    if openssl verify -CAfile "$CACERTS_PEM" "/etc/ucentral/cert.pem" > /dev/null 2>&1; then
        echo "✓ Birth certificate verification successful"
    else
        echo "⚠ Birth certificate verification failed"
        echo "  This may be normal if the birth cert was issued by a different CA"
    fi
    echo ""
fi

echo "========================================="
echo "EST Get CA Certificates Test Complete"
echo "========================================="
echo ""
echo "CA certificates saved to: $CACERTS_PEM"
echo ""
echo "Next steps:"
echo "1. Review the CA certificates"
echo "2. Update operational CA bundle if needed"
echo ""
echo "Commands:"
echo "  cat $CACERTS_PEM"
echo "  sudo cp $CACERTS_PEM /etc/ucentral/operational.ca"
