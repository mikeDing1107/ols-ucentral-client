/* SPDX-License-Identifier: BSD-3-Clause */

#ifndef __EST_CLIENT_H
#define __EST_CLIENT_H

/**
 * EST (Enrollment over Secure Transport) Client Implementation
 *
 * Implements RFC 7030 EST protocol for PKI 2.0 operational certificate
 * enrollment and renewal. Uses libcurl for HTTPS transport and OpenSSL
 * for cryptographic operations.
 */

#include <stddef.h>

/* EST operation return codes */
#define EST_SUCCESS           0
#define EST_ERROR_GENERAL    -1
#define EST_ERROR_NETWORK    -2
#define EST_ERROR_CRYPTO     -3
#define EST_ERROR_MEMORY     -4
#define EST_ERROR_INVALID    -5

/**
 * Generate a Certificate Signing Request (CSR) from an existing certificate
 *
 * @param cert_path Path to existing certificate (PEM format)
 * @param key_path Path to private key (PEM format)
 * @param csr_out Output buffer for CSR (base64, no headers) - caller must free()
 * @param csr_len Output length of CSR data
 * @return EST_SUCCESS on success, error code otherwise
 */
int est_generate_csr(const char *cert_path, const char *key_path,
                     char **csr_out, size_t *csr_len);

/**
 * Perform EST simple enrollment - Get operational certificate from birth certificate
 *
 * @param est_server EST server URL (e.g., "est.certificates.open-lan.org")
 * @param birth_cert Path to birth certificate (PEM format)
 * @param birth_key Path to birth certificate private key (PEM format)
 * @param ca_bundle Path to CA certificate bundle for server verification
 * @param operational_cert_out Output operational certificate (PEM) - caller must free()
 * @return EST_SUCCESS on success, error code otherwise
 */
int est_simple_enroll(const char *est_server,
                      const char *birth_cert, const char *birth_key,
                      const char *ca_bundle,
                      char **operational_cert_out);

/**
 * Perform EST simple reenrollment - Renew operational certificate
 *
 * @param est_server EST server URL
 * @param operational_cert Path to current operational certificate (PEM format)
 * @param key Path to private key (PEM format)
 * @param ca_bundle Path to CA certificate bundle
 * @param renewed_cert_out Output renewed certificate (PEM) - caller must free()
 * @return EST_SUCCESS on success, error code otherwise
 */
int est_simple_reenroll(const char *est_server,
                        const char *operational_cert, const char *key,
                        const char *ca_bundle,
                        char **renewed_cert_out);

/**
 * Retrieve operational CA certificates from EST server
 *
 * @param est_server EST server URL
 * @param cert Path to client certificate for authentication
 * @param key Path to private key
 * @param ca_bundle Path to CA bundle for server verification
 * @param ca_certs_out Output CA certificates (PEM) - caller must free()
 * @return EST_SUCCESS on success, error code otherwise
 */
int est_get_cacerts(const char *est_server,
                    const char *cert, const char *key,
                    const char *ca_bundle,
                    char **ca_certs_out);

/**
 * Convert PKCS#7 format to PEM format using OpenSSL
 *
 * @param pkcs7_data PKCS#7 data (base64, no headers)
 * @param pkcs7_len Length of PKCS#7 data
 * @param pem_out Output PEM format certificate(s) - caller must free()
 * @param pem_len Output length of PEM data
 * @return EST_SUCCESS on success, error code otherwise
 */
int est_pkcs7_to_pem(const char *pkcs7_data, size_t pkcs7_len,
                     char **pem_out, size_t *pem_len);

/**
 * Auto-detect EST server URL based on certificate issuer
 *
 * Inspects the certificate issuer field to determine appropriate EST server:
 * - "OpenLAN Demo Birth CA" -> QA server
 * - "OpenLAN Birth Issuing CA" -> Production server
 *
 * Can be overridden with EST_SERVER environment variable.
 *
 * @param cert_path Path to certificate to inspect
 * @return EST server URL (static string), or NULL on error
 */
const char* est_get_server_url(const char *cert_path);

/**
 * Save certificate to file
 *
 * @param cert_data Certificate data (PEM format)
 * @param cert_len Length of certificate data
 * @param file_path Destination file path
 * @return EST_SUCCESS on success, error code otherwise
 */
int est_save_cert(const char *cert_data, size_t cert_len, const char *file_path);

/**
 * Get last error message
 *
 * @return Human-readable error message (static string)
 */
const char* est_get_error(void);

#endif /* __EST_CLIENT_H */
