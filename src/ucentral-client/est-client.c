/* SPDX-License-Identifier: BSD-3-Clause */

/**
 * EST (Enrollment over Secure Transport) Client Implementation
 *
 * RFC 7030 compliant EST client for PKI 2.0 operational certificate
 * enrollment and renewal. Implements:
 * - /simpleenroll - Initial certificate enrollment
 * - /simplereenroll - Certificate renewal
 * - /cacerts - CA certificate retrieval
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <curl/curl.h>
#include <openssl/bio.h>
#include <openssl/pem.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/pkcs7.h>

#define UC_LOG_COMPONENT UC_LOG_COMPONENT_CLIENT
#include "ucentral-log.h"

#include "est-client.h"

/* EST default servers */
#define EST_SERVER_PROD  "est.certificates.open-lan.org"
#define EST_SERVER_QA    "qaest.certificates.open-lan.org:8001"

/* EST well-known paths (RFC 7030) */
#define EST_PATH_SIMPLEENROLL   "/.well-known/est/simpleenroll"
#define EST_PATH_SIMPLEREENROLL "/.well-known/est/simplereenroll"
#define EST_PATH_CACERTS        "/.well-known/est/cacerts"

/* HTTP request timeout */
#define EST_TIMEOUT_SECONDS 30

/* Global error message buffer */
static char est_error_msg[512] = {0};

/* Memory buffer for CURL responses */
struct est_memory {
	char *data;
	size_t size;
};

/**
 * Set error message
 */
static void est_set_error(const char *fmt, ...)
{
	va_list args;
	va_start(args, fmt);
	vsnprintf(est_error_msg, sizeof(est_error_msg), fmt, args);
	va_end(args);
}

const char* est_get_error(void)
{
	return est_error_msg[0] ? est_error_msg : "Unknown error";
}

/**
 * CURL write callback - store response data in memory
 */
static size_t est_write_callback(void *contents, size_t size, size_t nmemb, void *userp)
{
	size_t realsize = size * nmemb;
	struct est_memory *mem = (struct est_memory *)userp;

	char *ptr = realloc(mem->data, mem->size + realsize + 1);
	if (!ptr) {
		est_set_error("Out of memory");
		return 0;
	}

	mem->data = ptr;
	memcpy(&(mem->data[mem->size]), contents, realsize);
	mem->size += realsize;
	mem->data[mem->size] = 0; /* null terminate */

	return realsize;
}

/**
 * Extract certificate issuer string
 */
static char* est_get_cert_issuer(const char *cert_path)
{
	FILE *f = fopen(cert_path, "r");
	if (!f) {
		est_set_error("Cannot open certificate: %s", cert_path);
		return NULL;
	}

	X509 *cert = PEM_read_X509(f, NULL, NULL, NULL);
	fclose(f);

	if (!cert) {
		est_set_error("Failed to parse certificate");
		return NULL;
	}

	X509_NAME *issuer = X509_get_issuer_name(cert);
	if (!issuer) {
		X509_free(cert);
		est_set_error("Failed to get certificate issuer");
		return NULL;
	}

	char *issuer_str = X509_NAME_oneline(issuer, NULL, 0);
	X509_free(cert);

	return issuer_str;
}

const char* est_get_server_url(const char *cert_path)
{
	/* Check environment variable override */
	const char *env_server = getenv("EST_SERVER");
	if (env_server && env_server[0])
		return env_server;

	/* Caller must pass the birth cert; operational cert issuers are not
	 * matched below. */
	char *issuer = est_get_cert_issuer(cert_path);
	if (!issuer) {
		UC_LOG_INFO("EST: cert issuer unavailable, defaulting to %s\n",
			    EST_SERVER_PROD);
		return EST_SERVER_PROD;
	}

	const char *server = EST_SERVER_PROD;

	if (strstr(issuer, "OpenLAN Demo Birth CA")) {
		server = EST_SERVER_QA;
	} else if (strstr(issuer, "OpenLAN Birth Issuing CA")) {
		server = EST_SERVER_PROD;
	} else {
		UC_LOG_INFO("EST: unrecognized cert issuer '%s', defaulting to %s\n",
			    issuer, EST_SERVER_PROD);
	}

	OPENSSL_free(issuer);
	return server;
}

/**
 * Generate CSR from existing certificate
 */
int est_generate_csr(const char *cert_path, const char *key_path,
                     char **csr_out, size_t *csr_len)
{
	if (!cert_path || !key_path || !csr_out || !csr_len) {
		est_set_error("Invalid arguments");
		return EST_ERROR_INVALID;
	}

	*csr_out = NULL;
	*csr_len = 0;

	/* Read existing certificate */
	FILE *cert_file = fopen(cert_path, "r");
	if (!cert_file) {
		est_set_error("Cannot open certificate: %s", cert_path);
		return EST_ERROR_GENERAL;
	}

	X509 *cert = PEM_read_X509(cert_file, NULL, NULL, NULL);
	fclose(cert_file);

	if (!cert) {
		est_set_error("Failed to parse certificate");
		return EST_ERROR_CRYPTO;
	}

	/* Get subject from existing certificate */
	X509_NAME *subject = X509_get_subject_name(cert);
	if (!subject) {
		X509_free(cert);
		est_set_error("Failed to get certificate subject");
		return EST_ERROR_CRYPTO;
	}

	/* Duplicate subject name (we'll free cert but need subject) */
	X509_NAME *subject_dup = X509_NAME_dup(subject);
	X509_free(cert);

	if (!subject_dup) {
		est_set_error("Failed to duplicate subject name");
		return EST_ERROR_MEMORY;
	}

	/* Read private key */
	FILE *key_file = fopen(key_path, "r");
	if (!key_file) {
		X509_NAME_free(subject_dup);
		est_set_error("Cannot open private key: %s", key_path);
		return EST_ERROR_GENERAL;
	}

	EVP_PKEY *pkey = PEM_read_PrivateKey(key_file, NULL, NULL, NULL);
	fclose(key_file);

	if (!pkey) {
		X509_NAME_free(subject_dup);
		est_set_error("Failed to parse private key");
		return EST_ERROR_CRYPTO;
	}

	/* Create new CSR */
	X509_REQ *req = X509_REQ_new();
	if (!req) {
		EVP_PKEY_free(pkey);
		X509_NAME_free(subject_dup);
		est_set_error("Failed to create CSR");
		return EST_ERROR_MEMORY;
	}

	/* Set version */
	X509_REQ_set_version(req, 0L);

	/* Set subject */
	X509_REQ_set_subject_name(req, subject_dup);
	X509_NAME_free(subject_dup);

	/* Set public key */
	X509_REQ_set_pubkey(req, pkey);

	/* Sign CSR */
	if (!X509_REQ_sign(req, pkey, EVP_sha256())) {
		X509_REQ_free(req);
		EVP_PKEY_free(pkey);
		est_set_error("Failed to sign CSR");
		return EST_ERROR_CRYPTO;
	}

	EVP_PKEY_free(pkey);

	/* Write CSR to memory (DER format) */
	BIO *bio = BIO_new(BIO_s_mem());
	if (!bio) {
		X509_REQ_free(req);
		est_set_error("Failed to create BIO");
		return EST_ERROR_MEMORY;
	}

	if (!i2d_X509_REQ_bio(bio, req)) {
		BIO_free(bio);
		X509_REQ_free(req);
		est_set_error("Failed to write CSR");
		return EST_ERROR_CRYPTO;
	}

	X509_REQ_free(req);

	/* Get DER data */
	BUF_MEM *bio_buf;
	BIO_get_mem_ptr(bio, &bio_buf);

	/* Base64 encode (no headers) */
	BIO *b64 = BIO_new(BIO_f_base64());
	BIO_set_flags(b64, BIO_FLAGS_BASE64_NO_NL);
	BIO *mem_bio = BIO_new(BIO_s_mem());
	BIO_push(b64, mem_bio);

	BIO_write(b64, bio_buf->data, bio_buf->length);
	BIO_flush(b64);

	BUF_MEM *b64_buf;
	BIO_get_mem_ptr(mem_bio, &b64_buf);

	*csr_out = malloc(b64_buf->length + 1);
	if (!*csr_out) {
		BIO_free_all(b64);
		BIO_free(bio);
		est_set_error("Out of memory");
		return EST_ERROR_MEMORY;
	}

	memcpy(*csr_out, b64_buf->data, b64_buf->length);
	(*csr_out)[b64_buf->length] = 0;
	*csr_len = b64_buf->length;

	BIO_free_all(b64);
	BIO_free(bio);

	return EST_SUCCESS;
}

/**
 * Convert PKCS#7 to PEM format
 */
int est_pkcs7_to_pem(const char *pkcs7_data, size_t pkcs7_len,
                     char **pem_out, size_t *pem_len)
{
	if (!pkcs7_data || !pkcs7_len || !pem_out || !pem_len) {
		est_set_error("Invalid arguments");
		return EST_ERROR_INVALID;
	}

	*pem_out = NULL;
	*pem_len = 0;

	/* Decode base64 */
	BIO *b64 = BIO_new(BIO_f_base64());
	BIO_set_flags(b64, BIO_FLAGS_BASE64_NO_NL);
	BIO *bio_mem = BIO_new_mem_buf((void*)pkcs7_data, pkcs7_len);
	BIO_push(b64, bio_mem);

	/* Read PKCS#7 structure */
	PKCS7 *p7 = d2i_PKCS7_bio(b64, NULL);
	BIO_free_all(b64);

	if (!p7) {
		est_set_error("Failed to parse PKCS#7 data");
		return EST_ERROR_CRYPTO;
	}

	/* Extract certificates from PKCS#7 */
	STACK_OF(X509) *certs = NULL;
	int type = OBJ_obj2nid(p7->type);

	if (type == NID_pkcs7_signed) {
		certs = p7->d.sign->cert;
	} else if (type == NID_pkcs7_signedAndEnveloped) {
		certs = p7->d.signed_and_enveloped->cert;
	}

	if (!certs || sk_X509_num(certs) == 0) {
		PKCS7_free(p7);
		est_set_error("No certificates in PKCS#7");
		return EST_ERROR_CRYPTO;
	}

	/* Write certificates to PEM */
	BIO *out = BIO_new(BIO_s_mem());
	if (!out) {
		PKCS7_free(p7);
		est_set_error("Failed to create output BIO");
		return EST_ERROR_MEMORY;
	}

	for (int i = 0; i < sk_X509_num(certs); i++) {
		X509 *cert = sk_X509_value(certs, i);
		if (!PEM_write_bio_X509(out, cert)) {
			BIO_free(out);
			PKCS7_free(p7);
			est_set_error("Failed to write certificate");
			return EST_ERROR_CRYPTO;
		}
	}

	PKCS7_free(p7);

	/* Get PEM data */
	BUF_MEM *pem_buf;
	BIO_get_mem_ptr(out, &pem_buf);

	*pem_out = malloc(pem_buf->length + 1);
	if (!*pem_out) {
		BIO_free(out);
		est_set_error("Out of memory");
		return EST_ERROR_MEMORY;
	}

	memcpy(*pem_out, pem_buf->data, pem_buf->length);
	(*pem_out)[pem_buf->length] = 0;
	*pem_len = pem_buf->length;

	BIO_free(out);

	return EST_SUCCESS;
}

/**
 * Perform EST HTTP request
 */
static int est_http_request(const char *url, const char *cert, const char *key,
                            const char *ca_bundle, const char *post_data, size_t post_len,
                            char **response_out, size_t *response_len)
{
	CURL *curl;
	CURLcode res;
	struct est_memory response = {0};

	curl = curl_easy_init();
	if (!curl) {
		est_set_error("Failed to initialize CURL");
		return EST_ERROR_GENERAL;
	}

	/* Set URL */
	curl_easy_setopt(curl, CURLOPT_URL, url);

	/* Client certificate authentication */
	curl_easy_setopt(curl, CURLOPT_SSLCERTTYPE, "PEM");
	curl_easy_setopt(curl, CURLOPT_SSLCERT, cert);
	curl_easy_setopt(curl, CURLOPT_SSLKEYTYPE, "PEM");
	curl_easy_setopt(curl, CURLOPT_SSLKEY, key);

	/* CA bundle for server verification */
	if (ca_bundle)
		curl_easy_setopt(curl, CURLOPT_CAINFO, ca_bundle);

	/* Response handler */
	curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, est_write_callback);
	curl_easy_setopt(curl, CURLOPT_WRITEDATA, (void *)&response);

	/* Timeout */
	curl_easy_setopt(curl, CURLOPT_TIMEOUT, EST_TIMEOUT_SECONDS);

	/* POST request if data provided */
	if (post_data && post_len > 0) {
		struct curl_slist *headers = NULL;
		headers = curl_slist_append(headers, "Content-Type: application/pkcs10");
		curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
		curl_easy_setopt(curl, CURLOPT_POST, 1L);
		curl_easy_setopt(curl, CURLOPT_POSTFIELDS, post_data);
		curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, post_len);
	}

	/* Perform request */
	res = curl_easy_perform(curl);

	curl_easy_cleanup(curl);

	if (res != CURLE_OK) {
		if (response.data)
			free(response.data);
		est_set_error("CURL error: %s", curl_easy_strerror(res));
		return EST_ERROR_NETWORK;
	}

	*response_out = response.data;
	*response_len = response.size;

	return EST_SUCCESS;
}

int est_simple_enroll(const char *est_server, const char *birth_cert,
                      const char *birth_key, const char *ca_bundle,
                      char **operational_cert_out)
{
	if (!est_server || !birth_cert || !birth_key || !operational_cert_out) {
		est_set_error("Invalid arguments");
		return EST_ERROR_INVALID;
	}

	*operational_cert_out = NULL;

	/* Generate CSR */
	char *csr = NULL;
	size_t csr_len = 0;
	int ret = est_generate_csr(birth_cert, birth_key, &csr, &csr_len);
	if (ret != EST_SUCCESS) {
		return ret;
	}

	/* Build EST URL */
	char url[512];
	snprintf(url, sizeof(url), "https://%s%s", est_server, EST_PATH_SIMPLEENROLL);

	/* Perform enrollment */
	char *response = NULL;
	size_t response_len = 0;
	ret = est_http_request(url, birth_cert, birth_key, ca_bundle,
	                       csr, csr_len, &response, &response_len);
	free(csr);

	if (ret != EST_SUCCESS) {
		return ret;
	}

	/* Convert PKCS#7 response to PEM */
	char *pem = NULL;
	size_t pem_len = 0;
	ret = est_pkcs7_to_pem(response, response_len, &pem, &pem_len);
	free(response);

	if (ret != EST_SUCCESS) {
		return ret;
	}

	*operational_cert_out = pem;
	return EST_SUCCESS;
}

int est_simple_reenroll(const char *est_server, const char *operational_cert,
                        const char *key, const char *ca_bundle,
                        char **renewed_cert_out)
{
	if (!est_server || !operational_cert || !key || !renewed_cert_out) {
		est_set_error("Invalid arguments");
		return EST_ERROR_INVALID;
	}

	*renewed_cert_out = NULL;

	/* Generate CSR */
	char *csr = NULL;
	size_t csr_len = 0;
	int ret = est_generate_csr(operational_cert, key, &csr, &csr_len);
	if (ret != EST_SUCCESS) {
		return ret;
	}

	/* Build EST URL */
	char url[512];
	snprintf(url, sizeof(url), "https://%s%s", est_server, EST_PATH_SIMPLEREENROLL);

	/* Perform reenrollment */
	char *response = NULL;
	size_t response_len = 0;
	ret = est_http_request(url, operational_cert, key, ca_bundle,
	                       csr, csr_len, &response, &response_len);
	free(csr);

	if (ret != EST_SUCCESS) {
		return ret;
	}

	/* Convert PKCS#7 response to PEM */
	char *pem = NULL;
	size_t pem_len = 0;
	ret = est_pkcs7_to_pem(response, response_len, &pem, &pem_len);
	free(response);

	if (ret != EST_SUCCESS) {
		return ret;
	}

	*renewed_cert_out = pem;
	return EST_SUCCESS;
}

int est_get_cacerts(const char *est_server, const char *cert, const char *key,
                    const char *ca_bundle, char **ca_certs_out)
{
	if (!est_server || !cert || !key || !ca_certs_out) {
		est_set_error("Invalid arguments");
		return EST_ERROR_INVALID;
	}

	*ca_certs_out = NULL;

	/* Build EST URL */
	char url[512];
	snprintf(url, sizeof(url), "https://%s%s", est_server, EST_PATH_CACERTS);

	/* Perform GET request */
	char *response = NULL;
	size_t response_len = 0;
	int ret = est_http_request(url, cert, key, ca_bundle,
	                           NULL, 0, &response, &response_len);

	if (ret != EST_SUCCESS) {
		return ret;
	}

	/* Convert PKCS#7 response to PEM */
	char *pem = NULL;
	size_t pem_len = 0;
	ret = est_pkcs7_to_pem(response, response_len, &pem, &pem_len);
	free(response);

	if (ret != EST_SUCCESS) {
		return ret;
	}

	*ca_certs_out = pem;
	return EST_SUCCESS;
}

int est_save_cert(const char *cert_data, size_t cert_len, const char *file_path)
{
	if (!cert_data || !cert_len || !file_path) {
		est_set_error("Invalid arguments");
		return EST_ERROR_INVALID;
	}

	FILE *f = fopen(file_path, "w");
	if (!f) {
		est_set_error("Cannot create file: %s", file_path);
		return EST_ERROR_GENERAL;
	}

	if (fwrite(cert_data, 1, cert_len, f) != cert_len) {
		fclose(f);
		est_set_error("Failed to write to file: %s", file_path);
		return EST_ERROR_GENERAL;
	}

	fclose(f);
	return EST_SUCCESS;
}
