# PKI 2.0 Certificate Examples and Tools

This directory contains examples and tools for working with PKI 2.0 certificates in the uCentral client.

## Overview

PKI 2.0 uses a two-tier certificate system:
- **Birth Certificates**: Factory-provisioned, long-lived certificates used for EST enrollment
- **Operational Certificates**: Runtime-generated, shorter-lived certificates obtained via EST protocol

## Certificate Workflow

```
Factory/Manufacturing
    ↓
Birth Certificates Generated (openlan-pki-tools)
    ↓
Certificates Provisioned to Device (partition_script.sh)
    ↓
Device First Boot
    ↓
EST Enrollment (automatic via ucentral-client)
    ↓
Operational Certificates Obtained
    ↓
Device Runtime (uses operational certs)
    ↓
Certificate Renewal (via reenroll RPC)
```

## Birth Certificate Generation

Birth certificates are generated using the `openlan-pki-tools` repository.

### Prerequisites

```bash
# Clone openlan-pki-tools
git clone https://github.com/Telecominfraproject/openlan-pki-tools.git
cd openlan-pki-tools
```

### Generating Birth Certificates

The openlan-pki-tools repository provides scripts for generating birth certificates:

**For QA/Demo Environment:**
```bash
cd openlan-pki-tools
./scripts/generate-birth-cert.sh \
    --mac "AA:BB:CC:DD:EE:FF" \
    --serial "SN123456789" \
    --ca demo \
    --output /tmp/birth-certs/
```

**For Production Environment:**
```bash
./scripts/generate-birth-cert.sh \
    --mac "AA:BB:CC:DD:EE:FF" \
    --serial "SN123456789" \
    --ca production \
    --output /tmp/birth-certs/
```

### Birth Certificate Files

After generation, you'll have:
- `cert.pem` - Birth certificate (contains device identity)
- `key.pem` - Private key (keep secure!)
- `cas.pem` - CA certificate bundle
- `dev-id` - Device identifier file

## Installing Birth Certificates on Device

### Using partition_script.sh

```bash
# On your development machine, package the certificates
cd /tmp/birth-certs
tar -czf device-certs.tar.gz cert.pem key.pem cas.pem dev-id

# Copy to device
scp device-certs.tar.gz admin@<device-ip>:/tmp/
scp ../../partition_script.sh admin@<device-ip>:/tmp/

# On the device
ssh admin@<device-ip>
sudo su
cd /tmp
tar -xzf device-certs.tar.gz
bash ./partition_script.sh ./

# Reboot to mount the partition
reboot
```

## EST Enrollment (Automatic)

After installing birth certificates and rebooting, the uCentral client automatically:

1. Detects birth certificates in `/etc/ucentral/`
2. Determines EST server based on certificate issuer:
   - "OpenLAN Demo Birth CA" → `qaest.certificates.open-lan.org:8001`
   - "OpenLAN Birth Issuing CA" → `est.certificates.open-lan.org`
3. Performs EST simple enrollment using birth certificate
4. Saves operational certificate to `/etc/ucentral/operational.pem`
5. Saves operational CA to `/etc/ucentral/operational.ca`
6. Uses operational certificates for gateway connection

## Manual EST Enrollment Testing

For testing or manual certificate operations, you can use curl directly:

### Prerequisites
```bash
# Install curl and openssl
apt-get update
apt-get install -y curl openssl
```

### Test EST Enrollment

```bash
#!/bin/bash
# test-est-enrollment.sh

BIRTH_CERT="/etc/ucentral/cert.pem"
BIRTH_KEY="/etc/ucentral/key.pem"
CA_BUNDLE="/etc/ucentral/cas.pem"
EST_SERVER="qaest.certificates.open-lan.org:8001"

# Generate CSR from birth certificate
openssl req -new -key $BIRTH_KEY -out /tmp/device.csr -subj "/CN=$(hostname)"

# Base64 encode CSR (no headers)
CSR_B64=$(openssl req -in /tmp/device.csr -outform DER | base64 | tr -d '\n')

# Perform EST simple enrollment
curl -v --cacert $CA_BUNDLE \
     --cert $BIRTH_CERT \
     --key $BIRTH_KEY \
     -H "Content-Type: application/pkcs10" \
     -H "Content-Transfer-Encoding: base64" \
     --data "$CSR_B64" \
     "https://${EST_SERVER}/.well-known/est/simpleenroll" \
     -o /tmp/operational.p7

# Convert PKCS#7 to PEM
openssl pkcs7 -inform DER -in /tmp/operational.p7 -print_certs -out /tmp/operational.pem

echo "Operational certificate saved to /tmp/operational.pem"
```

### Test EST Re-enrollment

```bash
#!/bin/bash
# test-est-reenrollment.sh

OPERATIONAL_CERT="/etc/ucentral/operational.pem"
KEY="/etc/ucentral/key.pem"
CA_BUNDLE="/etc/ucentral/operational.ca"
EST_SERVER="qaest.certificates.open-lan.org:8001"

# Generate CSR from operational certificate
openssl req -new -key $KEY -out /tmp/device-renew.csr -subj "/CN=$(hostname)"

# Base64 encode CSR
CSR_B64=$(openssl req -in /tmp/device-renew.csr -outform DER | base64 | tr -d '\n')

# Perform EST simple re-enrollment
curl -v --cacert $CA_BUNDLE \
     --cert $OPERATIONAL_CERT \
     --key $KEY \
     -H "Content-Type: application/pkcs10" \
     -H "Content-Transfer-Encoding: base64" \
     --data "$CSR_B64" \
     "https://${EST_SERVER}/.well-known/est/simplereenroll" \
     -o /tmp/operational-renewed.p7

# Convert PKCS#7 to PEM
openssl pkcs7 -inform DER -in /tmp/operational-renewed.p7 -print_certs -out /tmp/operational-renewed.pem

echo "Renewed certificate saved to /tmp/operational-renewed.pem"
```

### Get CA Certificates

```bash
#!/bin/bash
# test-get-cacerts.sh

OPERATIONAL_CERT="/etc/ucentral/operational.pem"
KEY="/etc/ucentral/key.pem"
CA_BUNDLE="/etc/ucentral/operational.ca"
EST_SERVER="qaest.certificates.open-lan.org:8001"

# Fetch CA certificates from EST server
curl -v --cacert $CA_BUNDLE \
     --cert $OPERATIONAL_CERT \
     --key $KEY \
     "https://${EST_SERVER}/.well-known/est/cacerts" \
     -o /tmp/cacerts.p7

# Convert PKCS#7 to PEM
openssl pkcs7 -inform DER -in /tmp/cacerts.p7 -print_certs -out /tmp/cacerts.pem

echo "CA certificates saved to /tmp/cacerts.pem"
```

## Certificate Renewal via RPC

To renew operational certificates from the gateway, send a reenroll RPC command:

```json
{
  "jsonrpc": "2.0",
  "id": 123,
  "method": "reenroll",
  "params": {
    "serial": "device_serial_number"
  }
}
```

The device will:
1. Contact EST server with current operational certificate
2. Obtain renewed operational certificate
3. Save to `/etc/ucentral/operational.pem`
4. Restart after 10 seconds to use new certificate

## Certificate Inspection

### View Certificate Details

```bash
# View birth certificate
openssl x509 -in /etc/ucentral/cert.pem -text -noout

# View operational certificate
openssl x509 -in /etc/ucentral/operational.pem -text -noout

# Check certificate expiration
openssl x509 -in /etc/ucentral/operational.pem -noout -enddate
```

### Verify Certificate Chain

```bash
# Verify birth certificate against CA
openssl verify -CAfile /etc/ucentral/cas.pem /etc/ucentral/cert.pem

# Verify operational certificate against CA
openssl verify -CAfile /etc/ucentral/operational.ca /etc/ucentral/operational.pem
```

### Extract Certificate Information

```bash
# Get Common Name (CN)
openssl x509 -in /etc/ucentral/operational.pem -noout -subject | sed 's/.*CN = //'

# Get Issuer
openssl x509 -in /etc/ucentral/cert.pem -noout -issuer

# Get Serial Number
openssl x509 -in /etc/ucentral/operational.pem -noout -serial
```

## Troubleshooting

### EST Enrollment Fails

**Check EST server connectivity:**
```bash
curl -v https://qaest.certificates.open-lan.org:8001/.well-known/est/cacerts
```

**Verify birth certificates are valid:**
```bash
openssl x509 -in /etc/ucentral/cert.pem -text -noout
openssl verify -CAfile /etc/ucentral/cas.pem /etc/ucentral/cert.pem
```

**Check certificate issuer:**
```bash
openssl x509 -in /etc/ucentral/cert.pem -noout -issuer
# Should show: "OpenLAN Demo Birth CA" or "OpenLAN Birth Issuing CA"
```

### Operational Certificate Not Created

**Check uCentral client logs:**
```bash
journalctl -u ucentral-client -f
```

**Look for EST enrollment errors:**
```bash
grep -i "est\|enroll\|pki" /var/log/ucentral-client.log
```

**Manually test EST enrollment:**
```bash
cd /tmp
bash /path/to/examples/pki-2.0/test-est-enrollment.sh
```

### Certificate Expiration

**Check expiration dates:**
```bash
echo "Birth certificate:"
openssl x509 -in /etc/ucentral/cert.pem -noout -enddate

echo "Operational certificate:"
openssl x509 -in /etc/ucentral/operational.pem -noout -enddate
```

**Setup expiration monitoring:**
```bash
# Check if operational cert expires in less than 30 days
CERT_FILE="/etc/ucentral/operational.pem"
EXPIRE_DATE=$(openssl x509 -in $CERT_FILE -noout -enddate | cut -d= -f2)
EXPIRE_EPOCH=$(date -d "$EXPIRE_DATE" +%s)
NOW_EPOCH=$(date +%s)
DAYS_LEFT=$(( ($EXPIRE_EPOCH - $NOW_EPOCH) / 86400 ))

if [ $DAYS_LEFT -lt 30 ]; then
    echo "WARNING: Certificate expires in $DAYS_LEFT days"
    echo "Consider triggering reenroll RPC command"
fi
```

## Production Checklist

Before deploying to production:

- [ ] Birth certificates generated with production CA
- [ ] Certificates securely stored during manufacturing
- [ ] Device partition properly configured
- [ ] EST server URL matches certificate issuer
- [ ] Operational certificate automatically obtained on first boot
- [ ] Gateway can reach device for reenroll RPC
- [ ] Certificate expiration monitoring in place
- [ ] Backup/recovery procedure documented

## Additional Resources

- **Main README**: `../../README.md` - Certificate architecture overview
- **openlan-pki-tools**: https://github.com/Telecominfraproject/openlan-pki-tools
- **EST RFC 7030**: https://tools.ietf.org/html/rfc7030
- **est-client.c**: `../../src/ucentral-client/est-client.c` - EST client implementation
- **partition_script.sh**: `../../partition_script.sh` - Certificate partition tool
