//
//  LocalCA.mm
//  Hand-rolled TLS for on-device OTA. Generates a self-signed root CA once,
//  then issues leaf certs for any host on demand — all with the OpenSSL that's
//  already linked for zsign. No ACME, no external CA, no DNS, no expiry chase.
//
//  iOS trusts the leaf once the user installs the root as a profile and enables
//  it in Settings › General › About › Certificate Trust Settings.
//

#import <Foundation/Foundation.h>
#import <openssl/evp.h>
#import <openssl/x509.h>
#import <openssl/x509v3.h>
#import <openssl/pem.h>
#import <openssl/rand.h>
#import <openssl/bn.h>
#import "LocalCA.h"

static NSString *pemFromBIO(BIO *bio) {
    char *data = NULL;
    long len = BIO_get_mem_data(bio, &data);
    return [[NSString alloc] initWithBytes:data length:len encoding:NSUTF8StringEncoding];
}

// Build an EC P-256 key.
static EVP_PKEY *makeECKey(void) {
    EVP_PKEY_CTX *pctx = EVP_PKEY_CTX_new_id(EVP_PKEY_EC, NULL);
    if (!pctx) return NULL;
    EVP_PKEY_keygen_init(pctx);
    EVP_PKEY_CTX_set_ec_paramgen_curve_nid(pctx, NID_X9_62_prime256v1);
    EVP_PKEY *key = NULL;
    EVP_PKEY_keygen(pctx, &key);
    EVP_PKEY_CTX_free(pctx);
    return key;
}

static void setName(X509_NAME *name, const char *cn, const char *org) {
    X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC, (const unsigned char *)cn, -1, -1, 0);
    X509_NAME_add_entry_by_txt(name, "O",  MBSTRING_ASC, (const unsigned char *)org, -1, -1, 0);
}

static void addExt(X509 *cert, X509 *issuer, int nid, const char *value) {
    X509V3_CTX ctx;
    X509V3_set_ctx_nodb(&ctx);
    X509V3_set_ctx(&ctx, issuer ? issuer : cert, cert, NULL, NULL, 0);
    X509_EXTENSION *ex = X509V3_EXT_conf_nid(NULL, &ctx, nid, (char *)value);
    if (ex) { X509_add_ext(cert, ex, -1); X509_EXTENSION_free(ex); }
}

static void randSerial(X509 *cert) {
    unsigned char b[16]; RAND_bytes(b, sizeof b);
    b[0] &= 0x7F;
    BIGNUM *bn = BN_bin2bn(b, sizeof b, NULL);
    ASN1_INTEGER *ser = BN_to_ASN1_INTEGER(bn, NULL);
    X509_set_serialNumber(cert, ser);
    ASN1_INTEGER_free(ser); BN_free(bn);
}


@implementation LocalCA

+ (NSDictionary *)generateRootCAWithCommonName:(NSString *)cn validYears:(int)years {
    EVP_PKEY *key = makeECKey();
    if (!key) return nil;
    X509 *x = X509_new();
    X509_set_version(x, 2);
    randSerial(x);
    X509_gmtime_adj(X509_getm_notBefore(x), -3600);
    X509_gmtime_adj(X509_getm_notAfter(x), (long)years * 365 * 24 * 3600);
    X509_set_pubkey(x, key);
    X509_NAME *nm = X509_get_subject_name(x);
    setName(nm, cn.UTF8String, "MRvEK Local CA");
    X509_set_issuer_name(x, nm); // self-signed
    addExt(x, x, NID_basic_constraints, "critical,CA:TRUE");
    addExt(x, x, NID_key_usage, "critical,keyCertSign,cRLSign");
    addExt(x, x, NID_subject_key_identifier, "hash");
    if (!X509_sign(x, key, EVP_sha256())) { X509_free(x); EVP_PKEY_free(key); return nil; }

    BIO *cb = BIO_new(BIO_s_mem()); PEM_write_bio_X509(cb, x);
    BIO *kb = BIO_new(BIO_s_mem()); PEM_write_bio_PrivateKey(kb, key, NULL, NULL, 0, NULL, NULL);
    NSDictionary *out = @{ @"cert": pemFromBIO(cb), @"key": pemFromBIO(kb) };
    BIO_free(cb); BIO_free(kb); X509_free(x); EVP_PKEY_free(key);
    return out;
}

+ (NSDictionary *)issueLeafForHost:(NSString *)host
                       rootCertPEM:(NSString *)rootCertPEM
                        rootKeyPEM:(NSString *)rootKeyPEM
                        validYears:(int)years {
    // Load root.
    BIO *rcb = BIO_new_mem_buf(rootCertPEM.UTF8String, -1);
    X509 *root = PEM_read_bio_X509(rcb, NULL, NULL, NULL); BIO_free(rcb);
    BIO *rkb = BIO_new_mem_buf(rootKeyPEM.UTF8String, -1);
    EVP_PKEY *rootKey = PEM_read_bio_PrivateKey(rkb, NULL, NULL, NULL); BIO_free(rkb);
    if (!root || !rootKey) { if (root) X509_free(root); if (rootKey) EVP_PKEY_free(rootKey); return nil; }

    EVP_PKEY *leafKey = makeECKey();
    X509 *x = X509_new();
    X509_set_version(x, 2);
    randSerial(x);
    X509_gmtime_adj(X509_getm_notBefore(x), -3600);
    X509_gmtime_adj(X509_getm_notAfter(x), (long)years * 365 * 24 * 3600);
    X509_set_pubkey(x, leafKey);
    setName(X509_get_subject_name(x), host.UTF8String, "MRvEK OTA");
    X509_set_issuer_name(x, X509_get_subject_name(root));
    addExt(x, root, NID_basic_constraints, "critical,CA:FALSE");
    addExt(x, root, NID_key_usage, "critical,digitalSignature,keyEncipherment");
    addExt(x, root, NID_ext_key_usage, "serverAuth");
    addExt(x, root, NID_subject_key_identifier, "hash");
    addExt(x, root, NID_authority_key_identifier, "keyid,issuer");
    NSString *san = [NSString stringWithFormat:@"DNS:%@,DNS:*.%@", host, host];
    addExt(x, root, NID_subject_alt_name, san.UTF8String);
    if (!X509_sign(x, rootKey, EVP_sha256())) {
        X509_free(x); EVP_PKEY_free(leafKey); X509_free(root); EVP_PKEY_free(rootKey); return nil;
    }

    BIO *cb = BIO_new(BIO_s_mem());
    PEM_write_bio_X509(cb, x);       // leaf first
    PEM_write_bio_X509(cb, root);    // then root → fullchain
    BIO *kb = BIO_new(BIO_s_mem());
    PEM_write_bio_PrivateKey(kb, leafKey, NULL, NULL, 0, NULL, NULL);
    NSDictionary *out = @{ @"cert": pemFromBIO(cb), @"key": pemFromBIO(kb) };
    BIO_free(cb); BIO_free(kb);
    X509_free(x); EVP_PKEY_free(leafKey); X509_free(root); EVP_PKEY_free(rootKey);
    return out;
}

@end
