/*
 * macos-pbkdf2-test: PBKDF2-HMAC-SHA512 through CommonCrypto (corecrypto underneath), the routine opendirectoryd uses
 * for SALTED-SHA512-PBKDF2 passwords, on a fixed input. Run it on the Mac and on the phone: the two lines must match.
 * (2026-11-21: autologin failed with ODErrorCredentialsInvalid for a hash made with Python's hashlib.)
 *
 *   xcrun --sdk macosx clang -arch arm64 -O2 -o outputs/pbkdf2test tools/macos-pbkdf2-test.c
 */
#include <CommonCrypto/CommonKeyDerivation.h>
#include <CommonCrypto/CommonDigest.h>
#include <stdio.h>
#include <string.h>

static void
hex(const char *label, const unsigned char *p, size_t n)
{
	printf("%s ", label);
	for (size_t i = 0; i < n; i++) {
		printf("%02x", p[i]);
	}
	printf("\n");
}

int
main(void)
{
	const char *pw = "password";
	const unsigned char salt[] = "saltsaltsaltsaltsaltsaltsaltsalt";
	unsigned char out[64], d[CC_SHA512_DIGEST_LENGTH];
	int r = CCKeyDerivationPBKDF(kCCPBKDF2, pw, strlen(pw), salt, 32, kCCPRFHmacAlgSHA512, 1000, out, sizeof out);
	printf("CCKeyDerivationPBKDF -> %d\n", r);
	hex("pbkdf2-sha512 1000", out, 16);
	r = CCKeyDerivationPBKDF(kCCPBKDF2, pw, strlen(pw), salt, 32, kCCPRFHmacAlgSHA512, 45454, out, sizeof out);
	hex("pbkdf2-sha512 45454", out, 16);
	CC_SHA512("abc", 3, d);
	hex("CC_SHA512(abc)", d, 16);
	return 0;
}
